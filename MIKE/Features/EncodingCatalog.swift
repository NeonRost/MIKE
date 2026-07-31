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

import CoreFoundation
import Foundation

/// One encoding as offered in the picker. `name` is the canonical, untranslated
/// name shown to the user (proper names are never localized, see CLAUDE.md);
/// `shortName` is a filename-safe short form used for the `_<encoding>` output
/// suffix.
struct EncodingOption: Identifiable, Hashable {
    let encoding: String.Encoding
    let name: String
    let shortName: String

    var id: UInt { encoding.rawValue }
}

/// Builds the encoding lists shown in Convert Encoding from every encoding
/// Foundation/CoreFoundation actually supports on this system — the same
/// source TextEdit's own "Reopen With Encoding" menu draws from — rather than
/// hand-maintaining a list that could drift from what `String.Encoding` can
/// really do. `String.Encoding` only names a handful of encodings directly;
/// CP850, ISO-8859-15, GB2312 and KOI8-R have no Swift constant at all and
/// only exist by going through `CFStringEncoding`.
enum EncodingCatalog {

    /// The nine encodings called out explicitly, in this order, resolved
    /// directly through `CFStringConvertEncodingToNSStringEncoding` rather than
    /// looked up in `all`: `CFStringGetListOfAvailableEncodings` turns out not
    /// to include every encoding that actually converts and works (GB 2312-80
    /// is a real, usable encoding on this system but is absent from that
    /// "available" enumeration) — verified directly, not assumed.
    ///
    /// `CFStringEncodingExt.h`'s extended constants (CP850, ISO-8859-15,
    /// GB2312, KOI8-R) only reach Swift as cases of the `CFStringEncodings`
    /// enum, not as the flat `kCFStringEncoding…` C names — verified by trial
    /// compilation, since the Clang importer's exact spelling for these is not
    /// documented anywhere reliable.
    ///
    /// Shift-JIS is deliberately CoreFoundation's plain `kCFStringEncodingShiftJIS`
    /// ("Japanese (Shift JIS)"), not Swift's own named `String.Encoding.shiftJIS`
    /// — that constant is, confusingly, CP932/DOS Japanese under the hood
    /// ("Japanese (Windows, DOS)"), a different and less literal match to what
    /// "Shift-JIS" means here.
    ///
    /// GB2312 uses `kCFStringEncodingEUC_CN`, not the more literally-named
    /// `kCFStringEncodingGB_2312_80`: the latter converts to an
    /// `NSStringEncoding` value that Foundation's own runtime then rejects as
    /// "Unknown encoding" the moment it is actually used to encode or decode —
    /// confirmed by trying it. `EUC_CN` is CoreFoundation's own name for the
    /// exact same character set ("Simplified Chinese (GB 2312)") and actually
    /// works; EUC-CN is the byte-level encoding scheme that implements the
    /// GB 2312-80 character set and is what "GB2312" means in practice.
    static let common: [EncodingOption] = {
        let wanted: [(CFStringEncoding, String, String)] = [
            (CFStringEncoding(CFStringBuiltInEncodings.UTF8.rawValue), "UTF-8", "UTF-8"),
            (CFStringEncoding(CFStringBuiltInEncodings.unicode.rawValue), "UTF-16 (with BOM)", "UTF-16"),
            (CFStringEncoding(CFStringBuiltInEncodings.isoLatin1.rawValue), "Latin-1 (ISO-8859-1)", "Latin-1"),
            (CFStringEncoding(CFStringEncodings.isoLatin9.rawValue), "ISO-8859-15 / Latin-9", "ISO-8859-15"),
            (CFStringEncoding(CFStringBuiltInEncodings.windowsLatin1.rawValue), "Windows-1252", "Windows-1252"),
            (CFStringEncoding(CFStringEncodings.dosLatin1.rawValue), "CP850 (DOS, German)", "CP850"),
            (CFStringEncoding(CFStringEncodings.shiftJIS.rawValue), "Shift-JIS", "Shift-JIS"),
            (CFStringEncoding(CFStringEncodings.EUC_CN.rawValue), "GB2312", "GB2312"),
            (CFStringEncoding(CFStringEncodings.KOI8_R.rawValue), "KOI8-R", "KOI8-R"),
        ]
        return wanted.compactMap { cfEncoding, name, shortName in
            let raw = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            guard raw != kCFStringEncodingInvalidId else { return nil }
            return EncodingOption(encoding: String.Encoding(rawValue: raw), name: name, shortName: shortName)
        }
    }()

    /// Every encoding Foundation reports as available, sorted alphabetically by
    /// name, with the `common` set removed so nothing appears twice. Built
    /// once, lazily, since enumerating and naming ~200 entries is wasted work
    /// if this section is never opened.
    static let all: [EncodingOption] = {
        guard let list = CFStringGetListOfAvailableEncodings() else { return [] }

        var seen = Set<UInt>()
        var options: [EncodingOption] = []
        var index = 0
        while list[index] != kCFStringEncodingInvalidId {
            let cfEncoding = list[index]
            index += 1

            let raw = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            guard raw != kCFStringEncodingInvalidId, seen.insert(raw).inserted else { continue }
            guard let cfName = CFStringGetNameOfEncoding(cfEncoding) else { continue }

            let name = cfName as String
            options.append(EncodingOption(encoding: String.Encoding(rawValue: raw), name: name, shortName: name))
        }
        return options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    /// `all` minus the encodings already offered in `common`.
    static let others: [EncodingOption] = {
        let commonValues = Set(common.map(\.encoding.rawValue))
        return all.filter { !commonValues.contains($0.encoding.rawValue) }
    }()

    /// Every option, `common` first, keyed by raw encoding value — for looking
    /// up the name/short name of a `String.Encoding` a picker already selected,
    /// without rebuilding a combined list on every call.
    static let byEncoding: [UInt: EncodingOption] = {
        Dictionary(uniqueKeysWithValues: (common + others).map { ($0.encoding.rawValue, $0) })
    }()
}
