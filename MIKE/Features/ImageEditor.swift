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

enum ImageEditError: LocalizedError {
    case cannotRotate
    case cannotCrop

    var errorDescription: String? {
        switch self {
        case .cannotRotate: return String(localized: "The image could not be rotated.")
        case .cannotCrop: return String(localized: "The image could not be cropped.")
        }
    }
}

/// Rotation and cropping, straight Core Graphics — no external tool.
///
/// Quick Edit's pipeline is always: rotate, then crop, then hand the result to
/// `ImageConverter` for format conversion. Rotating first is what lets the crop
/// frame stay axis-aligned and still describe the true final result — see
/// `rotate(_:degrees:)`.
enum ImageEditor {

    /// Rotates `image` by `degrees`, clockwise as the user sees it on screen,
    /// expanding the canvas to bound the rotated result and filling the
    /// newly-exposed corners white.
    ///
    /// Two coordinate systems meet here and their rotation senses are
    /// opposite: SwiftUI's `.rotationEffect` is clockwise-positive because its
    /// Y axis increases downward, while `CGContext`'s own `rotate(by:)` is
    /// counterclockwise-positive because a `CGImage`'s pixel buffer has Y
    /// increasing upward. Negating the angle here is what makes this function
    /// turn the pixels the same visual way the on-screen preview already
    /// turned — verified against a real, asymmetrically marked test image,
    /// not assumed from the math alone.
    static func rotate(_ image: CGImage, degrees: Double) throws -> CGImage {
        guard degrees != 0 else { return image }

        let radians = degrees * .pi / 180
        let width = Double(image.width)
        let height = Double(image.height)

        // Bounding box of the rotated rectangle.
        let newWidth = abs(width * cos(radians)) + abs(height * sin(radians))
        let newHeight = abs(width * sin(radians)) + abs(height * cos(radians))
        let pixelWidth = max(Int(newWidth.rounded()), 1)
        let pixelHeight = max(Int(newHeight.rounded()), 1)

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ImageEditError.cannotRotate }

        // White first — this is the fill that shows up in the newly-exposed
        // corners once the image is rotated inside the larger canvas.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.translateBy(x: Double(pixelWidth) / 2, y: Double(pixelHeight) / 2)
        // Negated: see the doc comment above.
        context.rotate(by: -radians)
        context.draw(
            image,
            in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        )

        guard let result = context.makeImage() else { throw ImageEditError.cannotRotate }
        return result
    }

    /// The pixel size a rotation by `degrees` would produce, without actually
    /// rendering anything — pure trigonometry. Used to keep the crop fields'
    /// coordinate space (the rotated canvas) known at every slider position
    /// without re-rendering the full-resolution image on every tick.
    static func rotatedSize(of size: CGSize, degrees: Double) -> CGSize {
        guard degrees != 0 else { return size }
        let radians = degrees * .pi / 180
        let width = Double(size.width)
        let height = Double(size.height)
        let newWidth = abs(width * cos(radians)) + abs(height * sin(radians))
        let newHeight = abs(width * sin(radians)) + abs(height * cos(radians))
        return CGSize(width: newWidth.rounded(), height: newHeight.rounded())
    }

    /// Crops `image` to `rect`, where `rect` is expressed top-left-origin —
    /// X/Y as distance from the left/top edge, the way the crop fields and the
    /// on-screen frame both describe it.
    ///
    /// No Y flip is applied. This looks wrong at first glance — `CGContext`
    /// drawing is bottom-left-origin, which is what `rotate(_:degrees:)` above
    /// has to account for — but `CGImage.cropping(to:)` operates directly on
    /// the pixel buffer's own row-major layout, which is top-left-origin
    /// already. An earlier version of this function flipped Y to "correct"
    /// for the bottom-left convention and was verified, with a real
    /// asymmetrically-marked test image, to crop the wrong half: flipping was
    /// the bug. Do not reintroduce a flip here without re-running that test.
    static func crop(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        guard let result = image.cropping(to: rect) else { throw ImageEditError.cannotCrop }
        return result
    }

    /// Rotate, then crop — the full pipeline up to (not including) format
    /// conversion. Used identically for the live low-resolution preview and
    /// the one-shot full-resolution processing at save time.
    static func process(_ image: CGImage, degrees: Double, cropRect: CGRect) throws -> CGImage {
        let rotated = try rotate(image, degrees: degrees)
        return try crop(rotated, to: cropRect)
    }

    /// A downscaled copy for interactive use, never written to disk. The
    /// canvas rotates and redraws this on every slider tick; the full-size
    /// original is only ever touched once, at save time, so the preview never
    /// costs any quality in the result.
    static func previewBase(of image: CGImage, maxDimension: CGFloat = 1400) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        guard scale < 1 else { return image }

        let targetWidth = max(Int((width * scale).rounded()), 1)
        let targetHeight = max(Int((height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }
}
