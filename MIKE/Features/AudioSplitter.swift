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

struct SilenceInterval: Equatable {
    var start: Double
    var end: Double
}

struct SilenceAnalysis {
    var duration: Double
    /// Every silence ffmpeg reported, edge artifacts included — `trackRanges`
    /// is what actually matters for splitting; this is kept for display.
    var silences: [SilenceInterval]
}

struct TrackRange: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
}

enum AudioSplitError: LocalizedError {
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let detail): return "ffmpeg: \(detail)"
        }
    }
}

enum AudioSplitter {

    static let acceptedExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "ogg", "wav"]

    /// Silence in the first or last two seconds of the file is treated as
    /// ordinary rip padding, not a real track boundary — an album side or
    /// cassette rip almost always has some. Two seconds is a fixed buffer
    /// rather than a setting: the two sliders that do matter (threshold,
    /// minimum duration) are enough knobs for one screen.
    static let edgeBuffer: Double = 2.0

    // MARK: - Analysis

    /// Runs `-af silencedetect` and reports the file's duration and every
    /// detected silence. Must be called off the main thread.
    static func analyze(
        file: URL,
        thresholdDB: Double,
        minDuration: Double,
        ffmpeg: URL
    ) -> SilenceAnalysis? {
        guard let result = ProcessRunner.capture(
            executable: ffmpeg,
            arguments: [
                "-i", file.path,
                "-af", "silencedetect=noise=\(thresholdDB)dB:d=\(minDuration)",
                "-f", "null", "-",
            ],
            // Generous: silencedetect decodes far faster than real time in
            // practice, but a long album-side rip on a slow machine should
            // never be mistaken for a hang.
            timeout: 300
        ) else { return nil }

        guard let duration = parseDuration(result.output) else { return nil }
        return SilenceAnalysis(duration: duration, silences: parseSilences(result.output))
    }

    /// `Duration: 00:00:14.00, ...` from the `-i` banner.
    private static func parseDuration(_ text: String) -> Double? {
        guard let match = text.range(
            of: #"Duration: (\d+):(\d+):(\d+\.\d+)"#, options: .regularExpression
        ) else { return nil }
        let parts = text[match]
            .replacingOccurrences(of: "Duration: ", with: "")
            .split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Pairs up `silence_start: N` / `silence_end: N | silence_duration: N`
    /// lines. Values sometimes print without a decimal point (`silence_start:
    /// 0`, `silence_end: 14`), so the pattern matches digits with an optional
    /// fractional part rather than assuming one.
    private static func parseSilences(_ text: String) -> [SilenceInterval] {
        var starts: [Double] = []
        var ends: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let value = firstNumber(in: line, after: "silence_start:") {
                starts.append(value)
            } else if let value = firstNumber(in: line, after: "silence_end:") {
                ends.append(value)
            }
        }
        return zip(starts, ends).map { SilenceInterval(start: $0, end: $1) }
    }

    private static func firstNumber(in line: Substring, after marker: String) -> Double? {
        guard let markerRange = line.range(of: marker) else { return nil }
        guard let numberRange = line.range(
            of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression, range: markerRange.upperBound..<line.endIndex
        ) else { return nil }
        return Double(line[numberRange])
    }

    // MARK: - Track boundaries

    /// Turns detected silences into track ranges, dropping any silence that
    /// falls within `edgeBuffer` of either end of the file — see `edgeBuffer`.
    /// Every silence is treated as a real cut point otherwise: no attempt is
    /// made to detect or trim silence within a track.
    static func trackRanges(duration: Double, silences: [SilenceInterval]) -> [TrackRange] {
        let cuts = silences
            .filter { $0.start >= edgeBuffer && $0.end <= duration - edgeBuffer }
            .sorted { $0.start < $1.start }

        guard !cuts.isEmpty else { return [] }

        var ranges: [TrackRange] = []
        var cursor = 0.0
        for cut in cuts {
            ranges.append(TrackRange(start: cursor, end: cut.start))
            cursor = cut.end
        }
        ranges.append(TrackRange(start: cursor, end: duration))
        return ranges
    }

    // MARK: - Cutting

    /// Cuts one track out, stream copy only, no re-encoding. `-ss`/`-to`
    /// before `-c copy` lands on the nearest frame boundary rather than the
    /// exact sample for compressed formats — verified against a real MP3 to
    /// be within tens of milliseconds, not audibly broken.
    static func cut(
        source: URL,
        range: TrackRange,
        to destination: URL,
        ffmpeg: URL,
        onStart: ((Process) -> Void)? = nil
    ) throws {
        var lastLines: [String] = []
        var launched: Process?
        let status = ProcessRunner.stream(
            executable: ffmpeg,
            arguments: [
                "-y",
                "-ss", String(format: "%.3f", range.start),
                "-to", String(format: "%.3f", range.end),
                "-i", source.path,
                "-c", "copy",
                destination.path,
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
                // ffmpeg writes as it goes; a killed cut leaves a half-built
                // file that has to go, unlike the tracks finished earlier.
                try? FileManager.default.removeItem(at: destination)
                throw CancellationError()
            }
            let detail = lastLines.last.map { String($0.prefix(140)) } ?? "exit \(status)"
            throw AudioSplitError.ffmpegFailed(detail)
        }
    }

    // MARK: - Naming

    /// Expands `%n` (zero-padded track number) and `%t` (track count) in a
    /// user-typed pattern, for every track at once.
    static func applyPattern(_ pattern: String, trackCount: Int) -> [String] {
        let width = max(2, String(trackCount).count)
        return (1...max(trackCount, 0)).compactMap { index in
            guard trackCount > 0 else { return nil }
            let number = String(format: "%0\(width)d", index)
            return pattern
                .replacingOccurrences(of: "%n", with: number)
                .replacingOccurrences(of: "%t", with: String(trackCount))
        }
    }

    static func defaultNames(trackCount: Int) -> [String] {
        applyPattern("track_%n", trackCount: trackCount)
    }
}
