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

import Darwin
import Foundation
import UniformTypeIdentifiers

/// Direct POSIX extended-attribute access. Foundation has no wrapper for
/// these, so they come straight from Darwin/libc — the conventional
/// two-call pattern (ask for the size, then fill a buffer of that size) for
/// every one of the four calls.
enum XAttr {
    static func listNames(atPath path: String) -> [String] {
        let size = listxattr(path, nil, 0, 0)
        guard size > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: size)
        let result = listxattr(path, &buffer, size, 0)
        guard result > 0 else { return [] }

        // listxattr packs NUL-terminated C strings back-to-back in the buffer.
        return buffer[0..<result]
            .split(separator: 0)
            .compactMap { String(bytes: $0.map { UInt8(bitPattern: $0) }, encoding: .utf8) }
    }

    static func read(name: String, atPath path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        let result = getxattr(path, name, &buffer, size, 0, 0)
        guard result > 0 else { return nil }
        return Data(buffer[0..<result])
    }

    @discardableResult
    static func remove(name: String, atPath path: String) -> Bool {
        removexattr(path, name, 0) == 0
    }
}

struct FileInfoGeneral {
    let name: String
    let path: String
    let sizeBytes: Int64
    let mimeType: String?
    let created: Date?
    let modified: Date?
    let accessed: Date?
}

struct XAttrEntry: Identifiable {
    let id: String
    let key: String
    let displayValue: String
    let isRemovable: Bool

    init(key: String, displayValue: String, isRemovable: Bool) {
        self.id = key
        self.key = key
        self.displayValue = displayValue
        self.isRemovable = isRemovable
    }
}

struct FileInfoPermissions {
    let owner: String?
    let group: String?
    let octal: String
    let symbolic: String
    let executable: Bool
}

struct FileInfoFinder {
    let tags: [String]
    let whereFrom: URL?
    let comment: String?
}

enum FileInfoReader {
    /// The one xattr this section allows removing — a quarantined download
    /// blocked from opening is the clear, safe case a Remove button belongs
    /// to; nothing else here is writable.
    static let quarantineKey = "com.apple.quarantine"
    private static let whereFromKey = "com.apple.metadata:kMDItemWhereFroms"
    /// Finder is the authoritative writer of the comment; this is a
    /// best-effort read of what it happens to have cached as an xattr, not a
    /// guaranteed-accurate mirror (that would need AppleScript/Automation
    /// permission, deliberately avoided here).
    private static let commentKey = "com.apple.metadata:kMDItemFinderComment"

    /// Raw xattr values longer than this are shown only by size — the same
    /// "don't dump a huge binary blob into the UI" rule the rest of the app
    /// already follows for oversized metadata values.
    private static let maxHexDisplayLength = 256

    static func read(url: URL) -> (general: FileInfoGeneral, xattrs: [XAttrEntry], permissions: FileInfoPermissions, finder: FileInfoFinder?) {
        let path = url.path
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentTypeKey, .creationDateKey,
            .contentModificationDateKey, .contentAccessDateKey, .tagNamesKey,
        ])
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)

        let general = FileInfoGeneral(
            name: url.lastPathComponent,
            path: path,
            sizeBytes: Int64(values?.fileSize ?? (attrs?[.size] as? Int) ?? 0),
            mimeType: values?.contentType?.preferredMIMEType,
            created: values?.creationDate,
            modified: values?.contentModificationDate,
            accessed: values?.contentAccessDate
        )

        let xattrs = XAttr.listNames(atPath: path)
            .map { name -> XAttrEntry in
                let data = XAttr.read(name: name, atPath: path) ?? Data()
                return XAttrEntry(key: name, displayValue: displayValue(for: data), isRemovable: name == quarantineKey)
            }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        let permissions = readPermissions(path: path, attrs: attrs)

        let tags = values?.tagNames ?? []
        let whereFrom = readWhereFrom(path: path)
        let comment = readComment(path: path)
        let finder: FileInfoFinder? = (!tags.isEmpty || whereFrom != nil || !(comment ?? "").isEmpty)
            ? FileInfoFinder(tags: tags, whereFrom: whereFrom, comment: comment)
            : nil

        return (general, xattrs, permissions, finder)
    }

    // MARK: - Value formatting

    private static func displayValue(for data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), isPrintable(text) {
            return text
        }
        if data.count <= maxHexDisplayLength {
            return data.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        return byteCountString(data.count)
    }

    private static func isPrintable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return text.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func byteCountString(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(count))
    }

    // MARK: - Finder metadata

    private static func readWhereFrom(path: String) -> URL? {
        guard let data = XAttr.read(name: whereFromKey, atPath: path) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String],
              let first = plist.first
        else { return nil }
        return URL(string: first)
    }

    private static func readComment(path: String) -> String? {
        guard let data = XAttr.read(name: commentKey, atPath: path) else { return nil }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? String
    }

    // MARK: - Permissions

    private static func readPermissions(path: String, attrs: [FileAttributeKey: Any]?) -> FileInfoPermissions {
        let posix = (attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        return FileInfoPermissions(
            owner: attrs?[.ownerAccountName] as? String,
            group: attrs?[.groupOwnerAccountName] as? String,
            octal: String(format: "%o", posix),
            symbolic: symbolicPermissions(posix),
            executable: FileManager.default.isExecutableFile(atPath: path)
        )
    }

    private static func symbolicPermissions(_ posix: UInt16) -> String {
        let flags: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(flags.map { posix & $0.0 != 0 ? $0.1 : "-" })
    }
}
