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

/// Converts one archive to another format as a two-phase pipeline: extract
/// into a private temporary folder, then pack that folder's contents into
/// the target format. Neither library offers a direct format-to-format
/// transcode, and there is no simpler path — every entry has to be fully
/// materialized on disk between formats regardless.
enum ArchiveConverter {
    static func convert(
        archive: URL,
        sourceFormat: ArchiveFormat,
        to targetFormat: ArchiveFormat,
        destinationArchive: URL,
        onExtractProgress: @escaping (Int, Int) -> Void,
        onPackProgress: @escaping (Int, Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MIKE-Compression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try ArchiveExtractor.extract(
            archive: archive,
            format: sourceFormat,
            to: tempDir,
            onProgress: onExtractProgress,
            isCancelled: isCancelled
        )

        if isCancelled() { throw CompressionError.cancelled }

        let topLevelItems = (try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        try ArchiveBuilder.create(
            format: targetFormat,
            from: topLevelItems,
            to: destinationArchive,
            onProgress: onPackProgress,
            isCancelled: isCancelled
        )
    }
}
