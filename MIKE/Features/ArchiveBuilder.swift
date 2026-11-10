// MIKE – Mike's Toolbox
// Copyright (C) 2026 NeonRost
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import SWCompression
import ZIPFoundation

/// Packs files and folders into a new archive. Must be called off the main
/// thread — both libraries are synchronous.
enum ArchiveBuilder {
    /// One file or directory, with the archive-relative path it should be
    /// stored under. Each top-level item in `items` keeps its own name as
    /// the top path component, so packing a folder preserves its structure
    /// inside the archive rather than flattening its contents to the root.
    private struct Entry {
        let relativePath: String
        let url: URL
        let isDirectory: Bool
    }

    static func create(
        format: ArchiveFormat,
        from items: [URL],
        to destinationArchive: URL,
        onProgress: @escaping (Int, Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws {
        let entries = expand(items)
        guard !entries.isEmpty else { return }

        do {
            switch format {
            case .zip:
                try createZip(entries: entries, to: destinationArchive, onProgress: onProgress, isCancelled: isCancelled)
            case .tarGz:
                try createTarGz(entries: entries, to: destinationArchive, onProgress: onProgress, isCancelled: isCancelled)
            }
        } catch {
            // A ZIP grows entry by entry, so a cancelled or failed run would
            // otherwise leave a shorter archive behind under the final name —
            // one that opens fine and is simply missing files.
            try? FileManager.default.removeItem(at: destinationArchive)
            throw error
        }
    }

    // MARK: - ZIP

    private static func createZip(
        entries: [Entry],
        to destination: URL,
        onProgress: @escaping (Int, Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws {
        // Module-qualified — see the identical note in ArchiveExtractor.swift.
        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: destination, accessMode: .create)
        } catch {
            throw CompressionError.io(error.localizedDescription)
        }

        var lastPercent = -1
        for (index, entry) in entries.enumerated() {
            if isCancelled() { throw CompressionError.cancelled }
            ArchiveProgress.report(current: index + 1, total: entries.count, lastPercent: &lastPercent, onProgress: onProgress)
            do {
                try archive.addEntry(
                    with: entry.relativePath,
                    fileURL: entry.url,
                    compressionMethod: entry.isDirectory ? .none : .deflate
                )
            } catch {
                throw CompressionError.io(error.localizedDescription)
            }
        }
        onProgress(entries.count, entries.count)
    }

    // MARK: - TAR.GZ

    private static func createTarGz(
        entries: [Entry],
        to destination: URL,
        onProgress: @escaping (Int, Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws {
        // Refused before anything is read: see `TarGzLimits`.
        var totalSize: Int64 = 0
        for entry in entries where !entry.isDirectory {
            totalSize += Int64((try? entry.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard totalSize <= TarGzLimits.maximumPackedInput else {
            throw CompressionError.tooLargeForTarGz(limit: TarGzLimits.describe(TarGzLimits.maximumPackedInput))
        }

        var tarEntries: [TarEntry] = []
        tarEntries.reserveCapacity(entries.count)

        var lastPercent = -1
        for (index, entry) in entries.enumerated() {
            if isCancelled() { throw CompressionError.cancelled }
            // This phase is "reading files", not the final write — the
            // actual tar+gzip serialization below has no progress callback
            // of its own, so the UI shows an indeterminate spinner for that
            // short final step instead of a fabricated percentage.
            ArchiveProgress.report(current: index + 1, total: entries.count, lastPercent: &lastPercent, onProgress: onProgress)

            if entry.isDirectory {
                var info = TarEntryInfo(name: entry.relativePath + "/", type: .directory)
                applyAttributes(of: entry.url, to: &info, fallbackMode: 0o755)
                tarEntries.append(TarEntry(info: info, data: nil))
            } else {
                let data: Data
                do {
                    data = try Data(contentsOf: entry.url)
                } catch {
                    throw CompressionError.io(error.localizedDescription)
                }
                var info = TarEntryInfo(name: entry.relativePath, type: .regular)
                applyAttributes(of: entry.url, to: &info, fallbackMode: 0o644)
                tarEntries.append(TarEntry(info: info, data: data))
            }
        }
        onProgress(entries.count, entries.count)

        if isCancelled() { throw CompressionError.cancelled }

        // TarContainer.create does not throw; only the gzip step and the
        // final write can fail.
        let tarData = TarContainer.create(from: tarEntries)
        let gzData: Data
        do {
            gzData = try GzipArchive.archive(data: tarData)
        } catch {
            throw CompressionError.io(error.localizedDescription)
        }
        do {
            try gzData.write(to: destination)
        } catch {
            throw CompressionError.io(error.localizedDescription)
        }
    }

    /// Gives a TAR entry the mode and modification date of the file it came
    /// from. `TarEntryInfo` starts out with neither, and what that writes is
    /// mode 000 dated 1970 — verified: an archive made that way unpacks with
    /// `tar` into a folder its own owner gets "Permission denied" on.
    private static func applyAttributes(of url: URL, to info: inout TarEntryInfo, fallbackMode: UInt32) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value ?? fallbackMode
        // Whatever the source says, the owner can always read the copy (and
        // enter it, for a folder) — an archive nobody can open helps no one.
        let ownerMinimum: UInt32 = fallbackMode & 0o700 == 0o700 ? 0o700 : 0o400
        info.permissions = Permissions(rawValue: (mode & 0o777) | ownerMinimum)
        info.modificationTime = (attributes?[.modificationDate] as? Date) ?? Date()
    }

    // MARK: - Expansion

    /// Walks each top-level item (recursing into folders) into a flat list
    /// of archive-relative paths.
    ///
    /// Hidden files are included. They used to be skipped, on the model of
    /// the duplicate scan — but an archive is a copy, and one that quietly
    /// leaves out `.env`, `.gitignore` or `.htaccess` is not the folder that
    /// was handed over. Only the Finder's own `.DS_Store` litter stays out.
    private static func expand(_ items: [URL]) -> [Entry] {
        var result: [Entry] = []
        for item in items {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            let topName = item.lastPathComponent

            if isDir.boolValue {
                result.append(Entry(relativePath: topName, url: item, isDirectory: true))
                let keys: [URLResourceKey] = [.isDirectoryKey]
                guard let enumerator = FileManager.default.enumerator(
                    at: item,
                    includingPropertiesForKeys: keys,
                    options: []
                ) else { continue }

                for case let url as URL in enumerator {
                    if url.lastPathComponent == ".DS_Store" { continue }
                    let subIsDir = (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory ?? false
                    let relative = topName + "/" + relativeSubpath(of: url, under: item)
                    result.append(Entry(relativePath: relative, url: url, isDirectory: subIsDir))
                }
            } else {
                result.append(Entry(relativePath: topName, url: item, isDirectory: false))
            }
        }
        return result
    }

    private static func relativeSubpath(of url: URL, under base: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }
}
