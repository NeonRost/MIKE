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

/// The one error type Extract/Build/Convert throw. Raw errors from
/// ZIPFoundation or SWCompression are always mapped into one of these —
/// never shown to the user directly — so the section reads the same
/// "clear cause, not a stack trace" way the rest of MIKE does.
enum CompressionError: LocalizedError {
    case unrecognizedFormat
    case corrupted(ArchiveFormat)
    /// ZIPFoundation has no API to report this after the fact — see
    /// `ZipEncryptionScan` for why MIKE checks for it itself before ever
    /// asking ZIPFoundation to open the file.
    case passwordProtected
    case cancelled
    case io(String)

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return String(localized: "This file's format was not recognised. Only .zip and .tar.gz/.tgz are supported.")
        case .corrupted(let format):
            return String(
                localized: "This does not look like a valid \(format.rawValue) archive, or it is damaged.",
                comment: "Placeholder is an archive format name such as ZIP or TAR.GZ, not translated"
            )
        case .passwordProtected:
            return String(localized: "This archive is password-protected, which is not supported.")
        case .cancelled:
            return String(localized: "Cancelled.")
        case .io(let detail):
            return detail
        }
    }
}
