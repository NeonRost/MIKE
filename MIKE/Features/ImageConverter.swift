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

import CoreGraphics
import Foundation
import ImageIO

enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"
    case heic = "HEIC"
    case heif = "HEIF"
    case webp = "WEBP"
    case tiff = "TIFF"
    case bmp = "BMP"
    case gif = "GIF"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .heif: return "heif"
        case .webp: return "webp"
        case .tiff: return "tiff"
        case .bmp: return "bmp"
        case .gif: return "gif"
        }
    }

    /// ImageIO cannot *write* WebP (it reads it fine), so that one format
    /// goes out through an external encoder.
    var requiresExternalEncoder: Bool { self == .webp }

    /// HEIC and HEIF are read-only here: ImageIO reads both natively since
    /// macOS 13, but they are deliberately never offered as a conversion
    /// target — see `writableCases`.
    var isReadOnly: Bool { self == .heic || self == .heif }

    var typeIdentifier: String? {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        case .heic, .heif, .webp: return nil
        }
    }

    /// JPEG and BMP carry no alpha, so transparency is flattened onto white
    /// first — matching what the original did.
    var flattensAlpha: Bool {
        self == .jpeg || self == .bmp
    }

    /// Every format a conversion can target — `allCases` minus HEIC/HEIF,
    /// which only ever appear as a source format.
    static var writableCases: [ImageFormat] {
        allCases.filter { !$0.isReadOnly }
    }
}

/// WebP cannot be written by ImageIO, so it goes out through an external
/// encoder. `cwebp` is the reference encoder; an ffmpeg built with libwebp
/// does the same job, but the stock Homebrew ffmpeg is not.
enum WebPEncoder {
    case cwebp(URL)
    case ffmpeg(URL)
}

enum ImageConversionError: LocalizedError {
    case cannotRead
    case cannotRender
    case cannotWrite
    case webpEncoderMissing
    case encoderFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotRead:
            return String(localized: "The image could not be read.")
        case .cannotRender:
            return String(localized: "The image could not be rendered.")
        case .cannotWrite:
            return String(localized: "The image could not be written.")
        case .webpEncoderMissing:
            return String(localized: "WebP export needs cwebp. See Setup.")
        // Passed through untranslated: this is the encoder's own output.
        case .encoderFailed(let detail): return detail
        case .downloadFailed(let detail): return detail
        }
    }
}

enum ImageConverter {

    // MARK: - Loading

    static func load(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageConversionError.cannotRead }
        return image
    }

    static func load(from data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageConversionError.cannotRead }
        return image
    }

    /// The source's own EXIF/GPS/IPTC properties, for a caller that wants to
    /// carry them into a newly-written file. `CGImage` is pixel data only —
    /// Core Graphics never attaches metadata to it — so this has to be read
    /// separately at load time and re-attached explicitly at write time (see
    /// `write(image:to:format:webpEncoder:quality:metadata:)`). Verified
    /// directly: without this, every image MIKE writes through
    /// `CGImageDestination` loses all EXIF/GPS silently, not just the fields
    /// a feature meant to strip.
    static func metadata(from url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    static func download(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(HTTPDefaults.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ImageConversionError.downloadFailed(
                    String(localized: "HTTP \(http.statusCode)", comment: "Failed image download")
                )
            }
            return data
        } catch let error as ImageConversionError {
            throw error
        } catch {
            throw ImageConversionError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: - Conversion

    /// - Parameters:
    ///   - webpEncoder: only needed for WebP output.
    ///   - quality: JPEG compression quality, 0...1. Ignored for every other
    ///     format. Defaults to the maximum quality ImageIO offers, matching
    ///     Convert Format's single-file mode, which never passes this
    ///     argument at all.
    static func convert(
        image: CGImage,
        stem: String,
        to format: ImageFormat,
        in directory: URL,
        webpEncoder: WebPEncoder?,
        quality: Double = 1.0
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let prepared = format.flattensAlpha ? try flattenOnWhite(image) : image
        let target = uniqueURL(directory: directory, stem: stem, extension: format.fileExtension)

        if format == .webp {
            guard let webpEncoder else { throw ImageConversionError.webpEncoderMissing }
            try writeWebP(prepared, to: target, using: webpEncoder)
        } else {
            try write(prepared, to: target, format: format, quality: quality)
        }
        return target
    }

    /// Writes `image` to the exact `target` path — unlike `convert(...)`, the
    /// name is not derived or uniquified here. For callers where the
    /// destination was already chosen by the user (an `NSSavePanel`, which
    /// handles its own overwrite confirmation), not picked automatically by
    /// MIKE. Quick Edit uses this; Convert Format's `convert(...)` still owns
    /// the auto-named-in-a-folder path.
    ///
    /// - Parameter metadata: source EXIF/GPS properties to carry into the
    ///   output, from `metadata(from:)`. Left `nil` by every existing caller
    ///   (Convert Format's behavior is unchanged); Quick Edit passes the
    ///   loaded source's metadata through so its own GPS/all-metadata
    ///   checkboxes have real data to act on.
    static func write(
        image: CGImage,
        to target: URL,
        format: ImageFormat,
        webpEncoder: WebPEncoder?,
        quality: Double = 1.0,
        metadata: [CFString: Any]? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let prepared = format.flattensAlpha ? try flattenOnWhite(image) : image
        if format == .webp {
            guard let webpEncoder else { throw ImageConversionError.webpEncoderMissing }
            try writeWebP(prepared, to: target, using: webpEncoder)
        } else {
            try write(prepared, to: target, format: format, quality: quality, metadata: metadata)
        }
    }

    /// White canvas first, image drawn on top — the same result the original
    /// produced by pasting through the alpha mask.
    static func flattenOnWhite(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ImageConversionError.cannotRender }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)

        guard let result = context.makeImage() else {
            throw ImageConversionError.cannotRender
        }
        return result
    }

    static func write(
        _ image: CGImage,
        to url: URL,
        format: ImageFormat,
        quality: Double = 1.0,
        metadata: [CFString: Any]? = nil
    ) throws {
        guard let identifier = format.typeIdentifier,
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, identifier as CFString, 1, nil
              )
        else { throw ImageConversionError.cannotWrite }

        var options: [CFString: Any] = metadata ?? [:]
        if format == .jpeg {
            // Chroma subsampling is not exposed here, unlike Pillow's
            // subsampling=0.
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }

        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageConversionError.cannotWrite
        }
    }

    /// Lossless WebP through an external encoder: a temporary PNG carries the
    /// pixels (and any alpha) across untouched.
    private static func writeWebP(_ image: CGImage, to url: URL, using encoder: WebPEncoder) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("mike-webp-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try write(image, to: temporary, format: .png)

        let executable: URL
        let arguments: [String]
        let label: String

        switch encoder {
        case .cwebp(let tool):
            executable = tool
            arguments = ["-lossless", "-quiet", temporary.path, "-o", url.path]
            label = "cwebp"
        case .ffmpeg(let tool):
            executable = tool
            arguments = ["-y", "-i", temporary.path, "-c:v", "libwebp", "-lossless", "1", url.path]
            label = "ffmpeg"
        }

        var lastLines: [String] = []
        let status = ProcessRunner.stream(executable: executable, arguments: arguments) { line in
            lastLines.append(line)
            if lastLines.count > 10 { lastLines.removeFirst() }
        }

        guard status == 0 else {
            let detail = lastLines.last.map { String($0.prefix(140)) } ?? "exit \(status)"
            throw ImageConversionError.encoderFailed("\(label): \(detail)")
        }
    }

    // MARK: - Naming

    /// Appends " (2)", " (3)", … instead of overwriting an existing file.
    static func uniqueURL(directory: URL, stem: String, extension ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(stem).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    static func stem(fromRemote url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "image" : name
    }

    // MARK: - Batch scanning

    /// Files in `folder` matching `format`'s extension, top level only — no
    /// recursion into subfolders. Sorted the way the Finder sorts, so `img2`
    /// comes before `img10`.
    static func candidates(in folder: URL, format: ImageFormat) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { url in
                guard url.pathExtension.lowercased() == format.fileExtension else { return false }
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }
}

enum HTTPDefaults {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
}
