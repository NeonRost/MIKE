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

struct ArchiveExtractionResult {
    let destination: URL
    let extractedCount: Int
    /// Entry names that could not be written — a bad path (see
    /// `ArchivePath.sanitizedRelativePath`), a symlink escaping the
    /// destination, or a per-entry I/O failure. Never fatal to the rest of
    /// the archive, the same skip-and-report convention Convert Format and
    /// Merge Texts already use for their own batches.
    let failed: [String]
}

/// Unpacks a single archive. Must be called off the main thread — both
/// libraries are synchronous.
enum ArchiveExtractor {
    static func extract(
        archive: URL,
        format: ArchiveFormat,
        to destination: URL,
        onProgress: @escaping (Int, Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> ArchiveExtractionResult {
        // Only a folder this run created is this run's to remove again.
        let existedBefore = FileManager.default.fileExists(atPath: destination.path)
        do {
            switch format {
            case .zip:
                let (count, failed) = try extractZip(archive: archive, to: destination, onProgress: onProgress, isCancelled: isCancelled)
                return ArchiveExtractionResult(destination: destination, extractedCount: count, failed: failed)
            case .tarGz:
                let (count, failed) = try extractTarGz(archive: archive, to: destination, onProgress: onProgress, isCancelled: isCancelled)
                return ArchiveExtractionResult(destination: destination, extractedCount: count, failed: failed)
            }
        } catch {
            // A cancelled or broken-off unpack used to leave its half-filled
            // folder behind, looking like a finished result.
            if !existedBefore {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    // MARK: - ZIP

    private static func extractZip(
        archive: URL,
        to destination: URL,
        onProgress: @escaping (Int, Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> (count: Int, failed: [String]) {
        guard FileManager.default.isReadableFile(atPath: archive.path) else {
            throw CompressionError.corrupted(.zip)
        }
        // Checked before ZIPFoundation ever touches the file — see
        // `ZipEncryptionScan` for why this cannot be detected afterward.
        if ZipEncryptionScan.containsEncryptedEntry(at: archive) {
            throw CompressionError.passwordProtected
        }

        // Both SWCompression and ZIPFoundation export a type named `Archive`
        // (SWCompression's is a protocol `GzipArchive` etc. conform to) —
        // module-qualified so this always resolves to ZIPFoundation's class.
        let source: ZIPFoundation.Archive
        do {
            source = try ZIPFoundation.Archive(url: archive, accessMode: .read)
        } catch {
            throw CompressionError.corrupted(.zip)
        }

        let entries = Array(source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var failed: [String] = []
        var extracted = 0
        var lastPercent = -1
        for (index, entry) in entries.enumerated() {
            if isCancelled() { throw CompressionError.cancelled }
            ArchiveProgress.report(current: index + 1, total: entries.count, lastPercent: &lastPercent, onProgress: onProgress)

            guard let relativePath = ArchivePath.sanitizedRelativePath(entry.path) else {
                failed.append(entry.path)
                continue
            }
            let outputURL = destination.appendingPathComponent(relativePath)

            do {
                if entry.type == .directory {
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    _ = try source.extract(entry, to: outputURL)
                }
                extracted += 1
            } catch {
                failed.append(entry.path)
            }
        }
        onProgress(entries.count, entries.count)
        return (extracted, failed)
    }

    // MARK: - TAR.GZ

    private static func extractTarGz(
        archive: URL,
        to destination: URL,
        onProgress: @escaping (Int, Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> (count: Int, failed: [String]) {
        let archiveSize = Int64((try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard archiveSize <= TarGzLimits.maximumArchiveSize else {
            throw CompressionError.tooLargeForTarGz(limit: TarGzLimits.describe(TarGzLimits.maximumArchiveSize))
        }
        guard let compressed = try? Data(contentsOf: archive, options: .mappedIfSafe) else {
            throw CompressionError.corrupted(.tarGz)
        }

        let tarData: Data
        do {
            tarData = try GzipArchive.unarchive(archive: compressed)
        } catch {
            throw CompressionError.corrupted(.tarGz)
        }

        let entries: [TarEntry]
        do {
            entries = try TarContainer.open(container: tarData)
        } catch {
            throw CompressionError.corrupted(.tarGz)
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var failed: [String] = []
        var extracted = 0
        var lastPercent = -1
        for (index, entry) in entries.enumerated() {
            if isCancelled() { throw CompressionError.cancelled }
            ArchiveProgress.report(current: index + 1, total: entries.count, lastPercent: &lastPercent, onProgress: onProgress)

            guard let relativePath = ArchivePath.sanitizedRelativePath(entry.info.name) else {
                failed.append(entry.info.name)
                continue
            }
            let outputURL = destination.appendingPathComponent(relativePath)

            do {
                switch entry.info.type {
                case .directory:
                    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                    extracted += 1
                case .regular:
                    try FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try (entry.data ?? Data()).write(to: outputURL)
                    applyAttributes(of: entry.info, to: outputURL)
                    extracted += 1
                default:
                    // Symlinks, hard links, devices — not meaningfully or
                    // safely recreated from a TAR entry alone; reported like
                    // any other skipped entry rather than silently dropped.
                    failed.append(entry.info.name)
                }
            } catch {
                failed.append(entry.info.name)
            }
        }
        onProgress(entries.count, entries.count)
        return (extracted, failed)
    }

    /// Carries a TAR entry's mode and modification date over to the file just
    /// written. Without the mode, a script or an app inside the archive comes
    /// out no longer executable. Only the permission bits are applied — never
    /// setuid/setgid/sticky from an archive someone else made — and a mode
    /// that would lock the owner out of their own file is left at the default.
    private static func applyAttributes(of info: TarEntryInfo, to url: URL) {
        var attributes: [FileAttributeKey: Any] = [:]
        if let permissions = info.permissions {
            let mode = Int(permissions.rawValue & 0o777)
            if mode & 0o400 != 0 {
                attributes[.posixPermissions] = mode
            }
        }
        if let modified = info.modificationTime, modified.timeIntervalSince1970 > 0 {
            attributes[.modificationDate] = modified
        }
        guard !attributes.isEmpty else { return }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}
