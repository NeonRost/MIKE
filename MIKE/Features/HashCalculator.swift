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

import CryptoKit
import Foundation

struct FileHashes: Equatable {
    let md5: String
    let sha1: String
    let sha256: String
    let sha512: String
}

enum HashCalculationError: Error {
    case cancelled
    case cannotOpen
}

enum HashCalculator {
    /// Read in chunks rather than `Data(contentsOf:)` so a multi-gigabyte file
    /// is streamed through, never held whole in memory.
    private static let chunkSize = 4 * 1024 * 1024

    /// All four digests in one streaming pass over the file. `onProgress` is
    /// called on whatever thread this runs on — callers hop back to the main
    /// actor themselves, the same way every other background computation in
    /// this app does.
    static func hash(file url: URL, onProgress: @escaping (Double) -> Void) throws -> FileHashes {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw HashCalculationError.cannotOpen
        }
        defer { try? handle.close() }

        let totalSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize

        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        var sha512 = SHA512()

        var processed = 0
        // Only reported on a whole-percent change, so a huge file does not
        // flood the main actor with hundreds of near-identical updates.
        var lastReportedPercent = -1

        while true {
            if Task.isCancelled { throw HashCalculationError.cancelled }
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }

            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
            sha512.update(data: chunk)

            processed += chunk.count
            if let totalSize, totalSize > 0 {
                let percent = Int((Double(processed) / Double(totalSize)) * 100)
                if percent != lastReportedPercent {
                    lastReportedPercent = percent
                    onProgress(Double(processed) / Double(totalSize))
                }
            }
        }

        onProgress(1)
        return FileHashes(
            md5: hex(md5.finalize()),
            sha1: hex(sha1.finalize()),
            sha256: hex(sha256.finalize()),
            sha512: hex(sha512.finalize())
        )
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 only, for callers such as Find Duplicates that compare many
    /// files by content and don't need MD5/SHA-1/SHA-512 alongside it —
    /// computing all four for every candidate would be wasted work at scale.
    /// No progress callback: callers that need progress report it themselves
    /// at the per-file level, not per-byte within one file.
    static func sha256(file url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw HashCalculationError.cannotOpen
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            if Task.isCancelled { throw HashCalculationError.cancelled }
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }
}
