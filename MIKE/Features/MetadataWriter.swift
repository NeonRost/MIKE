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

/// The editable fields, kept small on purpose: a handful of common tags rather
/// than exiftool's thousands. An empty field is left untouched; a filled one is
/// written.
struct MetadataEdits {
    var copyright = ""
    var artist = ""
    var imageDescription = ""
    /// Only written when the user turned the date on — otherwise nil leaves
    /// `DateTimeOriginal` as it is.
    var dateTimeOriginal: Date?
    /// Signed decimal degrees, already validated. Both must be present for GPS
    /// to be written.
    var latitude: Double?
    var longitude: Double?

    /// exiftool `-Tag=value` assignments for the filled fields, in a stable
    /// order. No file path and no `--` here — the runner adds those.
    var tagArguments: [String] {
        var args: [String] = []

        if !copyright.trimmed.isEmpty { args.append("-Copyright=\(copyright.trimmed)") }
        if !artist.trimmed.isEmpty { args.append("-Artist=\(artist.trimmed)") }
        if !imageDescription.trimmed.isEmpty {
            args.append("-ImageDescription=\(imageDescription.trimmed)")
        }

        if let date = dateTimeOriginal {
            args.append("-DateTimeOriginal=\(Self.exifDateFormatter.string(from: date))")
        }

        if let latitude, let longitude {
            // exiftool only records the hemisphere when the Ref tags are set
            // explicitly, so the magnitude and the letter go in separately.
            args.append("-GPSLatitude=\(abs(latitude))")
            args.append("-GPSLatitudeRef=\(latitude >= 0 ? "N" : "S")")
            args.append("-GPSLongitude=\(abs(longitude))")
            args.append("-GPSLongitudeRef=\(longitude >= 0 ? "E" : "W")")
        }

        return args
    }

    var hasAnything: Bool { !tagArguments.isEmpty }

    /// exiftool expects `YYYY:MM:DD HH:MM:SS` in local time, no time zone.
    static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

enum MetadataWriter {

    /// Applies `edits` to `file`. Must be called off the main thread.
    static func apply(_ edits: MetadataEdits, to file: URL, exiftool: URL) throws -> ExifWriteOutcome {
        try ExifToolWrite.run(assignments: edits.tagArguments, on: file, exiftool: exiftool)
    }

    /// Strips every tag exiftool can write. `-all=` covers EXIF, IPTC, XMP and
    /// the rest in one go.
    ///
    /// - Parameter skipBackup: see `ExifToolWrite.run` — set by Quick Edit,
    ///   which calls this on a file it just wrote itself, not the user's real
    ///   original.
    static func removeAll(from file: URL, exiftool: URL, skipBackup: Bool = false) throws -> ExifWriteOutcome {
        try ExifToolWrite.run(assignments: ["-all="], on: file, exiftool: exiftool, skipBackup: skipBackup)
    }

    /// Removes location while leaving camera model, date and the rest in place.
    /// `-gps:all=` clears the EXIF GPS block; the XMP GPS tags are separate and
    /// go too, or a Lightroom/Photos export would keep its location.
    static func removeGPS(from file: URL, exiftool: URL, skipBackup: Bool = false) throws -> ExifWriteOutcome {
        try ExifToolWrite.run(assignments: ["-gps:all=", "-xmp:GPS*="], on: file, exiftool: exiftool, skipBackup: skipBackup)
    }

    /// The backup exiftool would create for `file`, exposed for the view's
    /// pre-write confirmation.
    static func backupExists(for file: URL) -> Bool {
        ExifToolWrite.backupExists(for: file)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
