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

enum EncodingConversionError: LocalizedError {
    case cannotDecode

    var errorDescription: String? {
        switch self {
        case .cannotDecode:
            return String(localized: "The file could not be read with this source encoding.")
        }
    }
}

enum EncodingConverter {

    /// Foundation's best-effort automatic detection, used only to pre-select
    /// the source encoding picker — never trusted silently, since detection
    /// can guess wrong on short or ambiguous files. Falls back to UTF-8 when
    /// nothing could be detected at all, so the picker always starts somewhere
    /// sensible.
    static func detectEncoding(of url: URL) -> String.Encoding {
        var encoding: String.Encoding = .utf8
        _ = try? String(contentsOf: url, usedEncoding: &encoding)
        return encoding
    }

    /// Decodes the file's raw bytes with the chosen source encoding. A wrong
    /// source encoding either fails outright (an invalid byte sequence for
    /// that encoding) or "succeeds" with garbled characters — both are
    /// signals the preview is meant to surface, not hide.
    static func decode(_ url: URL, as encoding: String.Encoding) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: encoding) else {
            throw EncodingConversionError.cannotDecode
        }
        return text
    }

    /// Counts the characters in `text` that cannot be losslessly represented in
    /// `encoding` — per user-perceived character (grapheme cluster), so one
    /// emoji counts as one, not as however many Unicode scalars it is made of.
    static func unrepresentableCharacterCount(_ text: String, in encoding: String.Encoding) -> Int {
        text.reduce(into: 0) { count, character in
            if String(character).data(using: encoding, allowLossyConversion: false) == nil {
                count += 1
            }
        }
    }

    /// Encodes `text` with `encoding`, losslessly. `nil` means at least one
    /// character cannot be represented — callers check
    /// `unrepresentableCharacterCount` first to explain why, rather than
    /// falling back to a lossy write that would silently substitute `?`.
    static func encode(_ text: String, as encoding: String.Encoding) -> Data? {
        text.data(using: encoding, allowLossyConversion: false)
    }
}
