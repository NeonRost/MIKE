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

        switch format {
        case .zip:
            try createZip(entries: entries, to: destinationArchive, onProgress: onProgress, isCancelled: isCancelled)
        case .tarGz:
            try createTarGz(entries: entries, to: destinationArchive, onProgress: onProgress, isCancelled: isCancelled)
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
                let info = TarEntryInfo(name: entry.relativePath + "/", type: .directory)
                tarEntries.append(TarEntry(info: info, data: nil))
            } else {
                let data: Data
                do {
                    data = try Data(contentsOf: entry.url)
                } catch {
                    throw CompressionError.io(error.localizedDescription)
                }
                let info = TarEntryInfo(name: entry.relativePath, type: .regular)
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

    // MARK: - Expansion

    /// Walks each top-level item (recursing into folders) into a flat list
    /// of archive-relative paths. Hidden files are skipped, matching
    /// `DuplicateFinder.collectFiles`'s own rule for folder scans.
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
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let url as URL in enumerator {
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
