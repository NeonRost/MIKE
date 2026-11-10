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

enum TagField: String, CaseIterable {
    case title, artist, albumArtist, album, year, track, genre, comment

    /// Other spellings the same field turns up under when *reading*, already
    /// lowercased. ffmpeg normalises most Vorbis-comment names on the way in
    /// (`TRACKNUMBER` arrives as `track`), but not every one in every version,
    /// and a file tagged by another tool can carry either.
    var readAliases: [String] {
        switch self {
        case .albumArtist: return ["albumartist", "album artist"]
        case .year: return ["year"]
        case .track: return ["tracknumber"]
        case .comment: return ["description"]
        case .title, .artist, .album, .genre: return []
        }
    }

    /// The `-metadata` key ffmpeg actually uses. Verified against real files in
    /// every accepted format — these are not guessed from documentation.
    var ffmpegKey: String {
        switch self {
        case .title: return "title"
        case .artist: return "artist"
        case .albumArtist: return "album_artist"
        case .album: return "album"
        case .year: return "date"
        case .track: return "track"
        case .genre: return "genre"
        case .comment: return "comment"
        }
    }
}

struct AudioTags {
    var title = ""
    var artist = ""
    var albumArtist = ""
    var album = ""
    var year = ""
    var track = ""
    var genre = ""
    var comment = ""

    subscript(field: TagField) -> String {
        get {
            switch field {
            case .title: return title
            case .artist: return artist
            case .albumArtist: return albumArtist
            case .album: return album
            case .year: return year
            case .track: return track
            case .genre: return genre
            case .comment: return comment
            }
        }
        set {
            switch field {
            case .title: title = newValue
            case .artist: artist = newValue
            case .albumArtist: albumArtist = newValue
            case .album: album = newValue
            case .year: year = newValue
            case .track: track = newValue
            case .genre: genre = newValue
            case .comment: comment = newValue
            }
        }
    }
}

/// What to do with the cover art on save. `unchanged` leaves whatever the file
/// already has (or does not have) alone — the common case, and the only one
/// that does not need a second ffmpeg input.
enum CoverEdit {
    case unchanged
    case replace(URL)
    case remove
}

/// What a format can actually do, verified against real files rather than
/// assumed from format documentation:
///
/// - MP3, FLAC and M4A support every field and full cover art.
/// - OGG and Opus support every field but not cover art: ffmpeg's own muxer
///   silently drops a `METADATA_BLOCK_PICTURE` tag on write — present in the
///   write command's own log, gone the moment the file is read back. There is
///   no reliable way to embed a cover through ffmpeg for these two.
/// - WAV supports every field except Album Artist: RIFF INFO chunks predate
///   the concept of a separate album artist, so ffmpeg has nowhere to put it —
///   the tag is silently dropped, not an error. Cover art is refused outright
///   ("wav muxer does not support any stream of type video").
/// - Raw AAC (`.aac`, ADTS) carries no metadata container at all. Nothing can
///   be read or written, tags or cover.
struct AudioFormatCapabilities {
    var supportsTags: Bool
    var supportsCoverArt: Bool
    var unsupportedFields: Set<TagField>

    static func forExtension(_ ext: String) -> AudioFormatCapabilities {
        switch ext.lowercased() {
        case "mp3", "flac", "m4a":
            return AudioFormatCapabilities(supportsTags: true, supportsCoverArt: true, unsupportedFields: [])
        case "ogg", "opus":
            return AudioFormatCapabilities(supportsTags: true, supportsCoverArt: false, unsupportedFields: [])
        case "wav":
            return AudioFormatCapabilities(supportsTags: true, supportsCoverArt: false, unsupportedFields: [.albumArtist])
        case "aac":
            return AudioFormatCapabilities(supportsTags: false, supportsCoverArt: false, unsupportedFields: Set(TagField.allCases))
        default:
            return AudioFormatCapabilities(supportsTags: true, supportsCoverArt: true, unsupportedFields: [])
        }
    }
}

enum AudioTagError: LocalizedError, ToolLogCarrying {
    case ffmpegFailed(String, log: String)

    var errorDescription: String? {
        switch self {
        // ffmpeg's own output, passed through untranslated.
        case .ffmpegFailed(let detail, _): return "ffmpeg: \(detail)"
        }
    }

    var toolLog: String? {
        if case .ffmpegFailed(_, let log) = self, !log.isEmpty { return log }
        return nil
    }
}

enum AudioTagEditor {

    static let acceptedExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav"]

    // MARK: - Reading

    /// Reads the tags ffmpeg reports for `url`.
    ///
    /// `-f ffmetadata -` only surfaces *container*-level metadata, which is
    /// where MP3/FLAC/M4A/WAV keep their tags — but Ogg and Opus keep theirs on
    /// the *audio stream* instead, which `-f ffmetadata -` never sees (it comes
    /// back with only ffmpeg's own `encoder` line, an empty-looking result that
    /// is silently wrong, not merely incomplete). This reads the `-i` banner
    /// directly instead — the same source `VideoConcatenator.layout` already
    /// parses for stream info — and collects every `key : value` line under
    /// *any* `Metadata:` heading, container or per-stream, by tracking each
    /// heading's indentation and gathering lines indented deeper than it until
    /// the indentation returns to that level or shallower.
    static func readTags(from url: URL, ffmpeg: URL) -> AudioTags {
        var tags = AudioTags()
        guard let result = ProcessRunner.capture(
            executable: ffmpeg, arguments: ["-hide_banner", "-i", url.path], timeout: 15
        ), !result.timedOut, !result.cancelled else { return tags }

        let raw = collectMetadata(from: result.output)
        for field in TagField.allCases {
            for key in [field.ffmpegKey] + field.readAliases {
                if let value = raw[key] {
                    tags[field] = value
                    break
                }
            }
        }
        return tags
    }

    /// Parses the `Metadata:` blocks in an `ffmpeg -i` banner into one
    /// key/value map — the container's and every *audio* stream's.
    ///
    /// Two things real files do that ffmpeg-written test files did not:
    ///
    /// - Keys come back in whatever case the file stores them. Vorbis comments
    ///   (FLAC, Ogg, Opus) are conventionally upper case — `ARTIST`, `TITLE`,
    ///   `ALBUM` — and ffmpeg prints them that way, so the map is keyed in
    ///   lower case and looked up in lower case. Verified: a FLAC tagged
    ///   `ARTIST`/`TITLE`/`ALBUM` read back with every field empty before this.
    /// - An embedded cover is a video stream with a `Metadata:` block of its
    ///   own (`title: Album cover`, `comment: Cover (front)`). That describes
    ///   the picture, not the recording. Read as file tags, it put "Cover
    ///   (front)" into the Comment field of every MP3 that had a cover and no
    ///   comment — and saving then wrote it as a real tag. Blocks under a
    ///   video stream are skipped.
    private static func collectMetadata(from bannerText: String) -> [String: String] {
        var result: [String: String] = [:]
        var metadataIndent: Int? = nil
        var underVideoStream = false
        let keyValue = try! NSRegularExpression(pattern: #"^([A-Za-z_][A-Za-z0-9_ ]*?)\s*:\s?(.*)$"#)

        for rawLine in bannerText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Stream #") {
                underVideoStream = trimmed.contains("Video:")
                metadataIndent = nil
                continue
            }
            if trimmed == "Metadata:" {
                metadataIndent = underVideoStream ? nil : indent
                continue
            }
            guard let blockIndent = metadataIndent else { continue }
            guard indent > blockIndent else { metadataIndent = nil; continue }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = keyValue.firstMatch(in: trimmed, range: range),
                  let keyRange = Range(match.range(at: 1), in: trimmed),
                  let valueRange = Range(match.range(at: 2), in: trimmed)
            else { continue }

            let key = String(trimmed[keyRange]).lowercased()
            // First occurrence wins: container-level metadata (which appears
            // first in the banner) is the more meaningful location when a key
            // happens to appear more than once.
            if result[key] == nil {
                result[key] = String(trimmed[valueRange])
            }
        }
        return result
    }

    /// Extracts the embedded cover, if any, as an image. `nil` both when the
    /// format cannot carry a cover and when this particular file has none —
    /// ffmpeg fails identically either way (`-map 0:v` matching nothing), which
    /// is exactly the "no cover" signal the caller wants.
    static func extractCover(from url: URL, ffmpeg: URL) -> NSImage? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mike-cover-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temp) }

        let result = ProcessRunner.capture(
            executable: ffmpeg,
            arguments: ["-y", "-i", url.path, "-map", "0:v", "-frames:v", "1", "-c", "copy", temp.path],
            timeout: 15
        )
        guard result?.status == 0 else { return nil }
        return NSImage(contentsOf: temp)
    }

    // MARK: - Writing

    /// Writes `tags` and `cover` into `url`, losslessly (`-c copy`), and only
    /// for fields that are both non-empty and supported by this format.
    ///
    /// ffmpeg refuses to edit a file in place — verified directly: pointing its
    /// own output at its input exits immediately with "FFmpeg cannot edit
    /// existing files in-place", the input left byte-for-byte untouched. So the
    /// safety the spec asks for (original stays untouched on failure) is built
    /// here rather than assumed from ffmpeg: the result goes to a temporary
    /// file next to the original, and only once ffmpeg has actually succeeded
    /// does `FileManager.replaceItemAt` swap it in. A failure at any point
    /// before that leaves the original exactly as it was.
    static func write(
        tags: AudioTags,
        cover: CoverEdit,
        to url: URL,
        ffmpeg: URL,
        onStart: ((Process) -> Void)? = nil
    ) throws {
        let capabilities = AudioFormatCapabilities.forExtension(url.pathExtension)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".mike-tag-\(UUID().uuidString).\(url.pathExtension)")

        var arguments = ["-y", "-i", url.path]

        switch cover {
        case .unchanged:
            arguments += ["-map", "0"]
        case .remove:
            arguments += ["-map", "0:a"]
        case .replace(let imageURL):
            arguments = ["-y", "-i", url.path, "-i", imageURL.path]
            arguments += [
                "-map", "0:a", "-map", "1:v",
                "-disposition:v", "attached_pic",
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)",
            ]
        }

        arguments += ["-c", "copy"]

        if capabilities.supportsTags {
            for field in TagField.allCases where !capabilities.unsupportedFields.contains(field) {
                let value = tags[field].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                arguments += ["-metadata", "\(field.ffmpegKey)=\(value)"]
            }
        }

        arguments.append(temp.path)

        let outcome = ProcessRunner.run(executable: ffmpeg, arguments: arguments, onStart: onStart)

        guard outcome.succeeded else {
            try? FileManager.default.removeItem(at: temp)
            if outcome.cancelled { throw CancellationError() }
            throw AudioTagError.ffmpegFailed(
                outcome.failureSummary(tool: "ffmpeg"), log: outcome.logText
            )
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
