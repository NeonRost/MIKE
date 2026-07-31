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

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickEditView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry

    @State private var sourceFile: URL?
    @State private var sourceImage: CGImage?
    @State private var sourceMetadata: [CFString: Any]?
    @State private var previewBase: CGImage?

    // Rotation: a discrete quarter-turn count from the 90° button, composed
    // with the fine slider — see `totalAngle`.
    @State private var quarterTurns = 0
    @State private var fineAngle: Double = 0
    @State private var fineAngleText = "0.0"

    // Always in post-rotation, full-resolution pixel coordinates — the same
    // space the numeric fields show. Reset to the full canvas whenever the
    // rotation changes; see the plan note on why.
    @State private var cropRect: CGRect = .zero
    @State private var cropXText = "0"
    @State private var cropYText = "0"
    @State private var cropWidthText = "0"
    @State private var cropHeightText = "0"

    @State private var isDropTargeted = false

    @State private var explicitFormat: ImageFormat?
    @State private var jpegQuality: Double = 100
    @State private var removeGPS = true
    @State private var removeAllMetadata = false

    @State private var isSaving = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle

    private static let selectableFormats: [ImageFormat] = [.jpeg, .png, .tiff, .webp]
    private static let minCropSize: CGFloat = 10

    private var webpEncoder: WebPEncoder? { tools.webpEncoder }
    private var canEncodeWebP: Bool { webpEncoder != nil }
    private var exiftoolAvailable: Bool { tools.isAvailable(.exiftool) }

    private var totalAngle: Double {
        Double(quarterTurns * 90) + fineAngle
    }

    private var fullSize: CGSize? {
        guard let sourceImage else { return nil }
        return CGSize(width: sourceImage.width, height: sourceImage.height)
    }

    /// The pixel space the crop rect and its numeric fields live in — the
    /// image's size *after* the current rotation, not before.
    private var rotatedFullSize: CGSize {
        guard let fullSize else { return .zero }
        return ImageEditor.rotatedSize(of: fullSize, degrees: totalAngle)
    }

    /// The format this file's own extension resolves to, if MIKE can write
    /// it at all.
    private var sourceFormat: ImageFormat? {
        guard let sourceFile else { return nil }
        return ImageFormat.allCases.first { $0.fileExtension == sourceFile.pathExtension.lowercased() }
    }

    /// What "Keep original format" actually resolves to. HEIC/HEIF can never
    /// be a target, so a HEIC/HEIF source falls back to JPEG — shown to the
    /// user rather than done silently, see `keepOriginalCaption`.
    private var effectiveFormat: ImageFormat {
        if let explicitFormat { return explicitFormat }
        if let sourceFormat, !sourceFormat.isReadOnly { return sourceFormat }
        return .jpeg
    }

    private var keepOriginalFallsBack: Bool {
        explicitFormat == nil && (sourceFormat?.isReadOnly ?? false)
    }

    private var canSave: Bool {
        guard sourceImage != nil, !isSaving else { return false }
        return !(effectiveFormat.requiresExternalEncoder && !canEncodeWebP)
    }

    var body: some View {
        // Wider than the other sections on purpose: the canvas needs room.
        HStack(alignment: .top, spacing: 0) {
            canvasArea
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))

            Divider()

            ScrollView {
                controls
                    .padding(20)
            }
            .frame(width: 320)
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasArea: some View {
        if let previewBase {
            CropCanvas(
                previewImage: rotatedPreviewImage(previewBase),
                rotatedFullSize: rotatedFullSize,
                cropRect: $cropRect,
                minCropSize: Self.minCropSize,
                isEnabled: !isSaving
            )
            .onChange(of: cropRect) { _ in syncCropFields() }
            .padding(20)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "crop")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Open an image to start editing.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
                    .padding(10)
            )
        }
    }

    private func rotatedPreviewImage(_ base: CGImage) -> NSImage {
        let rotated = (try? ImageEditor.rotate(base, degrees: totalAngle)) ?? base
        return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Quick Edit",
                subtitle: "Straighten, crop, convert format and strip metadata, in one pass."
            )

            FileRow(
                label: "Image file",
                file: sourceFile,
                isEnabled: !isSaving,
                onChoose: chooseFile,
                onClear: clear
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

            if sourceImage != nil {
                straightenSection
                Divider()
                cropSection
                Divider()
                outputSection
                Divider()
                metadataSection
                Divider()
                saveSection
            }
        }
    }

    @ViewBuilder
    private var straightenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Straighten")
                .font(.headline)

            HStack(spacing: 8) {
                Slider(value: $fineAngle, in: -45...45, step: 0.1)
                    .onChange(of: fineAngle) { newValue in
                        fineAngleText = String(format: "%.1f", newValue)
                        resetCropToFullCanvas()
                    }
                TextField(text: $fineAngleText) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .onSubmit {
                        if let value = Double(fineAngleText) {
                            fineAngle = min(max(value, -45), 45)
                        }
                        fineAngleText = String(format: "%.1f", fineAngle)
                    }
                Text(verbatim: "°")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Rotate 90°") {
                    quarterTurns = (quarterTurns + 1) % 4
                    resetCropToFullCanvas()
                }
                Button("Reset") {
                    quarterTurns = 0
                    fineAngle = 0
                    fineAngleText = "0.0"
                    resetCropToFullCanvas()
                }
            }
        }
        .disabled(isSaving)
    }

    @ViewBuilder
    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Crop")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    cropField("X", text: $cropXText)
                    cropField("Y", text: $cropYText)
                }
                GridRow {
                    cropField("W", text: $cropWidthText)
                    cropField("H", text: $cropHeightText)
                }
            }

            Button("Reset Crop") { resetCropToFullCanvas() }
        }
        .disabled(isSaving)
    }

    @ViewBuilder
    private func cropField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 14)
            TextField(text: text) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .onSubmit { applyCropFieldsFromText() }
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Format")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                formatMenu
                if keepOriginalFallsBack {
                    Text("Keep original format (→ \(effectiveFormat.rawValue))", comment: "Placeholder is an untranslated format name")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if effectiveFormat == .webp, let reason = tools.webpUnavailableReason {
                    HStack(spacing: 4) {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Setup", action: onOpenTools)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            if effectiveFormat == .jpeg {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Quality")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: "\(Int(jpegQuality))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $jpegQuality, in: 1...100, step: 1)
                }
            }
        }
        .disabled(isSaving)
    }

    @ViewBuilder
    private var formatMenu: some View {
        Menu {
            Button {
                explicitFormat = nil
            } label: {
                if explicitFormat == nil {
                    Label("Keep original format", systemImage: "checkmark")
                } else {
                    Text("Keep original format")
                }
            }
            Divider()
            ForEach(Self.selectableFormats) { candidate in
                Button {
                    explicitFormat = candidate
                } label: {
                    if explicitFormat == candidate {
                        Label(candidate.rawValue, systemImage: "checkmark")
                    } else {
                        Text(candidate.rawValue)
                    }
                }
                .disabled(candidate.requiresExternalEncoder && !canEncodeWebP)
            }
        } label: {
            Text(explicitFormat == nil ? String(localized: "Keep original format") : explicitFormat!.rawValue)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)

            Toggle("Remove GPS data", isOn: $removeGPS)
                .disabled(!exiftoolAvailable || removeAllMetadata)
            Toggle("Remove all metadata", isOn: $removeAllMetadata)
                .disabled(!exiftoolAvailable)

            if !exiftoolAvailable {
                HStack(spacing: 4) {
                    Text("Needs exiftool to remove metadata. Saving without removal still works.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Setup", action: onOpenTools)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .disabled(isSaving)
    }

    @ViewBuilder
    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Save…") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                StatusLine(text: status, kind: statusKind)
            }
            Text("The original file is never changed — Save always writes a new file.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Loading

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = QuickEditView.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        load(chosen)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isSaving, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url, QuickEditView.acceptedExtensions.contains(url.pathExtension.lowercased())
            else { return }
            DispatchQueue.main.async { load(url) }
        }
        return true
    }

    static let acceptedExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "webp", "bmp"]

    private func load(_ url: URL) {
        guard let image = try? ImageConverter.load(from: url) else {
            status = String(localized: "The image could not be read.")
            statusKind = .failure
            return
        }
        sourceFile = url
        sourceImage = image
        sourceMetadata = ImageConverter.metadata(from: url)
        previewBase = ImageEditor.previewBase(of: image)
        explicitFormat = nil
        quarterTurns = 0
        fineAngle = 0
        fineAngleText = "0.0"
        status = ""
        statusKind = .idle
        resetCropToFullCanvas()
    }

    private func clear() {
        sourceFile = nil
        sourceImage = nil
        sourceMetadata = nil
        previewBase = nil
        cropRect = .zero
        status = ""
        statusKind = .idle
    }

    // MARK: - Crop field sync

    private func resetCropToFullCanvas() {
        cropRect = CGRect(origin: .zero, size: rotatedFullSize)
        syncCropFields()
    }

    private func syncCropFields() {
        cropXText = String(Int(cropRect.origin.x.rounded()))
        cropYText = String(Int(cropRect.origin.y.rounded()))
        cropWidthText = String(Int(cropRect.width.rounded()))
        cropHeightText = String(Int(cropRect.height.rounded()))
    }

    /// Builds a candidate rect from the four text fields (falling back to the
    /// current value for anything unparsable) and clamps it — out-of-range
    /// entries are corrected, not rejected, then the fields are rewritten to
    /// show what was actually applied.
    private func applyCropFieldsFromText() {
        let x = Double(cropXText) ?? cropRect.origin.x
        let y = Double(cropYText) ?? cropRect.origin.y
        let width = Double(cropWidthText) ?? cropRect.width
        let height = Double(cropHeightText) ?? cropRect.height
        let candidate = CGRect(x: x, y: y, width: width, height: height)
        cropRect = CropCanvas.clamp(candidate, to: rotatedFullSize, minSize: Self.minCropSize)
        syncCropFields()
    }

    // MARK: - Save

    private func save() {
        guard canSave, let sourceImage, let sourceFile else { return }

        let angle = totalAngle
        let rect = cropRect
        let format = effectiveFormat
        let encoder = webpEncoder
        let quality = jpegQuality / 100
        let metadata = sourceMetadata
        let stripAll = removeAllMetadata
        let stripGPS = removeGPS
        let exiftool = tools.status(for: .exiftool).url

        let panel = NSSavePanel()
        let stem = sourceFile.deletingPathExtension().lastPathComponent
        let sourceDirectory = sourceFile.deletingLastPathComponent()
        // Suggests a non-colliding name up front — the panel's own native
        // overwrite confirmation still applies if the user types an existing
        // name anyway.
        let suggested = ImageConverter.uniqueURL(directory: sourceDirectory, stem: stem, extension: format.fileExtension)
        panel.directoryURL = sourceDirectory
        panel.nameFieldStringValue = suggested.lastPathComponent
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.prompt = String(localized: "Save", comment: "Confirm button in the save dialog")
        guard panel.runModal() == .OK, let target = panel.url else { return }

        isSaving = true
        statusKind = .working
        status = String(localized: "Saving…")

        Task {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let processed = try ImageEditor.process(sourceImage, degrees: angle, cropRect: rect)
                            try ImageConverter.write(image: processed, to: target, format: format, webpEncoder: encoder, quality: quality, metadata: metadata)

                            if let exiftool {
                                if stripAll {
                                    _ = try MetadataWriter.removeAll(from: target, exiftool: exiftool, skipBackup: true)
                                } else if stripGPS {
                                    _ = try MetadataWriter.removeGPS(from: target, exiftool: exiftool, skipBackup: true)
                                }
                            }
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                status = String(
                    localized: "Saved: \(target.lastPathComponent)",
                    comment: "Placeholder is the written file name"
                )
                statusKind = .success
            } catch {
                status = error.localizedDescription
                statusKind = .failure
            }
            isSaving = false
        }
    }
}

// MARK: - Crop canvas

private enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// The interactive canvas: shows the rotated preview, dims everything outside
/// the crop frame, and lets the frame be resized (eight handles) or moved
/// (drag inside). `cropRect` is always in full-resolution, post-rotation
/// coordinates — this view only ever converts to/from display points for
/// drawing and gesture math, never stores anything in display units.
private struct CropCanvas: View {
    let previewImage: NSImage
    let rotatedFullSize: CGSize
    @Binding var cropRect: CGRect
    let minCropSize: CGFloat
    let isEnabled: Bool

    @State private var dragStartRect: CGRect?

    private let handleDiameter: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let scale = displayScale(for: geo.size)
            let displaySize = CGSize(width: rotatedFullSize.width * scale, height: rotatedFullSize.height * scale)
            let origin = CGPoint(x: (geo.size.width - displaySize.width) / 2, y: (geo.size.height - displaySize.height) / 2)
            let displayRect = CGRect(
                x: origin.x + cropRect.origin.x * scale,
                y: origin.y + cropRect.origin.y * scale,
                width: cropRect.width * scale,
                height: cropRect.height * scale
            )

            ZStack(alignment: .topLeading) {
                Image(nsImage: previewImage)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .position(x: origin.x + displaySize.width / 2, y: origin.y + displaySize.height / 2)

                // Even-odd fill: the outer rect minus the crop rect, dimmed —
                // darkens everything outside the frame, leaves the inside clear.
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
                        let position = handlePosition(handle, in: displayRect)
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
        guard rotatedFullSize.width > 0, rotatedFullSize.height > 0, size.width > 0, size.height > 0 else { return 1 }
        return min(size.width / rotatedFullSize.width, size.height / rotatedFullSize.height)
    }

    private func handlePosition(_ handle: CropHandle, in rect: CGRect) -> CGPoint {
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

    private func dragGesture(for handle: CropHandle, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = cropRect }
                guard let start = dragStartRect else { return }
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                cropRect = Self.applyHandleDrag(handle, delta: delta, start: start, bounds: rotatedFullSize, minSize: minCropSize)
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
                cropRect = Self.clamp(rect, to: rotatedFullSize, minSize: minCropSize)
            }
            .onEnded { _ in dragStartRect = nil }
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
    /// the whole frame and for numeric-field edits.
    static func clamp(_ rect: CGRect, to bounds: CGSize, minSize: CGFloat) -> CGRect {
        var result = rect
        result.size.width = min(max(result.size.width, minSize), bounds.width)
        result.size.height = min(max(result.size.height, minSize), bounds.height)
        result.origin.x = min(max(result.origin.x, 0), bounds.width - result.size.width)
        result.origin.y = min(max(result.origin.y, 0), bounds.height - result.size.height)
        return result
    }
}
