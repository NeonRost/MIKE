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

enum VideoTrimError: LocalizedError {
    case cannotReadDuration
    case ffmpegFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cannotReadDuration:
            return String(localized: "The video's duration could not be read.")
        // ffmpeg's own output, passed through untranslated.
        case .ffmpegFailed(let detail): return "ffmpeg: \(detail)"
        case .cancelled:
            return String(localized: "Cancelled.")
        }
    }
}

enum VideoTrimmer {

    static let acceptedExtensions: Set<String> = ["mp4", "mov", "mkv", "m4v", "avi", "wmv", "flv"]

    /// Reads the file's total duration straight from ffmpeg's own probe
    /// banner (`-i` with no output, same technique `VideoConcatenator.layout`
    /// uses for codec info) — works for every accepted format, including ones
    /// AVFoundation cannot open at all. Verified directly: for an AVI file,
    /// `AVURLAsset.load(.duration)` throws "Cannot Open" while `ffmpeg -i`
    /// reports its `Duration:` line without issue, because ffmpeg's own AVI
    /// demuxer has nothing to do with AVFoundation's system codec support.
    static func duration(of file: URL, ffmpeg: URL) -> TimeInterval? {
        guard let result = ProcessRunner.capture(
            executable: ffmpeg,
            arguments: ["-hide_banner", "-i", file.path],
            timeout: 15
        ) else { return nil }

        for line in result.output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "Duration: ") else { continue }
            let rest = line[range.upperBound...]
            guard let comma = rest.firstIndex(of: ",") else { continue }
            return parseTimecode(String(rest[rest.startIndex..<comma]))
        }
        return nil
    }

    /// Parses ffmpeg-style "HH:MM:SS.ss" into seconds.
    static func parseTimecode(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// "HH:MM:SS.s" — one decimal digit, the precision shown in the Start/End
    /// fields and passed to ffmpeg's `-ss`/`-to`.
    static func formatTimecode(_ seconds: TimeInterval) -> String {
        let totalTenths = Int((max(0, seconds) * 10).rounded())
        let hours = totalTenths / 36000
        let minutes = (totalTenths / 600) % 60
        let secs = (totalTenths / 10) % 60
        let tenth = totalTenths % 10
        return String(format: "%02d:%02d:%02d.%d", hours, minutes, secs, tenth)
    }

    /// Stream copy through `-ss`/`-to` *before* `-i` — faster than seeking
    /// after input, and with `-c copy` there is no re-encode to make up for
    /// the resulting keyframe-snap, so the tiny timing imprecision is the
    /// accepted trade-off, not a bug.
    static func trim(
        input: URL,
        start: TimeInterval,
        end: TimeInterval,
        into directory: URL,
        ffmpeg: URL,
        onStart: ((Process) -> Void)? = nil,
        onProgress: @escaping (Double?) -> Void
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = "\(input.deletingPathExtension().lastPathComponent)_trim"
        let target = ImageConverter.uniqueURL(directory: directory, stem: stem, extension: input.pathExtension)
        let clipLength = max(end - start, 0.001)

        var lastLines: [String] = []
        var launched: Process?
        let status = ProcessRunner.stream(
            executable: ffmpeg,
            arguments: [
                "-y",
                "-ss", formatTimecode(start),
                "-to", formatTimecode(end),
                "-i", input.path,
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
            if let time = progressTime(in: line) {
                onProgress(min(time / clipLength, 1))
            }
        }

        guard status == 0 else {
            if launched?.terminationReason == .uncaughtSignal {
                // ffmpeg writes as it goes, so the half-built file has to go.
                try? FileManager.default.removeItem(at: target)
                throw VideoTrimError.cancelled
            }
            let detail = lastLines.last.map { String($0.prefix(140)) } ?? "exit \(status)"
            throw VideoTrimError.ffmpegFailed(detail)
        }

        return target
    }

    /// Matches ffmpeg's own progress line, e.g. "...time=00:00:02.50...".
    /// A `-c copy` trim is fast enough that this may fire once or not at all
    /// before the process exits — the caller has to handle both.
    private static func progressTime(in line: String) -> TimeInterval? {
        guard let range = line.range(of: "time=[0-9:.]+", options: .regularExpression) else { return nil }
        return parseTimecode(String(line[range].dropFirst(5)))
    }
}
