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
struct BatchRenameSettings: Equatable {
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
        // One formatter for the whole pass. A `DateFormatter` is expensive to
        // set up, and this runs for every file on every keystroke.
        let formatter = DateFormatter()
        // EXIF/formatting dates always render in a fixed, unambiguous locale —
        // the same reasoning as `MetadataWriter`'s own date formatter — since
        // a file name should not silently change shape with the system locale.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = settings.exifDateFormat

        return files.map { url in
            var stem = url.deletingPathExtension().lastPathComponent
            var problem: String?

            if settings.exifDateEnabled {
                let info = dateInfo[url]
                if let capture = info?.captureDate {
                    stem = formatter.string(from: capture)
                } else if settings.exifDateFallbackToModDate, let modified = info?.modificationDate {
                    stem = formatter.string(from: modified)
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

    /// Renames are attempted one at a time; a failure does not stop the rest
    /// — "as atomic as possible" means the whole plan is validated and built
    /// up front (by the caller, from a conflict-free preview), not that a
    /// single failure rolls everything back.
    ///
    /// A rename whose target is still occupied by another file *of the same
    /// batch* — `a → b` while `b → c`, a swap, or a change of case alone on a
    /// case-insensitive volume — cannot simply be done in list order: the
    /// name is taken until its current owner has moved. Those go through a
    /// temporary name first; everything else is moved directly.
    static func execute(_ renames: [(source: URL, target: URL)]) -> (succeeded: [(old: URL, new: URL)], failures: [(name: String, error: String)]) {
        var succeeded: [(URL, URL)] = []
        var failures: [(String, String)] = []

        let sourceKeys = Set(renames.map { key(for: $0.source) })
        var parked: [(original: URL, temporary: URL, target: URL)] = []

        for pair in renames where sourceKeys.contains(key(for: pair.target)) {
            let temporary = pair.source.deletingLastPathComponent()
                .appendingPathComponent(".mike-rename-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: pair.source, to: temporary)
                parked.append((pair.source, temporary, pair.target))
            } catch {
                failures.append((pair.source.lastPathComponent, error.localizedDescription))
            }
        }

        for item in parked {
            do {
                try FileManager.default.moveItem(at: item.temporary, to: item.target)
                succeeded.append((item.original, item.target))
            } catch {
                // Back under its own name rather than left under a hidden one.
                try? FileManager.default.moveItem(at: item.temporary, to: item.original)
                failures.append((item.original.lastPathComponent, error.localizedDescription))
            }
        }

        let parkedKeys = Set(parked.map { key(for: $0.original) })
        let alreadyFailed = Set(failures.map(\.0))
        for pair in renames where !parkedKeys.contains(key(for: pair.source)) {
            guard !sourceKeys.contains(key(for: pair.target)) else {
                // Could not be parked above; already reported.
                if !alreadyFailed.contains(pair.source.lastPathComponent) {
                    failures.append((pair.source.lastPathComponent, ""))
                }
                continue
            }
            do {
                try FileManager.default.moveItem(at: pair.source, to: pair.target)
                succeeded.append((pair.source, pair.target))
            } catch {
                failures.append((pair.source.lastPathComponent, error.localizedDescription))
            }
        }
        return (succeeded, failures)
    }

    /// Two paths that name the same file on the default, case-insensitive
    /// volume format compare equal here.
    ///
    /// Purely textual on purpose. `standardizedFileURL` looks at the disk —
    /// it drops a leading `/private` only while the file exists — so the key
    /// of one and the same path changed the moment its file was moved away,
    /// and a swap of two names stopped being recognised halfway through.
    static func key(for url: URL) -> String {
        url.path.lowercased()
    }
}
