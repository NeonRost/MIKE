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

enum VideoConcatError: LocalizedError {
    case noVideos
    case listUnwritable
    case ffmpegFailed(String)
    case incompatible([String])
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideos:
            return String(localized: "No videos found.")
        case .listUnwritable:
            return String(localized: "The file list could not be written.")
        // ffmpeg's own output, passed through untranslated.
        case .ffmpegFailed(let detail): return "ffmpeg: \(detail)"
        case .cancelled:
            return String(localized: "Cancelled.")
        case .incompatible(let reasons):
            let list = reasons.joined(separator: "; ")
            return String(
                localized: "These files cannot be joined without re-encoding: \(list)",
                comment: "Placeholder lists what differs per file"
            )
        }
    }
}

/// The stream layout of one input file, as far as it matters for stream-copy
/// joining.
struct MediaLayout: Equatable {
    var videoCodec: String?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var audioCodec: String?
    var sampleRate: Int?
    var channelLayout: String?

    var hasAudio: Bool { audioCodec != nil }

    var resolution: String? {
        guard let width, let height else { return nil }
        return "\(width)×\(height)"
    }

    /// Plain-language list of what differs from `reference`.
    func differences(from reference: MediaLayout) -> [String] {
        var found: [String] = []
        let none = String(localized: "none", comment: "No stream of this kind is present")
        let unknown = String(localized: "unknown", comment: "A property could not be read")

        if videoCodec != reference.videoCodec {
            found.append(String(
                localized: "video codec \(videoCodec ?? none) instead of \(reference.videoCodec ?? none)",
                comment: "Codec names are not translated"
            ))
        }
        if width != reference.width || height != reference.height {
            found.append(String(
                localized: "resolution \(resolution ?? unknown) instead of \(reference.resolution ?? unknown)"
            ))
        }
        if let a = frameRate, let b = reference.frameRate, abs(a - b) > 0.01 {
            let mine = String(format: "%.3g", a)
            let theirs = String(format: "%.3g", b)
            found.append(String(
                localized: "\(mine) fps instead of \(theirs) fps",
                comment: "fps stays as the unit abbreviation"
            ))
        }
        if hasAudio != reference.hasAudio {
            found.append(hasAudio
                ? String(localized: "has audio while the first file has none")
                : String(localized: "has no audio track"))
        } else if hasAudio, audioCodec != reference.audioCodec {
            found.append(String(
                localized: "audio codec \(audioCodec ?? none) instead of \(reference.audioCodec ?? none)",
                comment: "Codec names are not translated"
            ))
        } else if hasAudio, sampleRate != reference.sampleRate {
            found.append(String(
                localized: "audio at \(sampleRate ?? 0) Hz instead of \(reference.sampleRate ?? 0) Hz"
            ))
        } else if hasAudio, channelLayout != reference.channelLayout {
            found.append(String(
                localized: "audio \(channelLayout ?? "?") instead of \(reference.channelLayout ?? "?")",
                comment: "Channel layouts such as mono or stereo"
            ))
        }
        return found
    }
}

/// What a folder looks like before anything is joined.
struct ConcatPreflight {
    var files: [URL]
    /// File name → what makes it incompatible with the first file.
    var problems: [(file: String, reasons: [String])]

    var isJoinable: Bool { files.count >= 1 && problems.isEmpty }
}

enum VideoConcatenator {

    static let outputStem = "combined"
    static let outputExtension = "mp4"
    static var outputName: String { "\(outputStem).\(outputExtension)" }
    static let acceptedExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// Matches the output and every collision-avoiding variant of it, so a
    /// second run never picks up what a first run produced.
    static func isOutput(_ name: String) -> Bool {
        name.range(
            of: "^\(outputStem)( \\([0-9]+\\))?\\.\(outputExtension)$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Files that would be joined, in the order they will play. Sorted the
    /// way the Finder sorts, so `clip2` comes before `clip10`.
    static func candidates(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { url in
                guard acceptedExtensions.contains(url.pathExtension.lowercased()) else { return false }
                guard !isOutput(url.lastPathComponent) else { return false }
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    /// Reads one file's stream layout out of ffmpeg's own report. Uses
    /// `ffmpeg -i` rather than ffprobe so no fourth tool is required.
    static func layout(of file: URL, ffmpeg: URL) -> MediaLayout {
        var layout = MediaLayout()
        // `-i` without an output makes ffmpeg describe the file and exit
        // non-zero, which is expected here.
        guard let result = ProcessRunner.capture(
            executable: ffmpeg,
            arguments: ["-hide_banner", "-i", file.path],
            timeout: 15
        ) else { return layout }

        for line in result.output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.contains("Stream #") else { continue }

            if let range = text.range(of: "Video: "), layout.videoCodec == nil {
                layout.videoCodec = firstToken(after: range.upperBound, in: text)
                if let match = text.range(of: "[0-9]{2,5}x[0-9]{2,5}", options: .regularExpression) {
                    let parts = text[match].split(separator: "x")
                    layout.width = Int(parts[0])
                    layout.height = Int(parts[1])
                }
                if let match = text.range(of: "[0-9.]+ fps", options: .regularExpression) {
                    layout.frameRate = Double(text[match].replacingOccurrences(of: " fps", with: ""))
                }
            }

            if let range = text.range(of: "Audio: "), layout.audioCodec == nil {
                layout.audioCodec = firstToken(after: range.upperBound, in: text)
                if let match = text.range(of: "[0-9]+ Hz", options: .regularExpression) {
                    layout.sampleRate = Int(text[match].replacingOccurrences(of: " Hz", with: ""))
                }
                for candidate in ["mono", "stereo", "5.1", "7.1", "quad"] where text.contains(candidate) {
                    layout.channelLayout = candidate
                    break
                }
            }
        }
        return layout
    }

    private static func firstToken(after index: String.Index, in text: String) -> String {
        String(text[index...].prefix { !$0.isWhitespace && $0 != "," })
    }

    /// Checks a folder before anything runs.
    ///
    /// This matters because ffmpeg's concat demuxer exits 0 even when the
    /// inputs do not match: the result is then silently wrong — broken
    /// timestamps, a corrupt audio track, or a silent second half — rather
    /// than a failure the app could report.
    static func preflight(folder: URL, ffmpeg: URL) -> ConcatPreflight {
        preflight(files: candidates(in: folder), ffmpeg: ffmpeg)
    }

    /// Same check for a hand-picked, hand-ordered list. The first entry is the
    /// reference every other file has to match.
    static func preflight(files: [URL], ffmpeg: URL) -> ConcatPreflight {
        guard let first = files.first else {
            return ConcatPreflight(files: [], problems: [])
        }

        let reference = layout(of: first, ffmpeg: ffmpeg)
        var problems: [(file: String, reasons: [String])] = []

        for file in files.dropFirst() {
            let differences = layout(of: file, ffmpeg: ffmpeg).differences(from: reference)
            if !differences.isEmpty {
                problems.append((file: file.lastPathComponent, reasons: differences))
            }
        }
        return ConcatPreflight(files: files, problems: problems)
    }

    /// Everything in the folder, written back into that same folder.
    static func concatenate(folder: URL, ffmpeg: URL) throws -> URL {
        try concatenate(files: candidates(in: folder), into: folder, ffmpeg: ffmpeg)
    }

    /// Stream copy through ffmpeg's concat demuxer — no re-encode, so every
    /// input has to share the same codec and format. The list order is the
    /// play order.
    static func concatenate(
        files: [URL],
        into directory: URL,
        ffmpeg: URL,
        onStart: ((Process) -> Void)? = nil
    ) throws -> URL {
        guard !files.isEmpty else { throw VideoConcatError.noVideos }

        // Refuse rather than hand back a file that looks finished and is not.
        let check = preflight(files: files, ffmpeg: ffmpeg)
        if !check.problems.isEmpty {
            let reasons = check.problems.map { problem in
                let detail = ListFormatter.localizedString(byJoining: problem.reasons)
                // Nothing to translate here: a file name and already-localized reasons.
                return "\(problem.file) \(detail)"
            }
            throw VideoConcatError.incompatible(reasons)
        }

        // Kept out of the user's folder; the absolute paths inside make the
        // list's own location irrelevant to ffmpeg.
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mike-concat-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listURL) }

        let body = files
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: #"'\''"#))'" }
            .joined(separator: "\n") + "\n"

        do {
            try body.write(to: listURL, atomically: true, encoding: .utf8)
        } catch {
            throw VideoConcatError.listUnwritable
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Appends " (2)", " (3)", … rather than overwriting an earlier result.
        let target = ImageConverter.uniqueURL(
            directory: directory, stem: outputStem, extension: outputExtension
        )

        var lastLines: [String] = []
        var launched: Process?
        let status = ProcessRunner.stream(
            executable: ffmpeg,
            arguments: [
                "-y",
                "-f", "concat",
                "-safe", "0",
                "-i", listURL.path,
                "-c", "copy",
                target.path,
            ],
            onStart: { process in
                launched = process
                onStart?(process)
            }
        ) { line in
            lastLines.append(line)
            if lastLines.count > 20 { lastLines.removeFirst() }
        }

        guard status == 0 else {
            if launched?.terminationReason == .uncaughtSignal {
                // ffmpeg writes as it goes, so the half-built file has to go.
                try? FileManager.default.removeItem(at: target)
                throw VideoConcatError.cancelled
            }
            let detail = lastLines.last.map { String($0.prefix(140)) } ?? "exit \(status)"
            throw VideoConcatError.ffmpegFailed(detail)
        }

        return target
    }
}
