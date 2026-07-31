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

/// One pending change gathered by the view before the batch write.
struct EmbeddedWriteOp {
    /// The full exiftool tag path, e.g. `PNG:parameters` or `XMP-dc:Rights`.
    var writeTag: String
    /// The PNG keyword to register as a writable tag in the generated config,
    /// when this op targets a PNG text chunk. `nil` for XMP.
    var pngKeyword: String?
    /// The new value, or `nil` to delete the entry.
    var value: String?
}

enum EmbeddedWriteError: LocalizedError {
    case invalidKey(String)
    case nothingToWrite

    var errorDescription: String? {
        switch self {
        case .invalidKey(let key):
            return String(
                localized: "“\(key)” is not a valid key. Use letters, numbers and hyphens only.",
                comment: "Rejected metadata key. Placeholder is the entered key."
            )
        case .nothingToWrite:
            return String(localized: "No changes to write.")
        }
    }
}

enum EmbeddedMetadataWriter {

    /// Keys the user types are restricted to letters, numbers and hyphens, and
    /// must begin with a letter or number. That keeps the generated exiftool
    /// config free of any Perl-significant character and makes a leading-dash
    /// option such as `-all=` impossible to enter as a key.
    static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Writes a batch of changes in one exiftool run, so the `_original` backup
    /// is created at most once. Must be called off the main thread.
    static func write(_ ops: [EmbeddedWriteOp], to file: URL, exiftool: URL) throws -> ExifWriteOutcome {
        guard !ops.isEmpty else { throw EmbeddedWriteError.nothingToWrite }

        // Validate every PNG keyword before it can reach exiftool or the config.
        let pngKeywords = ops.compactMap(\.pngKeyword)
        for keyword in pngKeywords where !isValidKey(keyword) {
            throw EmbeddedWriteError.invalidKey(keyword)
        }

        // A config is only needed when PNG text tags are involved; XMP tags are
        // written natively by exiftool.
        let configFile = pngKeywords.isEmpty ? nil : try makeConfig(for: pngKeywords)
        defer { if let configFile { try? FileManager.default.removeItem(at: configFile) } }

        let assignments = ops.map { op -> String in
            if let value = op.value {
                return "-\(op.writeTag)=\(value)"
            } else {
                return "-\(op.writeTag)="
            }
        }

        return try ExifToolWrite.run(
            configFile: configFile,
            assignments: assignments,
            on: file,
            exiftool: exiftool
        )
    }

    /// Writes a temporary exiftool config that registers each keyword as a
    /// writable PNG textual-data tag. Without this, exiftool refuses to write
    /// keywords it does not already know (`prompt`, `workflow`, custom keys),
    /// answering "Tag not defined". Redefining a built-in keyword such as
    /// `parameters` here is harmless.
    private static func makeConfig(for keywords: [String]) throws -> URL {
        let unique = Set(keywords).sorted()
        let lines = unique.map { "    '\($0)' => { Writable => 'string' }," }.joined(separator: "\n")
        let config = """
        %Image::ExifTool::UserDefined = (
          'Image::ExifTool::PNG::TextualData' => {
        \(lines)
          },
        );
        1;
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mike-png-\(UUID().uuidString).config")
        try config.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
