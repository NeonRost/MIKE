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

/// Download settings per host. `format` and `postprocessorArguments` are
/// carried over verbatim from the original — proven in practice — and never
/// change. `cappedFormat` is new and purely additive: it produces the same
/// selector with a height ceiling spliced in, used only when the user opts
/// out of "best available" and picks a concrete, probed resolution.
struct DownloadProfile: Sendable {
    let name: String
    let format: String
    let postprocessorArguments: String
    let cappedFormat: @Sendable (Int) -> String

    /// Re-encode, e.g. for YouTube: plays in QuickTime and iMessage.
    static let recode = DownloadProfile(
        name: "Standard",
        format: "bv[ext=mp4]+ba[ext=m4a]/best[ext=mp4]",
        postprocessorArguments: "ffmpeg:-c:v libx264 -c:a aac -movflags +faststart -pix_fmt yuv420p",
        cappedFormat: { height in
            "bv[ext=mp4][height<=\(height)]+ba[ext=m4a]/best[ext=mp4][height<=\(height)]"
        }
    )

    /// Rewrap only, for TikTok and Instagram: keeps the original quality.
    static let rewrap = DownloadProfile(
        name: "Rewrap",
        format: "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/best",
        postprocessorArguments: "ffmpeg:-c copy -movflags +faststart",
        cappedFormat: { height in
            "bv*[ext=mp4][height<=\(height)]+ba[ext=m4a]/b[ext=mp4][height<=\(height)]/best[height<=\(height)]"
        }
    )

    static func forURL(_ urlString: String) -> DownloadProfile {
        let host = URL(string: urlString)?.host?.lowercased() ?? ""

        if host.contains("tiktok.com") {
            return DownloadProfile(
                name: "TikTok",
                format: rewrap.format,
                postprocessorArguments: rewrap.postprocessorArguments,
                cappedFormat: rewrap.cappedFormat
            )
        }
        if host.contains("instagram.com") {
            return DownloadProfile(
                name: "Instagram",
                format: rewrap.format,
                postprocessorArguments: rewrap.postprocessorArguments,
                cappedFormat: rewrap.cappedFormat
            )
        }
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return DownloadProfile(
                name: "YouTube",
                format: recode.format,
                postprocessorArguments: recode.postprocessorArguments,
                cappedFormat: recode.cappedFormat
            )
        }
        return recode
    }
}

/// Audio-only targets for `-x`. The menu label and the value yt-dlp actually
/// wants differ exactly once: yt-dlp has no `ogg` literal, only `vorbis` —
/// which is what produces the `.ogg` file — verified against `yt-dlp --help`
/// rather than assumed from the menu label.
enum AudioFormat: String, CaseIterable, Identifiable, Sendable {
    case mp3 = "MP3"
    case m4a = "M4A"
    case aac = "AAC"
    case opus = "OPUS"
    case flac = "FLAC"
    case wav = "WAV"
    case ogg = "OGG"

    var id: String { rawValue }

    var ytDlpValue: String {
        self == .ogg ? "vorbis" : rawValue.lowercased()
    }

    /// FLAC and WAV carry no bitrate concept — verified directly: yt-dlp
    /// still passes `-b:a` through to ffmpeg for both, but ffmpeg's flac and
    /// pcm encoders silently ignore it, so "Best" and a concrete probed
    /// bitrate produce byte-identical files. The quality picker is
    /// meaningless here, not just cosmetically redundant.
    var isLossless: Bool {
        self == .flac || self == .wav
    }
}

/// What to actually download: a site profile's re-encode/rewrap settings
/// (optionally capped at a probed, genuinely available height), or an
/// audio-only extraction (optionally at a probed, genuinely available
/// bitrate). Kept as one parameter to `DownloadRunner.run` rather than
/// several optionals so the call site can never pass an inconsistent
/// combination.
///
/// `nil` for the height/bitrate means "best available" — yt-dlp's own
/// unconstrained selector, exactly today's default behavior. A concrete
/// value only ever comes from a real `FormatProbe` result for this exact
/// URL, never a number MIKE invents: promising a fixed audio bitrate or
/// video resolution the source cannot actually deliver would be a lie the
/// user has no way to catch until the file is already on disk.
enum DownloadMode {
    case video(DownloadProfile, maxHeight: Int?)
    case audio(format: AudioFormat, bitrate: Int?)
}

enum DownloadOutcome {
    case finished
    case cancelled
    case failed(String)
}

enum DownloadRunner {

    private static let postprocessMarkers = [
        "[Merger]", "[ExtractAudio]", "[VideoConvertor]", "[FixupM4a]",
        "[Fixup", "[Metadata]", "[ffmpeg]", "Deleting original",
    ]

    /// Blocks until yt-dlp exits, so call it off the main thread.
    ///
    /// - Parameter onProgress: percentage text while downloading, then `nil`
    ///   once post-processing starts.
    static func run(
        urlString: String,
        into directory: URL,
        mode: DownloadMode,
        ytDlp: URL,
        ffmpeg: URL?,
        onStart: ((Process) -> Void)? = nil,
        onProgress: @escaping (String?) -> Void
    ) -> DownloadOutcome {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed("The output folder could not be created.")
        }

        let template = directory.appendingPathComponent("%(title)s.%(ext)s").path

        // Argument order matches the original, including --ffmpeg-location
        // sitting in front of -f.
        var arguments: [String] = []
        if let ffmpeg {
            arguments += ["--ffmpeg-location", ffmpeg.path]
        }
        switch mode {
        case .video(let profile, let maxHeight):
            let format = maxHeight.map(profile.cappedFormat) ?? profile.format
            arguments += [
                "-f", format,
                "--merge-output-format", "mp4",
                "--postprocessor-args", profile.postprocessorArguments,
                "-o", template,
                "--newline",
                "--no-colors",
                // Ends option parsing. Without it a string beginning with a dash
                // would be read as an option — and yt-dlp has options such as
                // --exec that run shell commands.
                "--",
                urlString,
            ]
        case .audio(let format, let bitrate):
            // A concrete bitrate (from a real probe) is passed as e.g. "128K" —
            // yt-dlp/ffmpeg then target that exact rate instead of the 0…10 VBR
            // quality scale. "Best" stays on the VBR scale (0), same as before.
            let quality = bitrate.map { "\($0)K" } ?? "0"
            arguments += [
                "-x",
                "--audio-format", format.ytDlpValue,
                "--audio-quality", quality,
                "-o", template,
                "--newline",
                "--no-colors",
                "--",
                urlString,
            ]
        }

        var environment = ProcessInfo.processInfo.environment
        // Progress parsing depends on a decimal point.
        environment["LC_ALL"] = environment["LC_ALL"] ?? "en_US.UTF-8"
        var searchPath = [ytDlp.deletingLastPathComponent().path]
        if let ffmpeg {
            searchPath.append(ffmpeg.deletingLastPathComponent().path)
        }
        if let existing = environment["PATH"] {
            searchPath.append(existing)
        }
        environment["PATH"] = searchPath.joined(separator: ":")

        var tail: [String] = []
        var inPostprocessing = false
        var lastPercent = ""
        // Every file yt-dlp says it is writing, so a cancelled run can clean up
        // exactly its own leftovers and nothing else in the folder.
        var destinations: [URL] = []

        // Kept so the exit can be told apart afterwards: a process we asked to
        // stop dies by signal, a failing one exits with a code.
        var launched: Process?

        let status = ProcessRunner.stream(
            executable: ytDlp,
            arguments: arguments,
            environment: environment,
            onStart: { process in
                launched = process
                onStart?(process)
            }
        ) { line in
            tail.append(line)
            if let destination = destination(in: line) {
                destinations.append(destination)
            }
            if tail.count > 30 { tail.removeFirst() }

            if !inPostprocessing,
               postprocessMarkers.contains(where: { line.contains($0) })
                || looksLikeFFmpegProgress(line) {
                inPostprocessing = true
                onProgress(nil)
                return
            }
            guard !inPostprocessing else { return }

            if let percent = percentage(in: line), percent != lastPercent {
                lastPercent = percent
                if percent.hasPrefix("100") {
                    inPostprocessing = true
                    onProgress(nil)
                } else {
                    onProgress(percent)
                }
            }
        }

        guard status == 0 else {
            if launched?.terminationReason == .uncaughtSignal {
                removePartialFiles(for: destinations)
                return .cancelled
            }
            return .failed(errorMessage(from: tail, status: status))
        }
        return .finished
    }

    /// yt-dlp announces each file as `[download] Destination: /path/to/file`.
    private static func destination(in line: String) -> URL? {
        guard let range = line.range(of: "[download] Destination: ") else { return nil }
        let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Removes the half-written files belonging to the destinations this run
    /// announced — never a blanket sweep of the folder, where another download
    /// may well be in progress.
    private static func removePartialFiles(for destinations: [URL]) {
        let manager = FileManager.default
        for destination in destinations {
            let base = destination.path
            var candidates = ["\(base).part", "\(base).ytdl"]

            // Fragmented downloads leave numbered pieces next to the .part.
            let folder = destination.deletingLastPathComponent()
            let prefix = destination.lastPathComponent + ".part-Frag"
            if let entries = try? manager.contentsOfDirectory(atPath: folder.path) {
                candidates += entries
                    .filter { $0.hasPrefix(prefix) }
                    .map { folder.appendingPathComponent($0).path }
            }

            for path in candidates where manager.fileExists(atPath: path) {
                try? manager.removeItem(atPath: path)
            }
        }
    }

    private static func looksLikeFFmpegProgress(_ line: String) -> Bool {
        line.contains("frame=") || line.contains("size=") || line.contains("time=")
    }

    /// Matches yt-dlp's "  53.2% of ..." progress output.
    private static func percentage(in line: String) -> String? {
        guard let range = line.range(
            of: "[0-9]{1,3}\\.[0-9]%",
            options: .regularExpression
        ) else { return nil }
        return String(line[range])
    }

    private static func errorMessage(from tail: [String], status: Int32) -> String {
        if let explicit = tail.last(where: {
            $0.lowercased().hasPrefix("error") || $0.contains("ERROR:")
        }) {
            return String(explicit.prefix(140))
        }
        if let last = tail.last {
            return String(last.prefix(140))
        }
        return String(localized: "Exit \(status)", comment: "yt-dlp ended with this exit code")
    }
}
