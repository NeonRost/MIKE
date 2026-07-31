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

import Compression
import Foundation

/// One textual chunk found in a PNG.
struct PNGTextChunk {
    var keyword: String
    var value: String
    /// The chunk type, shown verbatim: `tEXt`, `zTXt` or `iTXt`.
    var source: String
}

/// What the native reader found in a PNG.
struct PNGChunkContents {
    var text: [PNGTextChunk] = []
    /// PNG can carry a raw EXIF block in an `eXIf` chunk. Its decoded contents
    /// are EXIF and already shown by the Metadata section, so here only its
    /// presence and size are reported — no second decode.
    var exifByteSize: Int?
}

/// Reads a PNG's textual chunks straight from the binary format — no third-party
/// library, and no exiftool. This is the always-available path: it is what lets
/// the Embedded section show AUTOMATIC1111 `parameters` and ComfyUI
/// `prompt`/`workflow` even when exiftool is not installed, and it preserves the
/// exact keyword case (exiftool capitalises it).
enum PNGChunkReader {

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Returns `nil` when the file is not a PNG at all, so the caller can fall
    /// back to a format note.
    static func read(from url: URL) -> PNGChunkContents? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return read(data: data)
    }

    static func read(data: Data) -> PNGChunkContents? {
        guard data.count > 8, Array(data.prefix(8)) == signature else { return nil }

        var contents = PNGChunkContents()
        var index = 8

        while index + 8 <= data.count {
            let length = Int(beUInt32(data, at: index))
            let typeStart = index + 4
            let dataStart = typeStart + 4
            // A corrupt or truncated length must not read past the buffer.
            guard length >= 0, dataStart + length + 4 <= data.count else { break }

            let type = String(decoding: data[typeStart..<dataStart], as: UTF8.self)
            let chunk = data.subdata(in: dataStart..<dataStart + length)

            switch type {
            case "tEXt": parseTEXt(chunk, into: &contents)
            case "zTXt": parseZTXt(chunk, into: &contents)
            case "iTXt": parseITXt(chunk, into: &contents)
            case "eXIf": contents.exifByteSize = length
            case "IEND": return contents
            default: break
            }

            // length + 4 (type) + 4 (CRC), plus the 4 length bytes we started on.
            index = dataStart + length + 4
        }

        return contents
    }

    // MARK: - Chunk parsers

    /// `tEXt`: keyword \0 text, both Latin-1.
    private static func parseTEXt(_ chunk: Data, into contents: inout PNGChunkContents) {
        guard let separator = chunk.firstIndex(of: 0) else { return }
        let keyword = latin1(chunk[chunk.startIndex..<separator])
        let value = latin1(chunk[chunk.index(after: separator)...])
        contents.text.append(PNGTextChunk(keyword: keyword, value: value, source: "tEXt"))
    }

    /// `zTXt`: keyword \0 method(1) zlib-compressed-text. Latin-1 once inflated.
    private static func parseZTXt(_ chunk: Data, into contents: inout PNGChunkContents) {
        guard let separator = chunk.firstIndex(of: 0) else { return }
        let keyword = latin1(chunk[chunk.startIndex..<separator])
        let afterSeparator = chunk.index(after: separator)
        // One method byte follows the separator; only method 0 (zlib) exists.
        guard afterSeparator < chunk.endIndex else { return }
        let compressed = chunk[chunk.index(after: afterSeparator)...]
        guard let inflated = Self.inflate(Data(compressed)) else { return }
        contents.text.append(
            PNGTextChunk(keyword: keyword, value: latin1(inflated), source: "zTXt")
        )
    }

    /// `iTXt`: keyword \0 compressionFlag(1) compressionMethod(1) languageTag \0
    /// translatedKeyword \0 text. Text is UTF-8, optionally zlib-compressed.
    private static func parseITXt(_ chunk: Data, into contents: inout PNGChunkContents) {
        let bytes = Array(chunk)
        guard let kwEnd = bytes.firstIndex(of: 0), kwEnd + 2 < bytes.count else { return }
        let keyword = String(decoding: bytes[0..<kwEnd], as: UTF8.self)
        let compressionFlag = bytes[kwEnd + 1]
        // bytes[kwEnd + 2] is the compression method.

        // Two more null-terminated fields (language tag, translated keyword)
        // before the text begins.
        var cursor = kwEnd + 3
        var nullsToSkip = 2
        while nullsToSkip > 0, cursor < bytes.count {
            if bytes[cursor] == 0 { nullsToSkip -= 1 }
            cursor += 1
        }
        guard cursor <= bytes.count else { return }

        let textBytes = Data(bytes[cursor...])
        let value: String
        if compressionFlag == 1 {
            guard let inflated = Self.inflate(textBytes) else { return }
            value = String(decoding: inflated, as: UTF8.self)
        } else {
            value = String(decoding: textBytes, as: UTF8.self)
        }
        contents.text.append(PNGTextChunk(keyword: keyword, value: value, source: "iTXt"))
    }

    // MARK: - Helpers

    private static func beUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    private static func latin1<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        String(Array(bytes).map { Character(UnicodeScalar($0)) })
    }

    /// Inflates a PNG zlib stream. PNG uses the zlib wrapper (RFC 1950), while
    /// the Compression framework's `ZLIB` algorithm is raw DEFLATE (RFC 1951),
    /// so the 2-byte zlib header is stripped first; the trailing Adler-32 is
    /// simply not consumed once the DEFLATE stream ends.
    static func inflate(_ zlibData: Data) -> Data? {
        guard zlibData.count > 2 else { return nil }
        let deflate = zlibData.subdata(in: (zlibData.startIndex + 2)..<zlibData.endIndex)

        return deflate.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            guard let sourcePointer = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }

            var stream = compression_stream(
                dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
                dst_size: 0,
                src_ptr: sourcePointer,
                src_size: deflate.count,
                state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else { return nil }
            defer { compression_stream_destroy(&stream) }

            var output = Data()
            let bufferSize = 64 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            stream.src_ptr = sourcePointer
            stream.src_size = deflate.count

            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    output.append(buffer, count: bufferSize - stream.dst_size)
                    if status == COMPRESSION_STATUS_END { return output }
                default:
                    return nil
                }
            } while true
        }
    }
}
