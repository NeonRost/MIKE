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

/// A distinct audio bitrate the source actually offers, deduplicated by its
/// rounded kbit/s value — a source typically exposes the same rate more than
/// once across containers (e.g. Opus in WebM and AAC in M4A at similar rates).
struct AudioBitrateOption: Identifiable, Hashable, Sendable {
    let id: Int
    let codec: String

    var label: String { "\(id) kbit/s (\(codec))" }
}

/// A distinct video height the source actually offers, deduplicated by pixel
/// height regardless of codec (h264/vp9/av1 at the same height are the same
/// choice from the user's point of view).
struct VideoResolutionOption: Identifiable, Hashable, Sendable {
    let id: Int
    let fps: Int?

    var label: String {
        fps.map { "\(id)p\($0)" } ?? "\(id)p"
    }
}

struct FormatProbeResult: Sendable {
    /// Highest first.
    let audioBitrates: [AudioBitrateOption]
    /// Highest first.
    let videoResolutions: [VideoResolutionOption]
}

enum FormatProbeError: LocalizedError {
    case toolFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .toolFailed(let detail):
            return detail
        case .invalidResponse:
            return String(localized: "yt-dlp did not return usable format information for this URL.")
        }
    }
}

/// Asks yt-dlp what a URL actually offers, instead of MIKE guessing or
/// promising a number the source cannot back up. `-j` never writes a media
/// file — it prints the same per-format JSON yt-dlp's own `-f` selector reads
/// internally, so what this parses is exactly what a real download would
/// have been able to choose from.
enum FormatProbe {

    /// Blocks until yt-dlp exits, so call it off the main thread.
    static func run(urlString: String, ytDlp: URL) -> Result<FormatProbeResult, FormatProbeError> {
        var lines: [String] = []
        let status = ProcessRunner.stream(
            executable: ytDlp,
            arguments: ["-j", "--no-warnings", "--no-playlist", "--", urlString]
        ) { line in
            lines.append(line)
        }

        guard status == 0 else {
            return .failure(.toolFailed(errorDetail(from: lines, status: status)))
        }

        // yt-dlp prints exactly one JSON object per resolved video; with
        // --no-playlist there is always exactly one such line, but other
        // lines (warnings that slipped past --no-warnings, etc.) can precede
        // it.
        guard let jsonLine = lines.first(where: { $0.hasPrefix("{") }),
              let data = jsonLine.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formats = root["formats"] as? [[String: Any]]
        else {
            return .failure(.invalidResponse)
        }

        var audioSeen = Set<Int>()
        var audioOptions: [AudioBitrateOption] = []
        var videoSeen = Set<Int>()
        var videoOptions: [VideoResolutionOption] = []

        for format in formats {
            let vcodec = format["vcodec"] as? String
            let acodec = format["acodec"] as? String

            if vcodec == "none", let acodec, acodec != "none",
               let abr = number(format["abr"])?.doubleValue, abr > 0 {
                let rounded = Int(abr.rounded())
                if audioSeen.insert(rounded).inserted {
                    audioOptions.append(AudioBitrateOption(id: rounded, codec: acodec))
                }
            }
            if acodec == "none", let vcodec, vcodec != "none",
               let height = number(format["height"])?.intValue, height > 0 {
                if videoSeen.insert(height).inserted {
                    let fps = number(format["fps"])?.intValue
                    videoOptions.append(VideoResolutionOption(id: height, fps: fps))
                }
            }
        }

        guard !audioOptions.isEmpty || !videoOptions.isEmpty else {
            return .failure(.invalidResponse)
        }

        audioOptions.sort { $0.id > $1.id }
        videoOptions.sort { $0.id > $1.id }
        return .success(FormatProbeResult(audioBitrates: audioOptions, videoResolutions: videoOptions))
    }

    /// JSONSerialization bridges a whole-number JSON literal to both `Int`
    /// and `Double`, but a fractional one only bridges to `Double` — casting
    /// a fractional value `as? Int` fails outright rather than truncating.
    /// Going through `NSNumber` first sidesteps that and reads either shape
    /// correctly, verified directly against yt-dlp's actual output (`height`
    /// is always a whole number, `abr` almost never is).
    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    private static func errorDetail(from lines: [String], status: Int32) -> String {
        if let explicit = lines.last(where: {
            $0.lowercased().hasPrefix("error") || $0.contains("ERROR:")
        }) {
            return String(explicit.prefix(200))
        }
        if let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(last.prefix(200))
        }
        return String(localized: "Exit \(status)", comment: "yt-dlp ended with this exit code")
    }
}
