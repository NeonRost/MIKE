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

/// A "please stop" that can be raised on the main thread and read from the
/// queue doing the work. For in-process work with no `Process` to signal and
/// no `Task` to cancel — the loop checks it between files.
final class CancelFlag: @unchecked Sendable {
    private var raised = false
    private let lock = NSLock()

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return raised
    }

    func set() {
        lock.lock(); raised = true; lock.unlock()
    }
}

/// Rules for a name the user typed that is about to become a file name.
///
/// A typed name is not a path component until it has been checked: a slash
/// turns it into a path (`AC/DC` asks for a folder called `AC`), a colon is
/// what the Finder shows as a slash, a leading dot hides the file, and an
/// empty name leaves nothing but the extension — which is also a hidden file.
enum FileName {

    enum Problem {
        case empty
        case hidden
        case separator

        var message: String {
            switch self {
            case .empty:
                return String(localized: "The name would be empty.")
            case .hidden:
                return String(localized: "A name starting with a dot would hide the file.")
            case .separator:
                return String(localized: "A name cannot contain “/” or “:”.")
            }
        }
    }

    /// What is wrong with `stem` as a file name without its extension, if
    /// anything. For places that should refuse rather than quietly rewrite.
    static func problem(inStem stem: String) -> Problem? {
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains("/") || trimmed.contains(":") { return .separator }
        if trimmed.hasPrefix(".") { return .hidden }
        return nil
    }

    /// A usable stem made from whatever was typed, for places where the name
    /// is a label first and a file name second (a track title, an archive
    /// name): separators become hyphens, leading dots and control characters
    /// go, and an empty result falls back to `fallback`.
    static func sanitizedStem(_ raw: String, fallback: String) -> String {
        var name = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Well inside the 255-byte limit even for multi-byte text plus an
        // extension and a " (2)" suffix.
        if name.count > 120 { name = String(name.prefix(120)) }
        return name.isEmpty ? fallback : name
    }
}

/// Promoted out of `TextRecognizer` into `Shared` once Convert Format became a
/// second real consumer of "read whatever image is on the clipboard right
/// now" — the same move `FolderRow` went through earlier for the same reason.
enum ClipboardImage {

    /// The clipboard's image bytes, in whatever representation is present.
    /// `ImageConverter.load(from:)` reads either through ImageIO.
    static func data() -> Data? {
        let pasteboard = NSPasteboard.general
        return pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }
}
