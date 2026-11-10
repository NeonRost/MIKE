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

/// What happened to the untouched original alongside the edited file.
enum BackupState {
    /// exiftool created `<name>.<ext>_original` this run.
    case created
    /// A `_original` was already there from an earlier run; it was kept and no
    /// new backup was written over it.
    case preserved
}

/// What an exiftool write did. Failure is thrown, not returned.
enum ExifWriteOutcome {
    /// exiftool reported at least one file updated.
    case updated(BackupState)
    /// exiftool ran cleanly but changed nothing.
    case nothingToDo
}

enum ExifWriteError: LocalizedError, ToolLogCarrying {
    case launchFailed
    /// exiftool's own error text, passed through untranslated, with the rest
    /// of what it printed kept for the Details popover.
    case toolFailed(String, log: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed:
            return String(localized: "exiftool could not be started.")
        case .toolFailed(let detail, _):
            return detail
        }
    }

    var toolLog: String? {
        if case .toolFailed(_, let log) = self, !log.isEmpty { return log }
        return nil
    }
}

/// The one place that runs exiftool as a writer and protects the original.
///
/// Both the Metadata and the Embedded sections go through here so their
/// `_original` behaviour is guaranteed identical: the same backup rule, the
/// same `--` guard, the same result parsing.
enum ExifToolWrite {

    /// The backup exiftool would create for `file`. exiftool's rule is to
    /// append `_original` to the whole name, extension included.
    static func backupURL(for file: URL) -> URL {
        URL(fileURLWithPath: file.path + "_original")
    }

    static func backupExists(for file: URL) -> Bool {
        FileManager.default.fileExists(atPath: backupURL(for: file).path)
    }

    /// Runs a set of `-Tag=value` (or `-Tag=` deletion) assignments against
    /// `file`. Must be called off the main thread.
    ///
    /// - Parameters:
    ///   - configFile: an optional exiftool `-config` file. It is placed first
    ///     because exiftool requires `-config` before any other option. Used
    ///     by the Embedded section to register arbitrary PNG text keywords as
    ///     writable tags.
    static func run(
        configFile: URL? = nil,
        assignments: [String],
        on file: URL,
        exiftool: URL
    ) throws -> ExifWriteOutcome {
        // Decide up front whether a backup already exists. If it does we must
        // not let exiftool overwrite it — that file is the real original from
        // an earlier run, and a second write would replace it with the
        // already-edited copy. `-overwrite_original` tells exiftool to edit in
        // place and leave the existing `_original` alone.
        let backupExisted = backupExists(for: file)

        var arguments: [String] = []
        if let configFile {
            arguments.append("-config")
            arguments.append(configFile.path)
        }
        arguments.append(contentsOf: assignments)
        if backupExisted {
            arguments.append("-overwrite_original")
        }
        // Everything after `--` is a file name, so a field value that happens
        // to start with a dash can never be read as an option. The tag
        // assignments already fold the value inside a single argument, but the
        // marker is kept as the same belt-and-braces defence the download URL
        // gets.
        arguments.append("--")
        arguments.append(file.path)

        let outcome = ProcessRunner.run(executable: exiftool, arguments: arguments, logLimit: 200)
        if outcome.launchFailed { throw ExifWriteError.launchFailed }
        guard outcome.status == 0 else {
            throw ExifWriteError.toolFailed(
                outcome.failureSummary(tool: "exiftool"), log: outcome.logText
            )
        }

        if let updated = updatedCount(in: outcome.logText), updated > 0 {
            return .updated(backupExisted ? .preserved : .created)
        }
        // Exit 0 but nothing changed: exiftool says "0 image files updated"
        // (e.g. removing a tag that was not there).
        return .nothingToDo
    }

    /// Reads the "N image files updated" line exiftool prints on success.
    private static func updatedCount(in output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.contains("image files updated") else { continue }
            let digits = line.prefix { $0 == " " || $0.isNumber }
            if let value = Int(digits.trimmingCharacters(in: .whitespaces)) {
                return value
            }
        }
        return nil
    }
}
