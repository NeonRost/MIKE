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

/// Single File vs. Batch, shown as a segmented switch. Distinct from
/// `CombineSource` (Folder/Files in Combine Images) — that switch picks where
/// several files come from; this one picks whether there is one file at all.
enum ConvertMode: String, CaseIterable, Identifiable {
    case single = "Single File"
    case batch = "Batch"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .single: return "Single File"
        case .batch: return "Batch"
        }
    }
}

/// Survives navigating away from and back to Convert Format — see
/// `ArticleExtractionSession` for why this is needed at all. The two
/// `OutputDirectory` instances stay in the view: they are already
/// `UserDefaults`-backed and persist on their own.
@MainActor
final class ConvertFormatSession: ObservableObject {
    @Published var mode = ConvertMode.single

    // MARK: Single file

    @Published var sourceFile: URL?
    @Published var urlText = ""
    @Published var pastedImageData: Data?
    @Published var pastedImageSize: CGSize?
    @Published var format = ImageFormat.jpeg
    @Published var isRunning = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    // MARK: Batch

    @Published var batchFolder: URL?
    @Published var sourceFormat = ImageFormat.jpeg
    @Published var batchTargetFormat = ImageFormat.jpeg
    @Published var batchFiles: [URL] = []
    @Published var jpegQuality: Double = 100
    @Published var isBatchRunning = false
    @Published var batchCurrentIndex = 0
    @Published var batchStatus = ""
    @Published var batchStatusKind = StatusLine.Kind.idle
    private var batchTask: Task<Void, Never>?

    /// The URL field wins if it happens to be filled in alongside a chosen
    /// file or a pasted image — in practice this never actually happens,
    /// since choosing a file or pasting an image both clear it, and typing a
    /// URL doesn't clear them back, only out-ranks them here.
    var usesRemoteSource: Bool {
        !urlText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func canConvert(canEncodeWebP: Bool) -> Bool {
        guard !isRunning else { return false }
        guard usesRemoteSource || sourceFile != nil || pastedImageData != nil else { return false }
        return !(format.requiresExternalEncoder && !canEncodeWebP)
    }

    func canConvertBatch(canEncodeWebP: Bool) -> Bool {
        guard !isBatchRunning, !batchFiles.isEmpty else { return false }
        return !(batchTargetFormat.requiresExternalEncoder && !canEncodeWebP)
    }

    /// Resets both modes at once rather than just the active one — a single,
    /// predictable "start over" regardless of which segment is selected.
    func clear() {
        guard !isRunning, !isBatchRunning else { return }
        sourceFile = nil
        urlText = ""
        pastedImageData = nil
        pastedImageSize = nil
        format = .jpeg
        status = ""
        statusKind = .idle

        batchFolder = nil
        sourceFormat = .jpeg
        batchTargetFormat = .jpeg
        batchFiles = []
        jpegQuality = 100
        batchStatus = ""
        batchStatusKind = .idle
    }

    // MARK: - Single file actions

    func chooseFile(directory: OutputDirectory) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        sourceFile = chosen
        // Picking a file makes it the active source, so the other two are
        // cleared — the same rule pasting and typing a URL follow.
        urlText = ""
        clearPastedImage()
        status = ""
        statusKind = .idle
    }

    func pasteImageFromClipboard() {
        guard !isRunning else { return }
        guard let data = ClipboardImage.data(), let image = try? ImageConverter.load(from: data) else {
            status = String(localized: "No image in the clipboard.")
            statusKind = .idle
            return
        }

        pastedImageData = data
        pastedImageSize = CGSize(width: image.width, height: image.height)
        // Pasting makes it the active source, so the other two are cleared —
        // the same rule chooseFile() already follows for the URL.
        sourceFile = nil
        urlText = ""
        status = ""
        statusKind = .idle
    }

    func clearPastedImage() {
        pastedImageData = nil
        pastedImageSize = nil
    }

    func convert(webpEncoder: WebPEncoder?, canEncodeWebP: Bool, directory: OutputDirectory) {
        guard canConvert(canEncodeWebP: canEncodeWebP) else { return }

        let chosenFormat = format
        let target = directory.url
        let remote = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let localFile = sourceFile
        let pastedData = pastedImageData

        if usesRemoteSource, !WebURL.isValid(remote) {
            status = String(localized: "That is not a valid URL.")
            statusKind = .failure
            return
        }

        isRunning = true
        statusKind = .working
        status = String(localized: "Converting…")

        Task {
            do {
                let image: CGImage
                let stem: String

                if usesRemoteSource, let remoteURL = URL(string: remote) {
                    let data = try await ImageConverter.download(from: remoteURL)
                    image = try ImageConverter.load(from: data)
                    stem = ImageConverter.stem(fromRemote: remoteURL)
                } else if let localFile {
                    image = try ImageConverter.load(from: localFile)
                    stem = localFile.deletingPathExtension().lastPathComponent
                } else if let pastedData {
                    image = try ImageConverter.load(from: pastedData)
                    stem = "pasted-image"
                } else {
                    throw ImageConversionError.cannotRead
                }

                let output = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let result = try ImageConverter.convert(
                                image: image,
                                stem: stem,
                                to: chosenFormat,
                                in: target,
                                webpEncoder: webpEncoder
                            )
                            continuation.resume(returning: result)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

                status = String(localized: "Finished: \(output.lastPathComponent)", comment: "Placeholder is the written file name")
                statusKind = .success
            } catch {
                status = error.localizedDescription
                statusKind = .failure
            }
            isRunning = false
        }
    }

    // MARK: - Batch actions

    var batchCountText: String {
        String(
            localized: "\(batchFiles.count) \(batchFormatLabel) files found",
            comment: "Placeholder 2 is an untranslated format name such as HEIC"
        )
    }

    /// `sourceFormat.rawValue` arrives through a variable, not a string
    /// literal, so SwiftUI never treats it as a catalog key — the same reason
    /// the target-format menu can pass format names straight through.
    var batchFormatLabel: String { sourceFormat.rawValue }

    func chooseBatchFolder(directory: OutputDirectory) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the folder picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        loadBatchFolder(chosen, directory: directory)
    }

    func loadBatchFolder(_ folder: URL, directory: OutputDirectory) {
        batchFolder = folder
        // Defaults to writing back into the source folder, as specified —
        // still freely redirectable via the row's own Choose… button.
        directory.set(folder)
        batchStatus = ""
        batchStatusKind = .idle
        rescanBatchFolder()
    }

    /// Re-filters the already-chosen folder for the current source format.
    /// Runs on every source-format change so the count updates live without
    /// requiring the folder to be re-picked.
    func rescanBatchFolder() {
        guard let batchFolder else { batchFiles = []; return }
        batchFiles = ImageConverter.candidates(in: batchFolder, format: sourceFormat)
    }

    func convertBatch(webpEncoder: WebPEncoder?, canEncodeWebP: Bool, directory: OutputDirectory) {
        guard canConvertBatch(canEncodeWebP: canEncodeWebP) else { return }

        let files = batchFiles
        let targetFormatSnapshot = batchTargetFormat
        let quality = jpegQuality / 100
        let target = directory.url

        isBatchRunning = true
        batchCurrentIndex = 0
        batchStatusKind = .working
        batchStatus = String(localized: "Converting…")

        batchTask = Task {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

            var converted = 0
            var failed: [String] = []

            for (index, file) in files.enumerated() {
                if Task.isCancelled { break }
                batchCurrentIndex = index + 1
                batchStatus = String(
                    localized: "Converting \(batchCurrentIndex) of \(files.count)…",
                    comment: "Progress while converting a batch of images"
                )

                let outcome: Result<URL, Error> = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let image = try ImageConverter.load(from: file)
                            let stem = file.deletingPathExtension().lastPathComponent
                            let output = try ImageConverter.convert(
                                image: image,
                                stem: stem,
                                to: targetFormatSnapshot,
                                in: target,
                                webpEncoder: webpEncoder,
                                quality: quality
                            )
                            continuation.resume(returning: .success(output))
                        } catch {
                            continuation.resume(returning: .failure(error))
                        }
                    }
                }

                switch outcome {
                case .success: converted += 1
                case .failure: failed.append(file.lastPathComponent)
                }
            }

            let cancelled = Task.isCancelled
            isBatchRunning = false
            finishBatch(converted: converted, failed: failed, cancelled: cancelled)
        }
    }

    func cancelBatch() {
        batchTask?.cancel()
    }

    private func finishBatch(converted: Int, failed: [String], cancelled: Bool) {
        if cancelled {
            batchStatus = String(
                localized: "Cancelled after \(converted) files. What was already converted is kept.",
                comment: "Placeholder is a count of files"
            )
            batchStatusKind = .idle
            return
        }

        var message = String(
            localized: "Done. \(converted) files converted.",
            comment: "Placeholder is a count of files"
        )
        if !failed.isEmpty {
            let list = ListFormatter.localizedString(byJoining: failed)
            message += " " + String(
                localized: "Failed: \(list)",
                comment: "Placeholder is a comma-separated list of file names"
            )
        }
        batchStatus = message
        batchStatusKind = converted > 0 ? .success : .failure
    }
}

struct ConvertFormatView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry
    @ObservedObject var session: ConvertFormatSession
    @StateObject private var directory = OutputDirectory(defaultsKey: "ImgConvertOutputDir")
    @StateObject private var batchDirectory = OutputDirectory(defaultsKey: "ImgConvertBatchOutputDir")

    @State private var isBatchDropTargeted = false

    private var webpEncoder: WebPEncoder? { tools.webpEncoder }
    private var canEncodeWebP: Bool { webpEncoder != nil }

    private var canClear: Bool {
        !session.isRunning && !session.isBatchRunning
            && !(session.sourceFile == nil && session.urlText.isEmpty && session.pastedImageData == nil && session.batchFolder == nil)
    }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Convert Format",
                    subtitle: "Converts images to another format, as losslessly as each format allows."
                )

                Picker("Mode", selection: $session.mode) {
                    ForEach(ConvertMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(session.isRunning || session.isBatchRunning)

                switch session.mode {
                case .single: singleFileContent
                case .batch: batchContent
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Single file (unchanged behaviour)

    @ViewBuilder
    private var singleFileContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            FileRow(
                label: "Image file",
                file: session.sourceFile,
                isEnabled: !session.isRunning,
                onChoose: { session.chooseFile(directory: directory) },
                onClear: { session.sourceFile = nil }
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("…or a direct link to the image")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://…/image.webp", text: $session.urlText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("…or an image from the clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let pastedImageSize = session.pastedImageSize {
                        Text(
                            "Image from clipboard (\(Int(pastedImageSize.width))×\(Int(pastedImageSize.height)))",
                            comment: "Placeholders are pixel width and height"
                        )
                    } else {
                        Text("No image pasted")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if session.pastedImageData != nil {
                        Button("Clear") { session.clearPastedImage() }
                            .disabled(session.isRunning)
                    }
                    Button("Paste") { session.pasteImageFromClipboard() }
                        .disabled(session.isRunning)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("Target format")
                    targetFormatMenu(selection: $session.format, isEnabled: !session.isRunning)
                }
                webpHint
            }

            OutputDirectoryRow(directory: directory, isEnabled: !session.isRunning)

            HStack(spacing: 12) {
                Button("Convert") { session.convert(webpEncoder: webpEncoder, canEncodeWebP: canEncodeWebP, directory: directory) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canConvert(canEncodeWebP: canEncodeWebP))
                Button("Clear") { session.clear() }
                    .disabled(!canClear)
                StatusLine(text: session.status, kind: session.statusKind)
            }
        }
    }

    // MARK: - Batch

    @ViewBuilder
    private var batchContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            FolderRow(
                folder: session.batchFolder,
                detail: session.batchFolder == nil ? nil : session.batchCountText,
                isEnabled: !session.isBatchRunning,
                onChoose: { session.chooseBatchFolder(directory: batchDirectory) }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isBatchDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isBatchDropTargeted) { providers in
                handleFolderDrop(providers)
            }

            if session.batchFolder != nil {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source format")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(selection: $session.sourceFormat) {
                            ForEach(ImageFormat.allCases) { candidate in
                                Text(candidate.rawValue).tag(candidate)
                            }
                        } label: { EmptyView() }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .disabled(session.isBatchRunning)
                        .onChange(of: session.sourceFormat) { _ in session.rescanBatchFolder() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target format")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        targetFormatMenu(selection: $session.batchTargetFormat, isEnabled: !session.isBatchRunning)
                    }
                }

                webpHint

                if session.batchTargetFormat == .jpeg {
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
                    .frame(maxWidth: 280)
                    .disabled(session.isBatchRunning)
                }

                OutputDirectoryRow(directory: batchDirectory, isEnabled: !session.isBatchRunning)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Button("Convert") { session.convertBatch(webpEncoder: webpEncoder, canEncodeWebP: canEncodeWebP, directory: batchDirectory) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!session.canConvertBatch(canEncodeWebP: canEncodeWebP))
                        if session.isBatchRunning {
                            Button("Cancel") { session.cancelBatch() }
                        }
                        Button("Clear") { session.clear() }
                            .disabled(!canClear)
                        StatusLine(text: session.batchStatus, kind: session.batchStatusKind)
                    }
                    if session.isBatchRunning {
                        ProgressView(value: Double(session.batchCurrentIndex), total: Double(max(session.batchFiles.count, 1)))
                            .frame(maxWidth: 260)
                    }
                }
            }
        }
    }

    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isBatchRunning, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return }
            DispatchQueue.main.async { session.loadBatchFolder(url, directory: batchDirectory) }
        }
        return true
    }

    // MARK: - Shared target-format picker

    /// A plain `Picker` cannot disable a single entry, so this is a `Menu`:
    /// WEBP stays visible but unselectable without cwebp. Shared by both
    /// modes; only the candidate list differs from a plain format list in
    /// that it always excludes HEIC/HEIF via `ImageFormat.writableCases`.
    @ViewBuilder
    private func targetFormatMenu(selection: Binding<ImageFormat>, isEnabled: Bool) -> some View {
        Menu {
            ForEach(ImageFormat.writableCases) { candidate in
                Button {
                    selection.wrappedValue = candidate
                } label: {
                    if candidate == selection.wrappedValue {
                        Label(candidate.rawValue, systemImage: "checkmark")
                    } else {
                        Text(candidate.rawValue)
                    }
                }
                .disabled(candidate.requiresExternalEncoder && !canEncodeWebP)
            }
        } label: {
            Text(selection.wrappedValue.rawValue)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var webpHint: some View {
        if let reason = tools.webpUnavailableReason {
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
}
