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
/// So this is checked before ZIPFoundation ever opens the file — by reading
/// the archive's own table of contents, the central directory, where every
/// entry's flags are listed.
///
/// An earlier version searched the whole file for the local-header signature
/// `PK\u{03}\u{04}` instead. Those four bytes also occur by chance inside
/// entry data, and whenever the byte that followed happened to be odd, a
/// perfectly ordinary archive was refused as password-protected — verified
/// with an unencrypted ZIP that `unzip -t` passed. The odds grow with the size
/// of the archive, and it meant loading the entire file into memory first.
enum ZipEncryptionScan {

    private static let endOfCentralDirectory: UInt32 = 0x0605_4b50
    private static let zip64Locator: UInt32 = 0x0706_4b50
    private static let zip64EndOfCentralDirectory: UInt32 = 0x0606_4b50
    private static let centralFileHeader: UInt32 = 0x0201_4b50

    /// `false` both for "no encrypted entry" and for "could not make sense of
    /// this file" — a file that is not a readable ZIP is ZIPFoundation's to
    /// reject, with the right message for it.
    static func containsEncryptedEntry(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22 else { return false }

        // The end record sits at the very end, behind an optional comment of
        // at most 65,535 bytes.
        let tailLength = min(fileSize, 22 + 65_535 + 20)
        guard let tail = read(handle, at: fileSize - tailLength, count: Int(tailLength)),
              let recordOffset = lastIndex(of: endOfCentralDirectory, in: tail),
              recordOffset + 22 <= tail.count
        else { return false }

        var directorySize = UInt64(uint32(tail, at: recordOffset + 12))
        var directoryOffset = UInt64(uint32(tail, at: recordOffset + 16))

        // ZIP64: the 32-bit fields are all ones and the real values live in a
        // separate record, found through a locator just before this one.
        if directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            let locatorOffset = recordOffset - 20
            guard locatorOffset >= 0, uint32(tail, at: locatorOffset) == zip64Locator else { return false }
            let recordPosition = uint64(tail, at: locatorOffset + 8)
            guard let record = read(handle, at: recordPosition, count: 56),
                  uint32(record, at: 0) == zip64EndOfCentralDirectory
            else { return false }
            directorySize = uint64(record, at: 40)
            directoryOffset = uint64(record, at: 48)
        }

        // A table of contents is small; one far beyond that is not a real one.
        guard directorySize > 0, directorySize < 512 * 1024 * 1024,
              directoryOffset + directorySize <= fileSize,
              let directory = read(handle, at: directoryOffset, count: Int(directorySize))
        else { return false }

        var index = 0
        while index + 46 <= directory.count {
            guard uint32(directory, at: index) == centralFileHeader else { break }
            let flags = uint16(directory, at: index + 8)
            if flags & 0x1 != 0 { return true }
            let nameLength = Int(uint16(directory, at: index + 28))
            let extraLength = Int(uint16(directory, at: index + 30))
            let commentLength = Int(uint16(directory, at: index + 32))
            index += 46 + nameLength + extraLength + commentLength
        }
        return false
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count),
              data.count == count
        else { return nil }
        return [UInt8](data)
    }

    private static func lastIndex(of signature: UInt32, in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var index = bytes.count - 4
        while index >= 0 {
            if uint32(bytes, at: index) == signature { return index }
            index -= 1
        }
        return nil
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(uint32(bytes, at: offset)) | (UInt64(uint32(bytes, at: offset + 4)) << 32)
    }
}

/// How much TAR.GZ may be handled at once. SWCompression has no streaming
/// interface: packing holds every file, then the tar, then its gzipped copy;
/// unpacking holds the gzip, the tar and each entry. A bound of this size
/// keeps the peak within what a Mac with 8 GB can give one app.
enum TarGzLimits {
    static let maximumPackedInput: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumArchiveSize: Int64 = 1024 * 1024 * 1024

    static func describe(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
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
