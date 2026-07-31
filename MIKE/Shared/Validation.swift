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

enum WebURL {

    /// The input has to parse as an http or https URL with a host.
    ///
    /// This is a security check, not just a convenience one. The download URL
    /// is handed to `yt-dlp` as an argument, and yt-dlp reads anything starting
    /// with a dash as an option — including options such as `--exec`, which run
    /// shell commands. Parsing rather than pattern-matching means a value only
    /// gets through if it really is a web address.
    static func isValid(_ text: String) -> Bool {
        parsed(text) != nil
    }

    /// The validated URL, or `nil` if the input is not usable.
    static func parsed(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              // No whitespace: a "URL" carrying spaces is either a mistake or
              // an attempt to smuggle a second argument in.
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return nil }
        return url
    }

    /// First URL found in the clipboard, used to pre-fill the download field.
    static func fromClipboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        guard let range = text.range(of: "https?://\\S+", options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
