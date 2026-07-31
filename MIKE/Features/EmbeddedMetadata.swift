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

enum EmbeddedValueKind {
    case text
    case json
    case binary
}

/// One key/value block. Keys and values are the file's own data and are shown
/// verbatim.
struct EmbeddedEntry: Identifiable {
    let id = UUID()
    var key: String
    /// The exact original string, written back unchanged when the user does not
    /// edit it — so a JSON value is never silently reformatted on disk.
    var rawValue: String
    /// Indented JSON for display, when the value parses as JSON. Never written;
    /// display only.
    var prettyValue: String?
    var kind: EmbeddedValueKind
    /// For binary blocks: their size, shown instead of the bytes.
    var byteSize: Int?
    /// The chunk or container the value came from, shown verbatim: `tEXt`,
    /// `zTXt`, `iTXt`, `XMP`.
    var source: String
    /// The exiftool tag path used to write or delete this entry, e.g.
    /// `PNG:parameters` or `XMP-dc:Rights`. `nil` means read-only.
    var writeTag: String?
    /// XMP arrays and structures: displayed as JSON, not inline-editable.
    var structured: Bool

    init(
        key: String,
        rawValue: String,
        prettyValue: String? = nil,
        kind: EmbeddedValueKind,
        byteSize: Int? = nil,
        source: String,
        writeTag: String? = nil,
        structured: Bool = false
    ) {
        self.key = key
        self.rawValue = rawValue
        self.prettyValue = prettyValue
        self.kind = kind
        self.byteSize = byteSize
        self.source = source
        self.writeTag = writeTag
        self.structured = structured
    }

    /// Exact character count of the raw value — useful for judging a long AI
    /// prompt before opening it.
    var characterCount: Int { rawValue.count }

    /// Rough token estimate for long text, deliberately labelled approximate:
    /// real BPE tokenisation would need a bundled vocabulary. About four
    /// characters per token is the usual rule of thumb.
    var approximateTokens: Int { max(1, (rawValue.count + 3) / 4) }

    /// Inline editing is offered for plain, writable values only.
    var isEditable: Bool { writeTag != nil && !structured && kind != .binary }
    var isDeletable: Bool { writeTag != nil }
}

enum EmbeddedGroupKind {
    case aiGeneration
    case pngText
    case xmp
    case other
}

struct EmbeddedGroup: Identifiable {
    let id = UUID()
    var title: String
    var kind: EmbeddedGroupKind
    var entries: [EmbeddedEntry]
    /// PNG text groups accept new keys; XMP and "other" groups do not (for now).
    var allowsAdditions: Bool
}

/// Which format the chosen file is, as far as embedded blocks go.
enum EmbeddedFormat {
    case png
    case exiftoolFormat   // WebP, TIFF, JPEG — read through exiftool
    case unsupported      // BMP, GIF — no embedded text blocks of this kind
    case unknown

    /// Formats that plainly do not carry embedded text blocks get a note rather
    /// than an empty view.
    var carriesEmbeddedBlocks: Bool { self != .unsupported }
}

struct EmbeddedReadResult {
    var groups: [EmbeddedGroup] = []
    var format: EmbeddedFormat = .unknown
    /// Size of a PNG `eXIf` chunk, when present — noted, not decoded (its EXIF
    /// content lives in the Metadata section).
    var exifChunkByteSize: Int?
    /// A non-PNG format was chosen but exiftool is not installed, so only a
    /// limited view is possible.
    var limitedByMissingExiftool = false
    /// PNG carried an XMP packet but exiftool is absent, so it cannot be shown
    /// as a structured tree.
    var xmpNeedsExiftool = false

    var hasAnyGroup: Bool { !groups.isEmpty }
}

enum EmbeddedMetadata {

    /// Keys that identify AI-generation payloads, matched case-insensitively.
    private static let aiKeys: Set<String> = [
        "parameters", "prompt", "workflow", "sd-metadata",
        "negative_prompt", "dream", "comfyui",
    ]

    /// The XMP packet keyword PNG uses inside an `iTXt` chunk. Excluded from the
    /// raw text list so XMP is shown structured (via exiftool) instead of as raw
    /// XML.
    private static let pngXMPKeyword = "xml:com.adobe.xmp"

    static func read(from url: URL, exiftool: URL?) -> EmbeddedReadResult {
        var result = EmbeddedReadResult()

        if let png = PNGChunkReader.read(from: url) {
            result.format = .png
            result.exifChunkByteSize = png.exifByteSize

            let textChunks = png.text.filter { $0.keyword.lowercased() != pngXMPKeyword }
            let hasXMPPacket = png.text.contains { $0.keyword.lowercased() == pngXMPKeyword }

            var aiEntries: [EmbeddedEntry] = []
            var textEntries: [EmbeddedEntry] = []
            for chunk in textChunks {
                let entry = makePNGEntry(chunk)
                if aiKeys.contains(chunk.keyword.lowercased()) {
                    aiEntries.append(entry)
                } else {
                    textEntries.append(entry)
                }
            }

            if !aiEntries.isEmpty {
                result.groups.append(EmbeddedGroup(
                    title: "AI Generation Data", kind: .aiGeneration,
                    entries: aiEntries, allowsAdditions: false
                ))
            }
            // Always present, even empty, so the user can add a text chunk to a
            // PNG that has none.
            result.groups.append(EmbeddedGroup(
                title: "PNG Text Chunks", kind: .pngText,
                entries: textEntries, allowsAdditions: true
            ))

            // Structured XMP for the PNG, when exiftool can supply it.
            if let exiftool {
                result.groups.append(contentsOf: EmbeddedExifReader.read(from: url, exiftool: exiftool))
            } else if hasXMPPacket {
                result.xmpNeedsExiftool = true
            }

            // An all-empty PNG text group still lets the user add entries, so a
            // PNG is never treated as "unsupported".
            return result
        }

        // Not a PNG.
        switch url.pathExtension.lowercased() {
        case "bmp", "gif":
            result.format = .unsupported
        case "webp", "tif", "tiff", "jpg", "jpeg", "heic", "heif":
            result.format = .exiftoolFormat
            if let exiftool {
                result.groups = EmbeddedExifReader.read(from: url, exiftool: exiftool)
            } else {
                result.limitedByMissingExiftool = true
            }
        default:
            result.format = .unknown
            if let exiftool {
                result.groups = EmbeddedExifReader.read(from: url, exiftool: exiftool)
            } else {
                result.limitedByMissingExiftool = true
            }
        }
        return result
    }

    private static func makePNGEntry(_ chunk: PNGTextChunk) -> EmbeddedEntry {
        let (kind, pretty) = EmbeddedValue.classify(chunk.value)
        return EmbeddedEntry(
            key: chunk.keyword,
            rawValue: chunk.value,
            prettyValue: pretty,
            kind: kind,
            source: chunk.source,
            // Written with a generated -config that registers this keyword; the
            // key is validated before it ever reaches exiftool.
            // A keyword with characters outside the safe set (a space, say)
            // cannot round-trip through the config safely, so it is shown but
            // not made editable.
            writeTag: EmbeddedMetadataWriter.isValidKey(chunk.keyword) ? "PNG:\(chunk.keyword)" : nil
        )
    }
}

/// Value classification and JSON formatting, shared by both readers.
enum EmbeddedValue {

    /// Decides whether a raw string is JSON and, if so, produces an indented
    /// copy for display. The raw string is what gets written back.
    static func classify(_ raw: String) -> (EmbeddedValueKind, String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return (.text, nil) }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = prettyJSON(from: object)
        else { return (.text, nil) }
        return (.json, pretty)
    }

    static func prettyJSON(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
