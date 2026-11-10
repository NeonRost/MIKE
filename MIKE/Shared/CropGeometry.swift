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
import SwiftUI

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

/// The draggable crop frame: dims everything outside it, draws its border and
/// eight handles, and lets it be resized or moved.
///
/// It draws no picture of its own. Trim Video lays it over the player, Quick
/// Edit over its rotated preview — both used to carry a copy of this view,
/// identical down to the handle diameter, differing only in whether an image
/// was drawn underneath. The letterbox math is the shared part: the frame has
/// to line up with where an aspect-fitted picture of `displaySize` actually
/// sits inside the available space. `cropRect` and `displaySize` are both in
/// the picture's own pixel space; display points only ever exist inside this
/// view.
struct CropOverlay: View {
    let displaySize: CGSize
    @Binding var cropRect: CGRect
    let minCropSize: CGFloat
    let isEnabled: Bool

    @State private var dragStartRect: CGRect?

    private let handleDiameter: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let scale = displayScale(for: geo.size)
            let renderedSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
            let origin = CGPoint(x: (geo.size.width - renderedSize.width) / 2, y: (geo.size.height - renderedSize.height) / 2)
            let displayRect = CGRect(
                x: origin.x + cropRect.origin.x * scale,
                y: origin.y + cropRect.origin.y * scale,
                width: cropRect.width * scale,
                height: cropRect.height * scale
            )

            ZStack(alignment: .topLeading) {
                // Even-odd fill: the outer rect minus the crop rect, dimmed —
                // darkens everything outside the frame, leaves the inside
                // clear, so the video keeps showing through unobstructed.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRect(displayRect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: max(displayRect.width, 0), height: max(displayRect.height, 0))
                    .position(x: displayRect.midX, y: displayRect.midY)
                    .contentShape(Rectangle())
                    .gesture(isEnabled ? moveGesture(scale: scale) : nil)

                if isEnabled {
                    ForEach(Array(CropHandle.allCases.enumerated()), id: \.offset) { _, handle in
                        let position = CropGeometry.handlePosition(handle, in: displayRect)
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                            .frame(width: handleDiameter, height: handleDiameter)
                            .contentShape(Circle().inset(by: -8))
                            .position(position)
                            .gesture(dragGesture(for: handle, scale: scale))
                    }
                }
            }
            .clipped()
        }
    }

    private func displayScale(for size: CGSize) -> CGFloat {
        guard displaySize.width > 0, displaySize.height > 0, size.width > 0, size.height > 0 else { return 1 }
        return min(size.width / displaySize.width, size.height / displaySize.height)
    }

    private func dragGesture(for handle: CropHandle, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = cropRect }
                guard let start = dragStartRect else { return }
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                cropRect = CropGeometry.applyHandleDrag(handle, delta: delta, start: start, bounds: displaySize, minSize: minCropSize)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func moveGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = cropRect }
                guard let start = dragStartRect else { return }
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                var rect = start
                rect.origin.x += delta.width
                rect.origin.y += delta.height
                cropRect = CropGeometry.clamp(rect, to: displaySize, minSize: minCropSize)
            }
            .onEnded { _ in dragStartRect = nil }
    }
}
