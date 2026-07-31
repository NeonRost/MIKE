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
private enum ConvertMode: String, CaseIterable, Identifiable {
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

struct ConvertFormatView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry
    @StateObject private var directory = OutputDirectory(defaultsKey: "ImgConvertOutputDir")
    @StateObject private var batchDirectory = OutputDirectory(defaultsKey: "ImgConvertBatchOutputDir")

    @State private var mode = ConvertMode.single

    // MARK: Single file — unchanged from before batch mode existed.

    @State private var sourceFile: URL?
    @State private var urlText = ""
    @State private var format = ImageFormat.jpeg
    @State private var isRunning = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle

    // MARK: Batch

    @State private var batchFolder: URL?
    @State private var sourceFormat = ImageFormat.jpeg
    @State private var batchTargetFormat = ImageFormat.jpeg
    @State private var batchFiles: [URL] = []
    @State private var jpegQuality: Double = 100
    @State private var isBatchDropTargeted = false
    @State private var isBatchRunning = false
    @State private var batchCurrentIndex = 0
    @State private var batchStatus = ""
    @State private var batchStatusKind = StatusLine.Kind.idle
    @State private var batchTask: Task<Void, Never>?

    private var webpEncoder: WebPEncoder? { tools.webpEncoder }
    private var canEncodeWebP: Bool { webpEncoder != nil }

    /// The URL field wins when both are filled in.
    private var usesRemoteSource: Bool {
        !urlText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canConvert: Bool {
        guard !isRunning else { return false }
        guard usesRemoteSource || sourceFile != nil else { return false }
        return !(format.requiresExternalEncoder && !canEncodeWebP)
    }

    private var canConvertBatch: Bool {
        guard !isBatchRunning, !batchFiles.isEmpty else { return false }
        return !(batchTargetFormat.requiresExternalEncoder && !canEncodeWebP)
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

                Picker("Mode", selection: $mode) {
                    ForEach(ConvertMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(isRunning || isBatchRunning)

                switch mode {
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
                file: sourceFile,
                isEnabled: !isRunning,
                onChoose: chooseFile,
                onClear: { sourceFile = nil }
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("…or a direct link to the image")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://…/image.webp", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("Target format")
                    targetFormatMenu(selection: $format, isEnabled: !isRunning)
                }
                webpHint
            }

            OutputDirectoryRow(directory: directory, isEnabled: !isRunning)

            HStack(spacing: 12) {
                Button("Convert") { convert() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConvert)
                StatusLine(text: status, kind: statusKind)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        sourceFile = chosen
        // Picking a file clears the URL, so the active source is never
        // ambiguous.
        urlText = ""
        status = ""
        statusKind = .idle
    }

    private func convert() {
        guard canConvert else { return }

        let chosenFormat = format
        let target = directory.url
        let encoder = webpEncoder
        let remote = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let localFile = sourceFile

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
                                webpEncoder: encoder
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

    // MARK: - Batch

    @ViewBuilder
    private var batchContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            FolderRow(
                folder: batchFolder,
                detail: batchFolder == nil ? nil : batchCountText,
                isEnabled: !isBatchRunning,
                onChoose: chooseBatchFolder
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isBatchDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isBatchDropTargeted) { providers in
                handleFolderDrop(providers)
            }

            if batchFolder != nil {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source format")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(selection: $sourceFormat) {
                            ForEach(ImageFormat.allCases) { candidate in
                                Text(candidate.rawValue).tag(candidate)
                            }
                        } label: { EmptyView() }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .disabled(isBatchRunning)
                        .onChange(of: sourceFormat) { _ in rescanBatchFolder() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target format")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        targetFormatMenu(selection: $batchTargetFormat, isEnabled: !isBatchRunning)
                    }
                }

                webpHint

                if batchTargetFormat == .jpeg {
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
                    .frame(maxWidth: 280)
                    .disabled(isBatchRunning)
                }

                OutputDirectoryRow(directory: batchDirectory, isEnabled: !isBatchRunning)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Button("Convert") { convertBatch() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canConvertBatch)
                        if isBatchRunning {
                            Button("Cancel") { cancelBatch() }
                        }
                        StatusLine(text: batchStatus, kind: batchStatusKind)
                    }
                    if isBatchRunning {
                        ProgressView(value: Double(batchCurrentIndex), total: Double(max(batchFiles.count, 1)))
                            .frame(maxWidth: 260)
                    }
                }
            }
        }
    }

    private var batchCountText: String {
        String(
            localized: "\(batchFiles.count) \(batchFormatLabel) files found",
            comment: "Placeholder 2 is an untranslated format name such as HEIC"
        )
    }

    /// `sourceFormat.rawValue` arrives through a variable, not a string
    /// literal, so SwiftUI never treats it as a catalog key — the same reason
    /// the target-format menu below can pass format names straight through.
    private var batchFormatLabel: String { sourceFormat.rawValue }

    private func chooseBatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the folder picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        loadBatchFolder(chosen)
    }

    private func loadBatchFolder(_ folder: URL) {
        batchFolder = folder
        // Defaults to writing back into the source folder, as specified —
        // still freely redirectable via the row's own Choose… button.
        batchDirectory.set(folder)
        batchStatus = ""
        batchStatusKind = .idle
        rescanBatchFolder()
    }

    /// Re-filters the already-chosen folder for the current source format.
    /// Runs on every source-format change so the count updates live without
    /// requiring the folder to be re-picked.
    private func rescanBatchFolder() {
        guard let batchFolder else { batchFiles = []; return }
        batchFiles = ImageConverter.candidates(in: batchFolder, format: sourceFormat)
    }

    private func handleFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isBatchRunning, let provider = providers.first else { return false }
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
            DispatchQueue.main.async { loadBatchFolder(url) }
        }
        return true
    }

    private func convertBatch() {
        guard canConvertBatch else { return }

        let files = batchFiles
        let targetFormatSnapshot = batchTargetFormat
        let encoder = webpEncoder
        let quality = jpegQuality / 100
        let target = batchDirectory.url

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
                                webpEncoder: encoder,
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

    private func cancelBatch() {
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
