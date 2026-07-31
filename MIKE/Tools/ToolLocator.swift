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

enum Tool: String, CaseIterable, Identifiable, Sendable {
    case ytDlp
    case ffmpeg
    case cwebp
    case exiftool

    var id: String { rawValue }

    var executableName: String {
        switch self {
        case .ytDlp: return "yt-dlp"
        case .ffmpeg: return "ffmpeg"
        case .cwebp: return "cwebp"
        case .exiftool: return "exiftool"
        }
    }

    /// yt-dlp wants a double dash, ffmpeg and cwebp a single one, and exiftool
    /// spells it `-ver` — `-version` would be read as a tag name there.
    var versionArgument: String {
        switch self {
        case .ytDlp: return "--version"
        case .ffmpeg, .cwebp: return "-version"
        case .exiftool: return "-ver"
        }
    }

    /// Neither of these carries a whole section: cwebp is only needed for WebP
    /// export, exiftool only for editing and removing metadata. Their absence
    /// greys out a part of a section instead of disabling it.
    var isOptional: Bool { self == .cwebp || self == .exiftool }

    var purpose: String? {
        switch self {
        case .cwebp:
            return String(
                localized: "Optional — only needed for WebP export.",
                comment: "Shown under the cwebp entry in Tools"
            )
        case .exiftool:
            return String(
                localized: "Optional — only needed for editing and removing metadata. Reading works without it.",
                comment: "Shown under the exiftool entry in Tools"
            )
        case .ytDlp, .ffmpeg: return nil
        }
    }

    var downloadPage: URL {
        switch self {
        case .ytDlp: return URL(string: "https://github.com/yt-dlp/yt-dlp/releases")!
        case .ffmpeg: return URL(string: "https://ffmpeg.org/download.html")!
        case .cwebp: return URL(string: "https://developers.google.com/speed/webp/download")!
        case .exiftool: return URL(string: "https://exiftool.org")!
        }
    }

    var customPathDefaultsKey: String { "CustomPath.\(executableName)" }
}

struct ToolStatus: Sendable {
    enum Origin: Sendable {
        case custom
        case standard
        case missing
    }

    var url: URL?
    var version: String?
    var origin: Origin
    /// A custom path was entered but does not run — worth saying out loud
    /// instead of silently using a standard location instead.
    var customPathFailed: Bool = false
    /// ffmpeg only: whether this particular build can encode WebP. Homebrew's
    /// stock ffmpeg is built without libwebp, so having ffmpeg at all is not
    /// enough to promise WebP export.
    var supportsWebP: Bool = false

    var isAvailable: Bool { url != nil }

    static let missing = ToolStatus(url: nil, version: nil, origin: .missing)
}

enum ToolLocator {

    /// Apps launched from the Finder do not inherit the shell's PATH, so these
    /// are probed as absolute paths rather than resolved through the
    /// environment.
    static let standardDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    static func locate(_ tool: Tool, customPath: String?) -> ToolStatus {
        var customFailed = false

        if let customPath, !customPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (customPath.trimmingCharacters(in: .whitespaces) as NSString)
                .expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if let version = probe(tool, at: url) {
                return ToolStatus(
                    url: url,
                    version: version,
                    origin: .custom,
                    supportsWebP: hasWebPEncoder(tool, at: url)
                )
            }
            customFailed = true
        }

        for directory in standardDirectories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(tool.executableName)
            if let version = probe(tool, at: url) {
                return ToolStatus(
                    url: url,
                    version: version,
                    origin: .standard,
                    customPathFailed: customFailed,
                    supportsWebP: hasWebPEncoder(tool, at: url)
                )
            }
        }

        return ToolStatus(url: nil, version: nil, origin: .missing, customPathFailed: customFailed)
    }

    /// Homebrew's own two install locations: Apple Silicon first, then the
    /// Intel path that older machines and older installs still use.
    private static let homebrewPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    /// Homebrew is deliberately not part of `Tool`: MIKE never calls it and
    /// works fine without it. It is probed only so the Setup section can tell
    /// whether the `brew install` line it offers would actually work.
    static func locateHomebrew() -> ToolStatus {
        for path in homebrewPaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let result = ProcessRunner.capture(
                executable: url,
                arguments: ["--version"],
                timeout: 10
            ), result.status == 0 else { continue }

            // "Homebrew 6.0.13" → "6.0.13"
            let firstLine = result.output
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let version = firstLine
                .replacingOccurrences(of: "Homebrew ", with: "")
                .trimmingCharacters(in: .whitespaces)

            return ToolStatus(
                url: url,
                version: version.isEmpty ? nil : version,
                origin: .standard
            )
        }
        return .missing
    }

    /// ffmpeg ships in many configurations; the stock Homebrew build has no
    /// libwebp, so the encoder list has to be asked rather than assumed.
    ///
    /// Asking is expensive — `-encoders` prints hundreds of lines — and the
    /// answer only changes when the binary does. It is therefore remembered
    /// against the binary's path and modification date, so a `brew upgrade`
    /// (new date) or a different custom path (new path) re-checks, while
    /// switching back to MIKE a hundred times does not.
    private static func hasWebPEncoder(_ tool: Tool, at url: URL) -> Bool {
        guard tool == .ffmpeg else { return false }

        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0 }
        let stamp = modified.map { String(Int($0.timeIntervalSince1970)) } ?? "?"
        let key = "FFmpegWebP.\(url.path)"

        let defaults = UserDefaults.standard
        if let cached = defaults.dictionary(forKey: key),
           cached["stamp"] as? String == stamp,
           let supported = cached["supported"] as? Bool {
            return supported
        }

        guard let result = ProcessRunner.capture(
            executable: url,
            arguments: ["-hide_banner", "-encoders"],
            timeout: 8
        ), result.status == 0 else {
            // A failed probe is not remembered: the next check should try again.
            return false
        }

        let supported = result.output.contains("libwebp")
        defaults.set(["stamp": stamp, "supported": supported], forKey: key)
        return supported
    }

    /// A binary only counts once it actually runs. The executable bit alone is
    /// not enough: quarantined downloads and architecture mismatches pass that
    /// check and then fail the moment they are used for real.
    private static func probe(_ tool: Tool, at url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }

        guard let result = ProcessRunner.capture(
            executable: url,
            arguments: [tool.versionArgument]
        ), result.status == 0 else { return nil }

        return parseVersion(tool, from: result.output)
    }

    static func parseVersion(_ tool: Tool, from output: String) -> String? {
        let firstLine = output
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)

        guard let firstLine, !firstLine.isEmpty else { return nil }

        switch tool {
        case .ytDlp, .cwebp, .exiftool:
            // All three print a bare version number on the first line.
            return firstLine
        case .ffmpeg:
            // "ffmpeg version 7.1.1-tessus  https://evermeet.cx/..." → "7.1.1-tessus"
            guard let range = firstLine.range(of: "ffmpeg version ") else { return firstLine }
            let rest = firstLine[range.upperBound...]
            return rest.split(separator: " ").first.map(String.init) ?? firstLine
        }
    }
}
