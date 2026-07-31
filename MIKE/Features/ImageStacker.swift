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
import SwiftUI

enum ImageStackerError: LocalizedError {
    case noImages
    case cannotRender
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .noImages:
            return String(localized: "No images found.")
        case .cannotRender:
            return String(localized: "The combined image could not be rendered.")
        case .cannotWrite:
            return String(localized: "The combined image could not be written.")
        }
    }
}

/// Which way the images are laid out.
enum StackDirection: String, CaseIterable, Identifiable {
    case vertical
    case horizontal

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        }
    }
}

/// What happens when the images are not all the same size.
///
/// Scaling leaves no gaps at all. Keeping the sizes means the smaller images
/// leave space on the cross axis, which is either filled with white — and
/// written as JPEG — or left transparent, which forces PNG.
enum SizeHandling: String, CaseIterable, Identifiable {
    case scaleToSmallest
    case whiteStart
    case whiteCentered
    case transparentStart
    case transparentCentered

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .scaleToSmallest: return "Scale down to the smallest"
        case .whiteStart: return "Keep sizes, fill with white"
        case .whiteCentered: return "Keep sizes, fill with white, centred"
        case .transparentStart: return "Keep sizes, leave transparent"
        case .transparentCentered: return "Keep sizes, leave transparent, centred"
        }
    }

    /// Transparency cannot survive JPEG, so these write PNG instead.
    var isTransparent: Bool {
        self == .transparentStart || self == .transparentCentered
    }

    var isCentered: Bool {
        self == .whiteCentered || self == .transparentCentered
    }

    var scalesToSmallest: Bool { self == .scaleToSmallest }
}

enum ImageStacker {

    static let outputStem = "combined"
    static let acceptedExtensions: Set<String> = ["jpg", "jpeg", "png"]

    static func outputExtension(for handling: SizeHandling) -> String {
        handling.isTransparent ? "png" : "jpg"
    }

    static func outputName(for handling: SizeHandling) -> String {
        "\(outputStem).\(outputExtension(for: handling))"
    }

    /// Matches the output and every collision-avoiding variant of it, in both
    /// possible extensions, so a second run never picks up what a first run
    /// produced — `combined.png` is otherwise a perfectly valid input.
    static func isOutput(_ name: String) -> Bool {
        name.range(
            of: "^\(outputStem)( \\([0-9]+\\))?\\.(jpg|png)$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Files that would be stacked, in the order they will appear.
    ///
    /// Sorted the way the Finder sorts: digits compare by value, so `page2`
    /// comes before `page10`.
    static func candidates(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { url in
                guard acceptedExtensions.contains(url.pathExtension.lowercased()) else { return false }
                guard !isOutput(url.lastPathComponent) else { return false }
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    /// Everything in the folder, written back into that same folder.
    static func stack(
        folder: URL,
        direction: StackDirection = .vertical,
        handling: SizeHandling = .whiteStart
    ) throws -> URL {
        try stack(
            files: candidates(in: folder),
            into: folder,
            direction: direction,
            handling: handling
        )
    }

    /// Combines the given images, in the given order, into a single image.
    static func stack(
        files: [URL],
        into directory: URL,
        direction: StackDirection = .vertical,
        handling: SizeHandling = .whiteStart
    ) throws -> URL {
        guard !files.isEmpty else { throw ImageStackerError.noImages }

        let images = files.compactMap { try? ImageConverter.load(from: $0) }
        guard !images.isEmpty else { throw ImageStackerError.noImages }

        let sizes = drawnSizes(for: images, direction: direction, handling: handling)
        let canvas = canvasSize(for: sizes, direction: direction)
        guard canvas.width > 0, canvas.height > 0 else {
            throw ImageStackerError.cannotRender
        }

        // A transparent result needs a real alpha channel; the opaque one is
        // cheaper and is what JPEG wants anyway.
        let bitmapInfo = handling.isTransparent
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: canvas.width,
            height: canvas.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { throw ImageStackerError.cannotRender }

        // A fresh context is already clear, so only the white variant paints.
        if !handling.isTransparent {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        }
        context.interpolationQuality = .high

        // Core Graphics counts upwards from the bottom, so the running offset
        // is converted for the vertical case and for top alignment.
        var offset = 0
        for (image, size) in zip(images, sizes) {
            let rect: CGRect
            switch direction {
            case .vertical:
                let x = handling.isCentered ? (canvas.width - size.width) / 2 : 0
                let y = canvas.height - offset - size.height
                rect = CGRect(x: x, y: y, width: size.width, height: size.height)
                offset += size.height
            case .horizontal:
                let y = handling.isCentered
                    ? (canvas.height - size.height) / 2
                    : canvas.height - size.height          // top aligned
                rect = CGRect(x: offset, y: y, width: size.width, height: size.height)
                offset += size.width
            }
            context.draw(image, in: rect)
        }

        guard let combined = context.makeImage() else {
            throw ImageStackerError.cannotRender
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Appends " (2)", " (3)", … rather than overwriting an earlier result.
        let target = ImageConverter.uniqueURL(
            directory: directory,
            stem: outputStem,
            extension: outputExtension(for: handling)
        )

        let type = handling.isTransparent ? "public.png" : "public.jpeg"
        guard let destination = CGImageDestinationCreateWithURL(
            target as CFURL, type as CFString, 1, nil
        ) else { throw ImageStackerError.cannotWrite }

        // Quality 95, as in the original. PNG ignores it.
        CGImageDestinationAddImage(
            destination,
            combined,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ImageStackerError.cannotWrite
        }

        return target
    }

    // MARK: - Geometry

    /// The size each image is drawn at. Only the scaling mode changes them;
    /// the other modes draw every image at its own size.
    private static func drawnSizes(
        for images: [CGImage],
        direction: StackDirection,
        handling: SizeHandling
    ) -> [(width: Int, height: Int)] {
        guard handling.scalesToSmallest else {
            return images.map { (width: $0.width, height: $0.height) }
        }

        switch direction {
        case .vertical:
            // Everything gets the narrowest width; heights follow the aspect.
            let target = images.map(\.width).min() ?? 0
            return images.map { image in
                let height = Double(image.height) * Double(target) / Double(max(image.width, 1))
                return (width: max(target, 1), height: max(Int(height.rounded()), 1))
            }
        case .horizontal:
            // Everything gets the shortest height; widths follow the aspect.
            let target = images.map(\.height).min() ?? 0
            let scaled = images.map { image -> (width: Int, height: Int) in
                let width = Double(image.width) * Double(target) / Double(max(image.height, 1))
                return (width: max(Int(width.rounded()), 1), height: max(target, 1))
            }
            return scaled
        }
    }

    private static func canvasSize(
        for sizes: [(width: Int, height: Int)],
        direction: StackDirection
    ) -> (width: Int, height: Int) {
        switch direction {
        case .vertical:
            return (
                width: sizes.map(\.width).max() ?? 0,
                height: sizes.map(\.height).reduce(0, +)
            )
        case .horizontal:
            return (
                width: sizes.map(\.width).reduce(0, +),
                height: sizes.map(\.height).max() ?? 0
            )
        }
    }
}
