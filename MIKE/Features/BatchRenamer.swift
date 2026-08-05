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
import SwiftUI

enum CaseConversion: String, CaseIterable, Identifiable {
    case lowercase
    case uppercase
    case titleCase

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .lowercase: return "Lowercase"
        case .uppercase: return "Uppercase"
        case .titleCase: return "Title Case"
        }
    }
}

enum SpaceReplacement: String, CaseIterable, Identifiable {
    case underscore
    case hyphen
    case remove

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .underscore: return "With an underscore"
        case .hyphen: return "With a hyphen"
        case .remove: return "Remove"
        }
    }
}

/// Every operation's current settings, snapshotted once per preview/rename
/// pass so the pure `plan(files:dateInfo:settings:)` function never touches
/// `@Published` state directly.
struct BatchRenameSettings {
    var exifDateEnabled = false
    var exifDateFormat = "yyyy-MM-dd_HH-mm-ss"
    var exifDateFallbackToModDate = true

    var prefixEnabled = false
    var prefixText = ""

    var suffixEnabled = false
    var suffixText = ""

    var findReplaceEnabled = false
    var findText = ""
    var replaceText = ""
    var findReplaceCaseSensitive = false

    var caseConversionEnabled = false
    var caseConversion = CaseConversion.lowercase

    var spaceReplacementEnabled = false
    var spaceReplacement = SpaceReplacement.underscore

    var hasAnyOperation: Bool {
        exifDateEnabled || prefixEnabled || suffixEnabled || findReplaceEnabled
            || caseConversionEnabled || spaceReplacementEnabled
    }
}

/// The two dates the EXIF-date-as-name operation can draw from, read once per
/// file and cached — re-reading EXIF from disk on every keystroke in an
/// unrelated field (prefix, find & replace, …) would be wasteful.
struct FileDateInfo {
    var captureDate: Date?
    var modificationDate: Date?
}

struct PlannedRename {
    let source: URL
    var newStem: String
    /// Set only by the EXIF-date step when it could not determine a date for
    /// this file; the row is still carried through the remaining operations.
    var problem: String?

    var newName: String {
        let ext = source.pathExtension
        return ext.isEmpty ? newStem : "\(newStem).\(ext)"
    }
}

enum BatchRenamer {

    /// Applies the six operations, in the fixed order the UI shows them, to
    /// each file's name stem. The extension is never touched here — it is
    /// reattached by `PlannedRename.newName`.
    static func plan(files: [URL], dateInfo: [URL: FileDateInfo], settings: BatchRenameSettings) -> [PlannedRename] {
        files.map { url in
            var stem = url.deletingPathExtension().lastPathComponent
            var problem: String?

            if settings.exifDateEnabled {
                let info = dateInfo[url]
                if let capture = info?.captureDate {
                    stem = format(capture, pattern: settings.exifDateFormat)
                } else if settings.exifDateFallbackToModDate, let modified = info?.modificationDate {
                    stem = format(modified, pattern: settings.exifDateFormat)
                } else {
                    problem = String(localized: "No EXIF date found; name unchanged by this step.")
                }
            }

            if settings.prefixEnabled, !settings.prefixText.isEmpty {
                stem = settings.prefixText + stem
            }

            if settings.suffixEnabled, !settings.suffixText.isEmpty {
                stem += settings.suffixText
            }

            if settings.findReplaceEnabled, !settings.findText.isEmpty {
                stem = stem.replacingOccurrences(
                    of: settings.findText,
                    with: settings.replaceText,
                    options: settings.findReplaceCaseSensitive ? [] : [.caseInsensitive]
                )
            }

            if settings.caseConversionEnabled {
                switch settings.caseConversion {
                case .lowercase: stem = stem.lowercased()
                case .uppercase: stem = stem.uppercased()
                case .titleCase: stem = stem.capitalized
                }
            }

            if settings.spaceReplacementEnabled {
                switch settings.spaceReplacement {
                case .underscore: stem = stem.replacingOccurrences(of: " ", with: "_")
                case .hyphen: stem = stem.replacingOccurrences(of: " ", with: "-")
                case .remove: stem = stem.replacingOccurrences(of: " ", with: "")
                }
            }

            return PlannedRename(source: url, newStem: stem, problem: problem)
        }
    }

    /// EXIF/formatting dates always render in a fixed, unambiguous locale —
    /// the same reasoning as `MetadataWriter`'s own date formatter — since a
    /// file name should not silently change shape with the system locale.
    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// Renames are attempted one at a time; a failure does not stop the rest
    /// — "as atomic as possible" means the whole plan is validated and built
    /// up front (by the caller, from a conflict-free preview), not that a
    /// single failure rolls everything back.
    static func execute(_ renames: [(source: URL, target: URL)]) -> (succeeded: [(old: URL, new: URL)], failures: [(name: String, error: String)]) {
        var succeeded: [(URL, URL)] = []
        var failures: [(String, String)] = []
        for pair in renames {
            do {
                try FileManager.default.moveItem(at: pair.source, to: pair.target)
                succeeded.append((pair.source, pair.target))
            } catch {
                failures.append((pair.source.lastPathComponent, error.localizedDescription))
            }
        }
        return (succeeded, failures)
    }
}
