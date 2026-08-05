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

/// Shared by both archive formats' extraction: an entry's stored path is
/// attacker-controllable text, not a trusted file system path — a "Zip Slip"
/// entry named `../../Library/LaunchAgents/evil.plist` would otherwise write
/// outside the folder the user picked. Neither ZIPFoundation nor SWCompression
/// guards against this on their own, so MIKE resolves every entry path itself
/// before it ever becomes a destination URL.
enum ArchivePath {
    /// Normalizes `rawPath` into a sequence of path components confined to the
    /// extraction root: backslashes become forward slashes, empty and `.`
    /// segments are dropped, and a `..` that would climb above the root causes
    /// the whole entry to be rejected (`nil`) rather than silently clamped —
    /// clamping could still collide two different malicious entries into the
    /// same safe path.
    static func sanitizedRelativePath(_ rawPath: String) -> String? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        var resolved: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !resolved.isEmpty else { return nil }
                resolved.removeLast()
                continue
            }
            resolved.append(String(component))
        }
        guard !resolved.isEmpty else { return nil }
        return resolved.joined(separator: "/")
    }
}

/// ZIPFoundation 0.9.20 has no public API to detect an encrypted entry: its
/// `Entry` initializer silently returns `nil` for one (general-purpose bit 0
/// set), which does not just skip that one entry — `Sequence`/`AnyIterator`
/// reads a single `nil` as "no more elements", so an encrypted entry midway
/// through an archive silently truncates every entry after it too, with no
/// thrown error to catch. A password-protected archive would therefore look
/// like a valid one that happens to be missing most of its files.
///
/// So this is checked before ZIPFoundation ever opens the file: a direct scan
/// for the local file header signature (`PK\u{03}\u{04}`) and its
/// general-purpose flag, the same two bytes ZIPFoundation's own (private)
/// `isEncrypted` check reads. False positives from those four bytes
/// coincidentally appearing inside compressed entry data are the reason this
/// only gates the up-front "password protected" message — actual extraction
/// still goes through ZIPFoundation itself.
enum ZipEncryptionScan {
    static func containsEncryptedEntry(in data: Data) -> Bool {
        guard data.count > 30 else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let count = raw.count
            var index = 0
            while index < count - 8 {
                if base[index] == 0x50, base[index + 1] == 0x4B, base[index + 2] == 0x03, base[index + 3] == 0x04 {
                    let flag = UInt16(base[index + 6]) | (UInt16(base[index + 7]) << 8)
                    if flag & 0x1 != 0 { return true }
                }
                index += 1
            }
            return false
        }
    }
}

/// Throttles a progress callback to whole-percent changes, the same rule
/// `DuplicateFinder`'s own `reportProgress` uses — without it, an archive
/// with tens of thousands of small entries floods the main actor with one
/// dispatch and one SwiftUI re-render per entry.
enum ArchiveProgress {
    static func report(
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
