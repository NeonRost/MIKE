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
    @Published var isLoading = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    /// The rotated preview for the current angle. Rotating the preview is a
    /// full redraw of a 1400px image, and the canvas asks for it on every
    /// body evaluation — every tick of a crop drag included — so it is kept
    /// until the angle or the image actually changes.
    private var previewCache: (angle: Double, image: NSImage)?
    /// Counts loads, so a slow decode of a file the user has since replaced
    /// does not land on top of the newer one.
    private var loadGeneration = 0

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
        return ImageFormat.forExtension(sourceFile.pathExtension)
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

    /// Decodes off the main thread: a large HEIC or TIFF takes long enough to
    /// read and scale down that doing it inline froze the window for the
    /// duration.
    func load(_ url: URL) {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        status = ""
        statusKind = .idle

        Task {
            let loaded: (image: CGImage, metadata: [CFString: Any]?, preview: CGImage)? =
                await Background.run {
                    guard let image = try? ImageConverter.load(from: url) else {
                        return nil
                    }
                    let metadata = ImageConverter.metadata(from: url)
                    let preview = ImageEditor.previewBase(of: image)
                    return (image, metadata, preview)
                }

            guard generation == loadGeneration else { return }
            isLoading = false
            guard let loaded else {
                status = String(localized: "The image could not be read.")
                statusKind = .failure
                return
            }
            sourceFile = url
            sourceImage = loaded.image
            sourceMetadata = loaded.metadata
            previewBase = loaded.preview
            previewCache = nil
            explicitFormat = nil
            quarterTurns = 0
            fineAngle = 0
            fineAngleText = "0.0"
            resetCropToFullCanvas()
        }
    }

    func clear() {
        loadGeneration += 1
        isLoading = false
        sourceFile = nil
        sourceImage = nil
        sourceMetadata = nil
        previewBase = nil
        previewCache = nil
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

    func rotatedPreview() -> NSImage? {
        guard let previewBase else { return nil }
        if let previewCache, previewCache.angle == totalAngle { return previewCache.image }
        let rotated = (try? ImageEditor.rotate(previewBase, degrees: totalAngle)) ?? previewBase
        let image = NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
        previewCache = (totalAngle, image)
        return image
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

    func applyAngleText() {
        if let value = Double(fineAngleText.replacingOccurrences(of: ",", with: ".")), value.isFinite {
            let clamped = min(max(value, -45), 45)
            if clamped != fineAngle {
                fineAngle = clamped
                resetCropToFullCanvas()
            }
        }
        fineAngleText = String(format: "%.1f", fineAngle)
    }

    /// Takes over whatever is typed into the angle and crop fields. They
    /// commit on Return or on losing focus, and pressing Save guarantees
    /// neither — the picture saved has to be the one the fields describe.
    /// A changed angle resets the crop (as it does everywhere else), so the
    /// crop fields are only read when the angle stood.
    func commitTextFields() {
        let before = fineAngle
        applyAngleText()
        if fineAngle == before {
            applyCropFieldsFromText()
        }
    }

    // MARK: - Save

    func save(webpEncoder: WebPEncoder?, target: URL) {
        guard let sourceImage else { return }

        let angle = totalAngle
        let rect = cropRect
        let format = effectiveFormat
        let quality = jpegQuality / 100

        // Stripping happens here, by not writing what should not be there —
        // no second pass over the finished file. A `CGImage` carries no
        // metadata of its own, so the output holds exactly what this
        // dictionary holds: leave the GPS block out and there is no location;
        // pass nothing and there is no metadata. This used to go through
        // exiftool afterwards, which made the most privacy-relevant switch in
        // the section depend on an optional tool, and left a file with its
        // location intact on disk whenever that second step failed.
        var metadata = sourceMetadata
        if removeAllMetadata {
            metadata = nil
        } else if removeGPS {
            metadata?[kCGImagePropertyGPSDictionary] = nil
        }
        let outputMetadata = metadata

        isSaving = true
        statusKind = .working
        status = String(localized: "Saving…")

        Task {
            do {
                try await Background.attempt {
                    let processed = try ImageEditor.process(sourceImage, degrees: angle, cropRect: rect)
                    try ImageConverter.write(image: processed, to: target, format: format, webpEncoder: webpEncoder, quality: quality, metadata: outputMetadata)
                }.get()
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
    private var canSave: Bool { session.canSave(canEncodeWebP: canEncodeWebP) }

    var body: some View {
        // The canvas wants room, but a hard minimum wider than the window can
        // offer only pushes the content out of its frame — a wider sidebar
        // (larger icon size, longer translated labels) eats that margin. So the
        // inspector gives way first and the minimum stays inside what the
        // window guarantees.
        HStack(alignment: .top, spacing: 0) {
            canvasArea
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))

            Divider()

            ScrollView {
                controls
                    .padding(20)
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 320)
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasArea: some View {
        if let previewImage = session.rotatedPreview() {
            CropCanvas(
                previewImage: previewImage,
                rotatedFullSize: session.rotatedFullSize,
                cropRect: $session.cropRect,
                minCropSize: QuickEditSession.minCropSize,
                isEnabled: !session.isSaving
            )
            .onChange(of: session.cropRect) { _ in session.syncCropFields() }
            .padding(20)
        } else if session.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                isEnabled: !session.isSaving && !session.isLoading,
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
                    .onSubmit { session.applyAngleText() }
                    .commitOnBlur { session.applyAngleText() }
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
                .commitOnBlur { session.applyCropFieldsFromText() }
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
                .disabled(session.removeAllMetadata)
            Toggle("Remove all metadata", isOn: $session.removeAllMetadata)
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
        guard !session.isSaving, !session.isLoading, !providers.isEmpty else { return false }
        FileDrop.urls(from: providers) { urls in
            guard let url = urls.first(where: {
                QuickEditSession.acceptedExtensions.contains($0.pathExtension.lowercased())
            }) else { return }
            session.load(url)
        }
        return true
    }

    // MARK: - Save

    private func save() {
        guard canSave, let sourceFile = session.sourceFile else { return }
        session.commitTextFields()

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

        session.save(webpEncoder: webpEncoder, target: target)
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

    var body: some View {
        ZStack {
            // Aspect-fitted and centred — the same placement `CropOverlay`
            // assumes for the picture it frames.
            Image(nsImage: previewImage)
                .resizable()
                .aspectRatio(rotatedFullSize, contentMode: .fit)
            CropOverlay(
                displaySize: rotatedFullSize,
                cropRect: $cropRect,
                minCropSize: minCropSize,
                isEnabled: isEnabled
            )
        }
    }
}
