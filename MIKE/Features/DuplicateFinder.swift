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

struct DuplicateFile: Identifiable {
    let url: URL
    let modified: Date?
    var keep: Bool

    var id: URL { url }
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let fileSize: Int64
    var files: [DuplicateFile]
}

enum DuplicateFinderError: Error {
    case cancelled
}

enum DuplicateFinder {
    /// One walk per chosen folder; hidden entries, non-regular files,
    /// symlinks and Finder aliases are all skipped, and a file reachable
    /// through more than one chosen folder is only counted once.
    static func collectFiles(in folders: [URL], includeSubfolders: Bool) -> [URL] {
        var result: [URL] = []
        var seen = Set<URL>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !includeSubfolders {
            options.insert(.skipsSubdirectoryDescendants)
        }

        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: keys,
                options: options
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                guard values.isRegularFile == true else { continue }
                guard values.isSymbolicLink != true, values.isAliasFile != true else { continue }
                if seen.insert(url).inserted {
                    result.append(url)
                }
            }
        }
        return result
    }

    /// Two real phases: files with a unique size can never match anything and
    /// are dropped for free before any content is read; only the remaining
    /// same-size candidates are hashed. Cancelling at any point throws
    /// immediately — no partial groups are ever returned.
    static func findDuplicates(
        files: [URL],
        onScanProgress: @escaping (Int, Int) -> Void,
        onCompareProgress: @escaping (Int, Int) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> [DuplicateGroup] {
        var bySize: [Int64: [URL]] = [:]
        // Reported only on a whole-percent change — same rule as
        // `HashCalculator.hash`'s own progress. Without it, a folder with
        // tens of thousands of files floods the main actor with one
        // dispatch and one SwiftUI re-render per file, which is what was
        // actually behind a beachball-then-crash on a 22,000-file scan: the
        // background loop raced far ahead of a main thread that could never
        // drain the backlog of queued updates.
        var lastScanPercent = -1
        for (index, url) in files.enumerated() {
            if isCancelled() { throw DuplicateFinderError.cancelled }
            reportProgress(current: index + 1, total: files.count, lastPercent: &lastScanPercent, onProgress: onScanProgress)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            bySize[Int64(size), default: []].append(url)
        }
        onScanProgress(files.count, files.count)

        let candidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }

        var byHash: [String: [URL]] = [:]
        var lastComparePercent = -1
        for (index, url) in candidates.enumerated() {
            if isCancelled() { throw DuplicateFinderError.cancelled }
            reportProgress(current: index + 1, total: candidates.count, lastPercent: &lastComparePercent, onProgress: onCompareProgress)
            do {
                let hash = try HashCalculator.sha256(file: url)
                byHash[hash, default: []].append(url)
            } catch HashCalculationError.cancelled {
                throw DuplicateFinderError.cancelled
            } catch {
                // Unreadable file (permissions, vanished mid-scan, …) — not
                // fatal for the rest of the batch, just excluded.
                continue
            }
        }
        onCompareProgress(candidates.count, candidates.count)

        let groups: [DuplicateGroup] = byHash.values.compactMap { urls in
            guard urls.count > 1 else { return nil }
            let size = (try? urls[0].resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            var groupFiles = urls.map { url -> DuplicateFile in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return DuplicateFile(url: url, modified: modified, keep: false)
            }
            // Oldest first: the oldest copy is kept by default, everything
            // newer is suggested for the trash.
            groupFiles.sort { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
            groupFiles[0].keep = true
            return DuplicateGroup(fileSize: Int64(size), files: groupFiles)
        }

        // Biggest space savings first — the most useful order to act on.
        return groups.sorted { lhs, rhs in
            let lhsWasted = lhs.fileSize * Int64(lhs.files.count - 1)
            let rhsWasted = rhs.fileSize * Int64(rhs.files.count - 1)
            return lhsWasted > rhsWasted
        }
    }

    private static func reportProgress(
        current: Int,
        total: Int,
        lastPercent: inout Int,
        onProgress: (Int, Int) -> Void
    ) {
        guard total > 0 else { return }
        let percent = Int((Double(current) / Double(total)) * 100)
        guard percent != lastPercent else { return }
        lastPercent = percent
        onProgress(current, total)
    }
}
