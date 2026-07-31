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

import AppKit
import Foundation

struct TextMergeResult {
    var text: String
    /// File names that could not be read as text, in the order they were
    /// encountered — reported once at the end, not as an abort.
    var skipped: [String]
}

enum TextMerger {

    /// Not a hard filter: the real gate is whether a file can be read as text
    /// at all. This only hints the file picker and the drop target.
    static let acceptedExtensions: Set<String> = ["txt", "md", "rtf", "csv", "log"]

    /// Combines the files in `files` (already in the desired order) into one
    /// text. A file that cannot be read as text is skipped, not fatal to the
    /// rest of the batch.
    static func merge(files: [URL], includeHeadings: Bool, separator: String) -> TextMergeResult {
        var sections: [String] = []
        var skipped: [String] = []

        for url in files {
            guard let content = readText(from: url) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            sections.append(includeHeadings ? url.lastPathComponent + "\n" + content : content)
        }

        return TextMergeResult(text: sections.joined(separator: separator), skipped: skipped)
    }

    /// Turns the separator field's typed value into the literal string used to
    /// join sections. Only `\n` and `\t` are recognized escapes — anything
    /// else (including a literal " --- ") passes through unchanged, so the
    /// field stays free text as specified, not just a newline shorthand.
    static func unescapeSeparator(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    /// Reads a file's textual content, or `nil` if it cannot be read as text
    /// at all (a genuine binary file, or bytes that decode under no attempted
    /// encoding).
    ///
    /// RTF is detected by its magic bytes (`{\rtf1`), not by file extension —
    /// an RTF file with no extension, or a renamed one, still reads correctly.
    /// RTF is not plain text; reading its bytes directly would put raw control
    /// words like `{\rtf1\ansi…}` into the merged output instead of the
    /// document's actual text, so it goes through `NSAttributedString` and only
    /// the plain content is kept — formatting is discarded, same as RTF output
    /// elsewhere in MIKE never invents formatting Vision or the source didn't
    /// have.
    static func readText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        if data.starts(with: rtfSignature) {
            guard let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) else { return nil }
            return attributed.string
        }

        var encoding: String.Encoding = .utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }

    private static let rtfSignature = Array("{\\rtf1".utf8)
}
