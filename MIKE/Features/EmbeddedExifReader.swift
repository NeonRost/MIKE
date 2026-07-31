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

/// Reads XMP and other non-EXIF embedded blocks through exiftool. exiftool is
/// the XML intermediary for XMP: it hands back structured JSON (`-struct`) so
/// MIKE never parses or emits XMP XML itself.
enum EmbeddedExifReader {

    /// exiftool groups that the Metadata section already shows (or that are not
    /// embedded text blocks). Excluded here so the two sections never show the
    /// same thing twice. Matched against the part before the colon in a
    /// `Group1:Tag` key.
    private static let excludedGroups: Set<String> = [
        "exiftool", "system", "file", "composite", "png", "jfif",
        "exif", "exififd", "ifd0", "ifd1", "subifd", "gps", "interopifd",
        "iptc", "icc_profile", "icc-header", "icc_profile-header",
        "makernotes", "photoshop", "adobe",
    ]

    /// Returns the XMP and "other" groups, or an empty array when exiftool finds
    /// nothing outside the excluded groups. Must be called off the main thread.
    static func read(from url: URL, exiftool: URL) -> [EmbeddedGroup] {
        guard let result = ProcessRunner.capture(
            executable: exiftool,
            // -q -q keeps warnings off stdout so it stays pure JSON; -G1 gives
            // the namespace group, -struct keeps XMP structures intact, -a keeps
            // duplicate tags, -b would base64 binaries so it is left off.
            arguments: ["-j", "-G1", "-struct", "-a", "-q", "-q", "-charset", "UTF8", url.path],
            timeout: 25
        ), result.status == 0 else { return [] }

        // Be forgiving about anything printed before the array.
        guard let start = result.output.firstIndex(of: "["),
              let data = String(result.output[start...]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let object = array.first
        else { return [] }

        // Bucket keys by their group prefix, preserving exiftool's order.
        var order: [String] = []
        var buckets: [String: [(tag: String, value: Any)]] = [:]

        for (key, value) in object {
            guard let colon = key.firstIndex(of: ":") else { continue }
            let group = String(key[..<colon])
            let tag = String(key[key.index(after: colon)...])
            if excludedGroups.contains(group.lowercased()) { continue }
            if key == "SourceFile" { continue }
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append((tag, value))
        }

        // XMP groups first, then any other non-standard groups.
        let sortedGroups = order.sorted { a, b in
            let ax = a.lowercased().hasPrefix("xmp"), bx = b.lowercased().hasPrefix("xmp")
            if ax != bx { return ax }
            return a.localizedStandardCompare(b) == .orderedAscending
        }

        return sortedGroups.compactMap { group in
            let isXMP = group.lowercased().hasPrefix("xmp")
            let entries = buckets[group]!.map { pair in
                entry(group: group, tag: pair.tag, value: pair.value, editable: isXMP)
            }
            guard !entries.isEmpty else { return nil }
            return EmbeddedGroup(
                title: group,
                kind: isXMP ? .xmp : .other,
                entries: entries,
                // Adding a brand-new XMP property needs a namespace choice, out
                // of scope for now; existing ones stay editable and deletable.
                allowsAdditions: false
            )
        }
    }

    private static func entry(group: String, tag: String, value: Any, editable: Bool) -> EmbeddedEntry {
        let writeTag = "\(group):\(tag)"

        switch value {
        case let string as String:
            return EmbeddedEntry(
                key: tag,
                rawValue: string,
                kind: .text,
                source: "XMP",
                writeTag: editable ? writeTag : nil
            )
        case is [Any], is [String: Any]:
            // Arrays and XMP structures: shown as pretty JSON, read-only for now
            // (deletable as a whole via the entry's delete, which clears the
            // tag). Editing a structure field-by-field is out of scope.
            let pretty = EmbeddedValue.prettyJSON(from: value)
            return EmbeddedEntry(
                key: tag,
                rawValue: pretty ?? "\(value)",
                prettyValue: pretty,
                kind: .json,
                source: "XMP",
                // Still deletable: the write tag is kept so "delete" can clear
                // it, but inline editing is disabled by kind == .json + no raw
                // round-trip. The view treats structured values as read-only.
                writeTag: editable ? writeTag : nil,
                structured: true
            )
        default:
            return EmbeddedEntry(
                key: tag,
                rawValue: "\(value)",
                kind: .text,
                source: "XMP",
                writeTag: editable ? writeTag : nil
            )
        }
    }
}
