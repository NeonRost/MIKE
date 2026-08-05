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
import ImageIO

/// One tag and its value, both already turned into display strings. The label
/// is an EXIF/GPS/TIFF/IPTC tag name and stays in English — it is the
/// standard's own vocabulary, not UI copy, and is rendered with
/// `Text(verbatim:)`.
struct MetadataRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

/// A named block of rows — "EXIF", "GPS", and so on — kept only when it holds
/// at least one row.
struct MetadataGroup: Identifiable {
    let id = UUID()
    /// The heading shown for the group. `location` carries the derived,
    /// human-readable coordinate line that leads the GPS block.
    let title: String
    let rows: [MetadataRow]
    let location: LocationSummary?

    init(title: String, rows: [MetadataRow], location: LocationSummary? = nil) {
        self.title = title
        self.rows = rows
        self.location = location
    }
}

/// GPS turned into something a person can read: a decimal pair to paste into a
/// map, the same position in degrees/minutes/seconds, and altitude if present.
struct LocationSummary {
    let decimal: String
    let dms: String
    let altitude: String?
}

enum ImageMetadata {

    /// Reads the metadata ImageIO can see. This path never needs exiftool, so
    /// it stays available whether or not the tool is installed.
    ///
    /// Returns an empty array when the file carries no readable metadata at all
    /// — a clean "nothing here", not an error.
    static func read(from url: URL) -> [MetadataGroup] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [] }

        var groups: [MetadataGroup] = []

        // Top-level image facts (pixel size, colour model, DPI, orientation).
        let topLevel = properties.filter { !($0.value is [CFString: Any]) && !($0.value is [String: Any]) }
        if let group = makeGroup(title: "Image", from: topLevel as [CFString: Any]) {
            groups.append(group)
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let group = makeGroup(title: "EXIF", from: exif) {
            groups.append(group)
        }

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let group = makeGPSGroup(from: gps) {
            groups.append(group)
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let group = makeGroup(title: "TIFF", from: tiff) {
            groups.append(group)
        }

        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           let group = makeGroup(title: "IPTC", from: iptc) {
            groups.append(group)
        }

        return groups
    }

    /// EXIF's own `DateTimeOriginal`, parsed into a `Date`. `nil` for anything
    /// ImageIO cannot open, or that carries no capture date at all — both are
    /// the ordinary case for non-image files and images without EXIF, not
    /// errors.
    static func captureDate(from url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return exifDateFormatter.date(from: raw)
    }

    /// EXIF's own format: `yyyy:MM:dd HH:mm:ss`, local time, no time zone.
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    // MARK: - Group building

    private static func makeGroup(title: String, from dictionary: [CFString: Any]) -> MetadataGroup? {
        let rows = dictionary
            .map { MetadataRow(label: name(for: $0.key), value: display(value: $0.value)) }
            .filter { !$0.value.isEmpty }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        guard !rows.isEmpty else { return nil }
        return MetadataGroup(title: title, rows: rows)
    }

    private static func makeGPSGroup(from gps: [CFString: Any]) -> MetadataGroup? {
        let rows = gps
            .map { MetadataRow(label: name(for: $0.key), value: display(value: $0.value)) }
            .filter { !$0.value.isEmpty }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

        let summary = locationSummary(from: gps)
        // A GPS dictionary with neither raw rows nor a resolvable position is
        // nothing worth showing.
        guard !rows.isEmpty || summary != nil else { return nil }
        return MetadataGroup(title: "GPS", rows: rows, location: summary)
    }

    // MARK: - GPS decoding

    private static func locationSummary(from gps: [CFString: Any]) -> LocationSummary? {
        guard let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }

        // ImageIO reports magnitudes; the ref letters carry the hemisphere.
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() ?? "E"

        // Decimal form stays dot-separated on purpose — that is what maps
        // expect pasted in, regardless of the UI language.
        let decimal = String(
            format: "%.6f° %@, %.6f° %@",
            lat, latRef, lon, lonRef
        )
        let dms = "\(dmsString(lat)) \(latRef), \(dmsString(lon)) \(lonRef)"

        var altitude: String?
        if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
            let belowSeaLevel = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
            let metres = belowSeaLevel ? -alt : alt
            altitude = String(format: "%.1f m", metres)
        }

        return LocationSummary(decimal: decimal, dms: dms, altitude: altitude)
    }

    private static func dmsString(_ value: Double) -> String {
        let total = abs(value)
        let degrees = Int(total)
        let minutesFull = (total - Double(degrees)) * 60
        let minutes = Int(minutesFull)
        let seconds = (minutesFull - Double(minutes)) * 60
        return String(format: "%d° %d′ %.1f″", degrees, minutes, seconds)
    }

    // MARK: - Value formatting

    /// Turns a raw property value into a compact display string. Long binary
    /// blobs (MakerNote, embedded thumbnails) are reported by size rather than
    /// dumped as unreadable bytes.
    private static func display(value: Any) -> String {
        switch value {
        case let data as Data:
            return byteCount(data.count)
        case let array as [Any]:
            let parts = array.map { scalar($0) }
            let joined = parts.joined(separator: ", ")
            // A handful of values reads fine inline; a long vector does not.
            if parts.count > 12 || joined.count > 120 {
                return String(
                    localized: "\(parts.count) values",
                    comment: "Stand-in for a long array of metadata values"
                )
            }
            return joined
        case let dictionary as [AnyHashable: Any]:
            return String(
                localized: "\(dictionary.count) values",
                comment: "Stand-in for a nested metadata dictionary"
            )
        default:
            return scalar(value)
        }
    }

    private static func scalar(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            // Integers print without a trailing ".0"; fractionals keep a few
            // digits without a long floating tail.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let double = number.doubleValue
            if double == double.rounded() && abs(double) < 1e15 {
                return String(number.intValue)
            }
            return String(format: "%g", double)
        default:
            return "\(value)"
        }
    }

    private static func byteCount(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(count))
    }

    // MARK: - Tag names

    /// ImageIO's keys arrive as raw CFString identifiers such as
    /// `{Exif}ExposureTime`-style constants; their string value is the plain
    /// tag name ("ExposureTime"). That is the standard's own English name and
    /// is shown verbatim.
    private static func name(for key: CFString) -> String {
        key as String
    }
}
