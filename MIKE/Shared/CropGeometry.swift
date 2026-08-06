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

/// The eight resize handles a crop frame exposes, shared by Quick Edit's
/// image crop and Trim Video's video crop — moved out of Quick Edit once Trim
/// Video became a second real consumer, the same promotion `FileRow`/
/// `FolderRow` went through earlier for the identical reason.
enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// Pure crop-rectangle math, with no view or image dependency — both
/// consumers overlay this on completely different things (a static `NSImage`
/// for Quick Edit, a live `AVPlayerView` for Trim Video), so nothing here
/// draws anything. `bounds`/`cropRect` are always in the same real coordinate
/// space as whatever is being cropped (full-resolution image pixels, or a
/// video's displayed — post-rotation — pixel size); callers convert to/from
/// on-screen display points themselves.
enum CropGeometry {
    static func handlePosition(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Resizes from a fixed opposite anchor: the edge(s) this handle does not
    /// own are never reassigned, so they cannot move even if the drag
    /// overshoots past them — verified against a real overshoot case rather
    /// than assumed, since a naive "adjust both origin and size, then clamp
    /// size to the minimum" approach lets the anchor edge drift.
    static func applyHandleDrag(_ handle: CropHandle, delta: CGSize, start: CGRect, bounds: CGSize, minSize: CGFloat) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY

        func moveMinX(_ raw: CGFloat) { minX = min(max(raw, 0), maxX - minSize) }
        func moveMaxX(_ raw: CGFloat) { maxX = max(min(raw, bounds.width), minX + minSize) }
        func moveMinY(_ raw: CGFloat) { minY = min(max(raw, 0), maxY - minSize) }
        func moveMaxY(_ raw: CGFloat) { maxY = max(min(raw, bounds.height), minY + minSize) }

        switch handle {
        case .topLeft:
            moveMinX(start.minX + delta.width)
            moveMinY(start.minY + delta.height)
        case .top:
            moveMinY(start.minY + delta.height)
        case .topRight:
            moveMaxX(start.maxX + delta.width)
            moveMinY(start.minY + delta.height)
        case .right:
            moveMaxX(start.maxX + delta.width)
        case .bottomRight:
            moveMaxX(start.maxX + delta.width)
            moveMaxY(start.maxY + delta.height)
        case .bottom:
            moveMaxY(start.maxY + delta.height)
        case .bottomLeft:
            moveMinX(start.minX + delta.width)
            moveMaxY(start.maxY + delta.height)
        case .left:
            moveMinX(start.minX + delta.width)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Clamps a rect (already the desired size) to stay within `bounds`,
    /// preserving its width/height whenever there is room — used for moving
    /// the whole frame and for resetting to the full bounds.
    static func clamp(_ rect: CGRect, to bounds: CGSize, minSize: CGFloat) -> CGRect {
        var result = rect
        result.size.width = min(max(result.size.width, minSize), bounds.width)
        result.size.height = min(max(result.size.height, minSize), bounds.height)
        result.origin.x = min(max(result.origin.x, 0), bounds.width - result.size.width)
        result.origin.y = min(max(result.origin.y, 0), bounds.height - result.size.height)
        return result
    }
}
