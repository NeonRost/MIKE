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

/// Survives navigating away from and back to Quick Edit — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class QuickEditSession: ObservableObject {
    @Published var sourceFile: URL?
    @Published var sourceImage: CGImage?
    @Published var sourceMetadata: [CFString: Any]?
    @Published var previewBase: CGImage?

    // Rotation: a discrete quarter-turn count from the 90° button, composed
    // with the fine slider — see `totalAngle`.
    @Published var quarterTurns = 0
    @Published var fineAngle: Double = 0
    @Published var fineAngleText = "0.0"

    // Always in post-rotation, full-resolution pixel coordinates — the same
    // space the numeric fields show. Reset to the full canvas whenever the
    // rotation changes; see the plan note on why.
    @Published var cropRect: CGRect = .zero
    @Published var cropXText = "0"
    @Published var cropYText = "0"
    @Published var cropWidthText = "0"
    @Published var cropHeightText = "0"

    @Published var explicitFormat: ImageFormat?
    @Published var jpegQuality: Double = 100
    @Published var removeGPS = true
    @Published var removeAllMetadata = false

    @Published var isSaving = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    static let selectableFormats: [ImageFormat] = [.jpeg, .png, .tiff, .webp]
    static let minCropSize: CGFloat = 10
    static let acceptedExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "webp", "bmp"]

    var totalAngle: Double {
        Double(quarterTurns * 90) + fineAngle
    }

    private var fullSize: CGSize? {
        guard let sourceImage else { return nil }
        return CGSize(width: sourceImage.width, height: sourceImage.height)
    }

    /// The pixel space the crop rect and its numeric fields live in — the
    /// image's size *after* the current rotation, not before.
    var rotatedFullSize: CGSize {
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
    /// user rather than done silently, see `keepOriginalFallsBack`.
    var effectiveFormat: ImageFormat {
        if let explicitFormat { return explicitFormat }
        if let sourceFormat, !sourceFormat.isReadOnly { return sourceFormat }
        return .jpeg
    }

    var keepOriginalFallsBack: Bool {
        explicitFormat == nil && (sourceFormat?.isReadOnly ?? false)
    }

    func canSave(canEncodeWebP: Bool) -> Bool {
        guard sourceImage != nil, !isSaving else { return false }
        return !(effectiveFormat.requiresExternalEncoder && !canEncodeWebP)
    }

    // MARK: - Loading

    func load(_ url: URL) {
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

    func clear() {
        sourceFile = nil
        sourceImage = nil
        sourceMetadata = nil
        previewBase = nil
        cropRect = .zero
        explicitFormat = nil
        jpegQuality = 100
        removeGPS = true
        removeAllMetadata = false
        quarterTurns = 0
        fineAngle = 0
        fineAngleText = "0.0"
        status = ""
        statusKind = .idle
    }

    // MARK: - Crop field sync

    func resetCropToFullCanvas() {
        cropRect = CGRect(origin: .zero, size: rotatedFullSize)
        syncCropFields()
    }

    func syncCropFields() {
        cropXText = String(Int(cropRect.origin.x.rounded()))
        cropYText = String(Int(cropRect.origin.y.rounded()))
        cropWidthText = String(Int(cropRect.width.rounded()))
        cropHeightText = String(Int(cropRect.height.rounded()))
    }

    /// Builds a candidate rect from the four text fields (falling back to the
    /// current value for anything unparsable) and clamps it — out-of-range
    /// entries are corrected, not rejected, then the fields are rewritten to
    /// show what was actually applied.
    func applyCropFieldsFromText() {
        let x = Double(cropXText) ?? cropRect.origin.x
        let y = Double(cropYText) ?? cropRect.origin.y
        let width = Double(cropWidthText) ?? cropRect.width
        let height = Double(cropHeightText) ?? cropRect.height
        let candidate = CGRect(x: x, y: y, width: width, height: height)
        cropRect = CropGeometry.clamp(candidate, to: rotatedFullSize, minSize: Self.minCropSize)
        syncCropFields()
    }

    // MARK: - Save

    func save(webpEncoder: WebPEncoder?, exiftool: URL?, target: URL) {
        guard let sourceImage else { return }

        let angle = totalAngle
        let rect = cropRect
        let format = effectiveFormat
        let quality = jpegQuality / 100
        let metadata = sourceMetadata
        let stripAll = removeAllMetadata
        let stripGPS = removeGPS

        isSaving = true
        statusKind = .working
        status = String(localized: "Saving…")

        Task {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let processed = try ImageEditor.process(sourceImage, degrees: angle, cropRect: rect)
                            try ImageConverter.write(image: processed, to: target, format: format, webpEncoder: webpEncoder, quality: quality, metadata: metadata)

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

struct QuickEditView: View {
    let onOpenTools: () -> Void
    @ObservedObject var session: QuickEditSession

    @EnvironmentObject private var tools: ToolRegistry
    @State private var isDropTargeted = false

    private var webpEncoder: WebPEncoder? { tools.webpEncoder }
    private var canEncodeWebP: Bool { webpEncoder != nil }
    private var exiftoolAvailable: Bool { tools.isAvailable(.exiftool) }
    private var canSave: Bool { session.canSave(canEncodeWebP: canEncodeWebP) }
    private var canClear: Bool { session.sourceFile != nil }

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
        if let previewBase = session.previewBase {
            CropCanvas(
                previewImage: rotatedPreviewImage(previewBase),
                rotatedFullSize: session.rotatedFullSize,
                cropRect: $session.cropRect,
                minCropSize: QuickEditSession.minCropSize,
                isEnabled: !session.isSaving
            )
            .onChange(of: session.cropRect) { _ in session.syncCropFields() }
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
        let rotated = (try? ImageEditor.rotate(base, degrees: session.totalAngle)) ?? base
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
                file: session.sourceFile,
                isEnabled: !session.isSaving,
                onChoose: chooseFile,
                onClear: { session.clear() }
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

            if session.sourceImage != nil {
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
                Slider(value: $session.fineAngle, in: -45...45, step: 0.1)
                    .onChange(of: session.fineAngle) { newValue in
                        session.fineAngleText = String(format: "%.1f", newValue)
                        session.resetCropToFullCanvas()
                    }
                TextField(text: $session.fineAngleText) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .onSubmit {
                        if let value = Double(session.fineAngleText) {
                            session.fineAngle = min(max(value, -45), 45)
                        }
                        session.fineAngleText = String(format: "%.1f", session.fineAngle)
                    }
                Text(verbatim: "°")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Rotate 90°") {
                    session.quarterTurns = (session.quarterTurns + 1) % 4
                    session.resetCropToFullCanvas()
                }
                Button("Reset") {
                    session.quarterTurns = 0
                    session.fineAngle = 0
                    session.fineAngleText = "0.0"
                    session.resetCropToFullCanvas()
                }
            }
        }
        .disabled(session.isSaving)
    }

    @ViewBuilder
    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Crop")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    cropField("X", text: $session.cropXText)
                    cropField("Y", text: $session.cropYText)
                }
                GridRow {
                    cropField("W", text: $session.cropWidthText)
                    cropField("H", text: $session.cropHeightText)
                }
            }

            Button("Reset Crop") { session.resetCropToFullCanvas() }
        }
        .disabled(session.isSaving)
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
                .onSubmit { session.applyCropFieldsFromText() }
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
                if session.keepOriginalFallsBack {
                    Text("Keep original format (→ \(session.effectiveFormat.rawValue))", comment: "Placeholder is an untranslated format name")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if session.effectiveFormat == .webp, let reason = tools.webpUnavailableReason {
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

            if session.effectiveFormat == .jpeg {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Quality")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: "\(Int(session.jpegQuality))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $session.jpegQuality, in: 1...100, step: 1)
                }
            }
        }
        .disabled(session.isSaving)
    }

    @ViewBuilder
    private var formatMenu: some View {
        Menu {
            Button {
                session.explicitFormat = nil
            } label: {
                if session.explicitFormat == nil {
                    Label("Keep original format", systemImage: "checkmark")
                } else {
                    Text("Keep original format")
                }
            }
            Divider()
            ForEach(QuickEditSession.selectableFormats) { candidate in
                Button {
                    session.explicitFormat = candidate
                } label: {
                    if session.explicitFormat == candidate {
                        Label(candidate.rawValue, systemImage: "checkmark")
                    } else {
                        Text(candidate.rawValue)
                    }
                }
                .disabled(candidate.requiresExternalEncoder && !canEncodeWebP)
            }
        } label: {
            Text(session.explicitFormat == nil ? String(localized: "Keep original format") : session.explicitFormat!.rawValue)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)

            Toggle("Remove GPS data", isOn: $session.removeGPS)
                .disabled(!exiftoolAvailable || session.removeAllMetadata)
            Toggle("Remove all metadata", isOn: $session.removeAllMetadata)
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
        .disabled(session.isSaving)
    }

    @ViewBuilder
    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Save…") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                Button("Clear") { session.clear() }
                    .disabled(!canClear)
                StatusLine(text: session.status, kind: session.statusKind)
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
        panel.allowedContentTypes = QuickEditSession.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        session.load(chosen)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isSaving, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url, QuickEditSession.acceptedExtensions.contains(url.pathExtension.lowercased())
            else { return }
            DispatchQueue.main.async { session.load(url) }
        }
        return true
    }

    // MARK: - Save

    private func save() {
        guard canSave, let sourceFile = session.sourceFile else { return }

        let format = session.effectiveFormat
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

        session.save(webpEncoder: webpEncoder, exiftool: tools.status(for: .exiftool).url, target: target)
    }
}

// MARK: - Crop canvas

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
        guard rotatedFullSize.width > 0, rotatedFullSize.height > 0, size.width > 0, size.height > 0 else { return 1 }
        return min(size.width / rotatedFullSize.width, size.height / rotatedFullSize.height)
    }

    private func dragGesture(for handle: CropHandle, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = cropRect }
                guard let start = dragStartRect else { return }
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                cropRect = CropGeometry.applyHandleDrag(handle, delta: delta, start: start, bounds: rotatedFullSize, minSize: minCropSize)
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
                cropRect = CropGeometry.clamp(rect, to: rotatedFullSize, minSize: minCropSize)
            }
            .onEnded { _ in dragStartRect = nil }
    }
}
