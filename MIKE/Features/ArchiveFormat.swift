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
import UniformTypeIdentifiers

/// The two archive formats Compression reads and writes. RAR is deliberately
/// absent: neither SWCompression nor ZIPFoundation implement it at all, and
/// hand-rolling RAR's proprietary, patent-encumbered compression is out of
/// scope — this is the "leave it out" branch of the original requirement,
/// not an oversight.
enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip = "ZIP"
    case tarGz = "TAR.GZ"

    var id: String { rawValue }

    /// `.tar.gz` is checked before a plain `.gz` would ever be considered,
    /// and `.tgz` is the same format under its three-letter alias. Detection
    /// is by name only — MIKE never guesses a format from file content, the
    /// same rule Convert Format's batch mode follows for images.
    static func detect(from url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return .tarGz
        }
        if name.hasSuffix(".zip") {
            return .zip
        }
        return nil
    }

    /// The other format — used by Convert's target picker, which only ever
    /// offers the one format the detected source isn't already.
    var other: ArchiveFormat {
        switch self {
        case .zip: return .tarGz
        case .tarGz: return .zip
        }
    }

    /// The file name without this format's extension. Plain
    /// `deletingPathExtension()` only strips one component, which would
    /// leave a TAR.GZ's stem as `"name.tar"` — this strips the whole
    /// multi-part suffix instead.
    func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        let suffix = ".\(fileExtension)"
        if name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tarGz: return "tar.gz"
        }
    }

    /// For the open panel. TAR.GZ has no dedicated UTType, so `.gz` stands
    /// in for it — the panel is a convenience filter, not the actual format
    /// gate, which is `detect(from:)` on the chosen file's real name.
    var allowedContentTypes: [UTType] {
        switch self {
        case .zip:
            return [.zip]
        case .tarGz:
            return [UTType(filenameExtension: "gz"), UTType(filenameExtension: "tgz")].compactMap { $0 }
        }
    }
}
