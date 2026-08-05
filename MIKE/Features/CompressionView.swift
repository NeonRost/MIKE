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

enum CompressionMode: String, CaseIterable, Identifiable {
    case unpack = "Unpack"
    case pack = "Pack"
    case convert = "Convert"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .unpack: return "Unpack"
        case .pack: return "Pack"
        case .convert: return "Convert"
        }
    }
}

/// Survives navigating away from and back to Compression — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class CompressionSession: ObservableObject {
    @Published var mode = CompressionMode.unpack

    // MARK: Unpack

    @Published var unpackSource: URL?
    @Published var unpackFormat: ArchiveFormat?
    @Published var isUnpacking = false
    @Published var unpackProgress: Double = 0
    @Published var unpackStatus = ""
    @Published var unpackStatusKind = StatusLine.Kind.idle
    private var unpackTask: Task<Void, Never>?

    // MARK: Pack

    /// Same convention as `ImageStacker`/`VideoConcatenator`'s own
    /// `outputStem`: a fixed default name rather than one derived from the
    /// first picked item.
    static let defaultArchiveName = "compressed"

    @Published var packItems: [URL] = []
    @Published var packFormat = ArchiveFormat.zip
    @Published var packArchiveName = CompressionSession.defaultArchiveName
    @Published var isPacking = false
    @Published var packProgress: Double = 0
    @Published var packStatus = ""
    @Published var packStatusKind = StatusLine.Kind.idle
    private var packTask: Task<Void, Never>?

    // MARK: Convert

    @Published var convertSource: URL?
    @Published var convertSourceFormat: ArchiveFormat?
    @Published var convertTargetFormat: ArchiveFormat?
    @Published var isConverting = false
    @Published var convertProgress: Double = 0
    @Published var convertPhaseLabel = ""
    @Published var convertStatus = ""
    @Published var convertStatusKind = StatusLine.Kind.idle
    private var convertTask: Task<Void, Never>?

    var canClear: Bool {
        !isUnpacking && !isPacking && !isConverting
            && !(unpackSource == nil && packItems.isEmpty && convertSource == nil)
    }

    func clear() {
        guard canClear else { return }
        unpackSource = nil
        unpackFormat = nil
        unpackStatus = ""
        unpackStatusKind = .idle

        packItems = []
        packArchiveName = Self.defaultArchiveName
        packStatus = ""
        packStatusKind = .idle

        convertSource = nil
        convertSourceFormat = nil
        convertTargetFormat = nil
        convertStatus = ""
        convertStatusKind = .idle
    }

    // MARK: - Unpack

    func chooseUnpackSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        loadUnpackSource(chosen)
    }

    func loadUnpackSource(_ url: URL) {
        guard !isUnpacking else { return }
        unpackSource = url
        unpackFormat = ArchiveFormat.detect(from: url)
        unpackProgress = 0
        if unpackFormat == nil {
            unpackStatus = CompressionError.unrecognizedFormat.localizedDescription
            unpackStatusKind = .failure
        } else {
            unpackStatus = ""
            unpackStatusKind = .idle
        }
    }

    var canUnpack: Bool {
        !isUnpacking && unpackSource != nil && unpackFormat != nil
    }

    func runUnpack(directory: OutputDirectory) {
        guard canUnpack, let source = unpackSource, let format = unpackFormat else { return }

        let stem = format.stem(of: source)
        let target = Self.uniqueDirectoryURL(directory: directory.url, stem: stem)

        isUnpacking = true
        unpackProgress = 0
        unpackStatusKind = .working
        unpackStatus = String(localized: "Unpacking…")

        unpackTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try ArchiveExtractor.extract(
                    archive: source,
                    format: format,
                    to: target,
                    onProgress: { current, total in
                        DispatchQueue.main.async {
                            guard let self, self.unpackSource == source else { return }
                            self.unpackProgress = total > 0 ? Double(current) / Double(total) : 0
                        }
                    },
                    isCancelled: { Task.isCancelled }
                )
                await MainActor.run {
                    guard let self, self.unpackSource == source else { return }
                    self.isUnpacking = false
                    self.finishUnpack(result: result, target: target)
                }
            } catch is CancellationError {
                await MainActor.run { self?.reportUnpackCancelled() }
            } catch CompressionError.cancelled {
                await MainActor.run { self?.reportUnpackCancelled() }
            } catch {
                await MainActor.run {
                    guard let self, self.unpackSource == source else { return }
                    self.isUnpacking = false
                    self.unpackStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.unpackStatusKind = .failure
                }
            }
        }
    }

    private func finishUnpack(result: ArchiveExtractionResult, target: URL) {
        var message = String(
            localized: "Done. \(result.extractedCount) files unpacked to \(target.lastPathComponent).",
            comment: "Placeholders: file count, destination folder name"
        )
        if !result.failed.isEmpty {
            let list = ListFormatter.localizedString(byJoining: result.failed)
            message += " " + String(
                localized: "Skipped: \(list)",
                comment: "Placeholder is a comma-separated list of entry names that could not be extracted"
            )
        }
        unpackStatus = message
        unpackStatusKind = .success
    }

    private func reportUnpackCancelled() {
        isUnpacking = false
        unpackStatus = String(localized: "Cancelled.")
        unpackStatusKind = .idle
    }

    func cancelUnpack() {
        unpackTask?.cancel()
    }

    /// Appends " (2)", " (3)", … rather than ever writing into an existing
    /// folder — the same collision rule `ImageConverter.uniqueURL` applies to
    /// output files, just for a directory instead of a file.
    private static func uniqueDirectoryURL(directory: URL, stem: String) -> URL {
        var candidate = directory.appendingPathComponent(stem, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(counter))", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    // MARK: - Pack

    func addPackFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !packItems.contains(url) {
            packItems.append(url)
        }
    }

    func addPackItem(_ url: URL) {
        guard !packItems.contains(url) else { return }
        packItems.append(url)
    }

    func removePackItem(_ url: URL) {
        packItems.removeAll { $0 == url }
    }

    var canPack: Bool {
        !isPacking && !packItems.isEmpty && !packArchiveName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func runPack(directory: OutputDirectory) {
        guard canPack else { return }

        let items = packItems
        let format = packFormat
        let name = packArchiveName.trimmingCharacters(in: .whitespaces)
        let target = ImageConverter.uniqueURL(directory: directory.url, stem: name, extension: format.fileExtension)

        isPacking = true
        packProgress = 0
        packStatusKind = .working
        packStatus = String(localized: "Packing…")

        packTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try ArchiveBuilder.create(
                    format: format,
                    from: items,
                    to: target,
                    onProgress: { current, total in
                        DispatchQueue.main.async {
                            self?.packProgress = total > 0 ? Double(current) / Double(total) : 0
                        }
                    },
                    isCancelled: { Task.isCancelled }
                )
                await MainActor.run {
                    guard let self else { return }
                    self.isPacking = false
                    self.packStatus = String(
                        localized: "Done: \(target.lastPathComponent)",
                        comment: "Placeholder is the written archive's file name"
                    )
                    self.packStatusKind = .success
                }
            } catch is CancellationError {
                await MainActor.run { self?.reportPackCancelled() }
            } catch CompressionError.cancelled {
                await MainActor.run { self?.reportPackCancelled() }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isPacking = false
                    self.packStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.packStatusKind = .failure
                }
            }
        }
    }

    private func reportPackCancelled() {
        isPacking = false
        packStatus = String(localized: "Cancelled.")
        packStatusKind = .idle
    }

    func cancelPack() {
        packTask?.cancel()
    }

    // MARK: - Convert

    func chooseConvertSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        loadConvertSource(chosen)
    }

    func loadConvertSource(_ url: URL) {
        guard !isConverting else { return }
        convertSource = url
        let format = ArchiveFormat.detect(from: url)
        convertSourceFormat = format
        convertTargetFormat = format?.other
        convertProgress = 0
        if format == nil {
            convertStatus = CompressionError.unrecognizedFormat.localizedDescription
            convertStatusKind = .failure
        } else {
            convertStatus = ""
            convertStatusKind = .idle
        }
    }

    var canConvert: Bool {
        !isConverting && convertSource != nil && convertSourceFormat != nil && convertTargetFormat != nil
    }

    func runConvert(directory: OutputDirectory) {
        guard canConvert,
              let source = convertSource,
              let sourceFormat = convertSourceFormat,
              let targetFormat = convertTargetFormat
        else { return }

        let stem = sourceFormat.stem(of: source)
        let target = ImageConverter.uniqueURL(directory: directory.url, stem: stem, extension: targetFormat.fileExtension)

        isConverting = true
        convertProgress = 0
        convertStatusKind = .working
        convertPhaseLabel = String(localized: "Unpacking…")
        convertStatus = ""

        convertTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try ArchiveConverter.convert(
                    archive: source,
                    sourceFormat: sourceFormat,
                    to: targetFormat,
                    destinationArchive: target,
                    onExtractProgress: { current, total in
                        DispatchQueue.main.async {
                            guard let self, self.convertSource == source else { return }
                            self.convertPhaseLabel = String(localized: "Unpacking…")
                            self.convertProgress = total > 0 ? Double(current) / Double(total) : 0
                        }
                    },
                    onPackProgress: { current, total in
                        DispatchQueue.main.async {
                            guard let self, self.convertSource == source else { return }
                            self.convertPhaseLabel = String(localized: "Packing…")
                            self.convertProgress = total > 0 ? Double(current) / Double(total) : 0
                        }
                    },
                    isCancelled: { Task.isCancelled }
                )
                await MainActor.run {
                    guard let self, self.convertSource == source else { return }
                    self.isConverting = false
                    self.convertStatus = String(
                        localized: "Done: \(target.lastPathComponent)",
                        comment: "Placeholder is the written archive's file name"
                    )
                    self.convertStatusKind = .success
                }
            } catch is CancellationError {
                await MainActor.run { self?.reportConvertCancelled() }
            } catch CompressionError.cancelled {
                await MainActor.run { self?.reportConvertCancelled() }
            } catch {
                await MainActor.run {
                    guard let self, self.convertSource == source else { return }
                    self.isConverting = false
                    self.convertStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.convertStatusKind = .failure
                }
            }
        }
    }

    private func reportConvertCancelled() {
        isConverting = false
        convertStatus = String(localized: "Cancelled.")
        convertStatusKind = .idle
    }

    func cancelConvert() {
        convertTask?.cancel()
    }
}

struct CompressionView: View {
    @ObservedObject var session: CompressionSession
    @StateObject private var unpackDirectory = OutputDirectory(defaultsKey: "CompressionUnpackOutputDir")
    @StateObject private var packDirectory = OutputDirectory(defaultsKey: "CompressionPackOutputDir")
    @StateObject private var convertDirectory = OutputDirectory(defaultsKey: "CompressionConvertOutputDir")

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Compression",
                    subtitle: "Unpacks and creates ZIP and TAR.GZ archives, and converts between the two."
                )

                Picker("Mode", selection: $session.mode) {
                    ForEach(CompressionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(session.isUnpacking || session.isPacking || session.isConverting)

                switch session.mode {
                case .unpack: unpackContent
                case .pack: packContent
                case .convert: convertContent
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Unpack

    @State private var isUnpackDropTargeted = false

    @ViewBuilder
    private var unpackContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            FileRow(
                label: "Archive",
                file: session.unpackSource,
                isEnabled: !session.isUnpacking,
                onChoose: { session.chooseUnpackSource() },
                onClear: { session.unpackSource = nil; session.unpackFormat = nil }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isUnpackDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isUnpackDropTargeted) { providers in
                handleSingleFileDrop(providers) { session.loadUnpackSource($0) }
            }

            if let format = session.unpackFormat {
                Text("Detected format: \(format.rawValue)", comment: "Placeholder is an archive format name such as ZIP or TAR.GZ, not translated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            OutputDirectoryRow(directory: unpackDirectory, isEnabled: !session.isUnpacking)

            actionRow(
                actionTitle: "Unpack",
                canRun: session.canUnpack,
                isRunning: session.isUnpacking,
                progress: session.unpackProgress,
                phaseLabel: nil,
                status: session.unpackStatus,
                statusKind: session.unpackStatusKind,
                run: { session.runUnpack(directory: unpackDirectory) },
                cancel: { session.cancelUnpack() }
            )
        }
    }

    // MARK: - Pack

    @State private var isPackDropTargeted = false

    @ViewBuilder
    private var packContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            packItemsList

            HStack(spacing: 10) {
                Text("Target format")
                Picker(selection: $session.packFormat) {
                    ForEach(ArchiveFormat.allCases) { Text($0.rawValue).tag($0) }
                } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(session.isPacking)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Archive name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField("Archive", text: $session.packArchiveName)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .frame(maxWidth: 240)
                        .disabled(session.isPacking)
                    Text(verbatim: ".\(session.packFormat.fileExtension)")
                        .foregroundStyle(.secondary)
                }
            }

            OutputDirectoryRow(directory: packDirectory, isEnabled: !session.isPacking)

            actionRow(
                actionTitle: "Pack",
                canRun: session.canPack,
                isRunning: session.isPacking,
                progress: session.packProgress,
                phaseLabel: nil,
                status: session.packStatus,
                statusKind: session.packStatusKind,
                run: { session.runPack(directory: packDirectory) },
                cancel: { session.cancelPack() }
            )
        }
    }

    @ViewBuilder
    private var packItemsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.packItems.isEmpty {
                Text("Drag files or folders here, or add them below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                List {
                    ForEach(session.packItems, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(systemName: isDirectory(url) ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(url.path)
                            Spacer(minLength: 8)
                            Button {
                                session.removePackItem(url)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Add…") { session.addPackFiles() }
                Button("Clear") { session.packItems = [] }
                    .disabled(session.packItems.isEmpty)
            }
        }
        .disabled(session.isPacking)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPackDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isPackDropTargeted) { providers in
            handleMultiFileDrop(providers) { session.addPackItem($0) }
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    // MARK: - Convert

    @State private var isConvertDropTargeted = false

    @ViewBuilder
    private var convertContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            FileRow(
                label: "Archive",
                file: session.convertSource,
                isEnabled: !session.isConverting,
                onChoose: { session.chooseConvertSource() },
                onClear: {
                    session.convertSource = nil
                    session.convertSourceFormat = nil
                    session.convertTargetFormat = nil
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isConvertDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isConvertDropTargeted) { providers in
                handleSingleFileDrop(providers) { session.loadConvertSource($0) }
            }

            if let sourceFormat = session.convertSourceFormat {
                HStack(spacing: 10) {
                    Text("Detected format: \(sourceFormat.rawValue)", comment: "Placeholder is an archive format name such as ZIP or TAR.GZ, not translated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Text("Target format")
                    Picker(selection: Binding(
                        get: { session.convertTargetFormat ?? sourceFormat.other },
                        set: { session.convertTargetFormat = $0 }
                    )) {
                        Text(sourceFormat.other.rawValue).tag(sourceFormat.other)
                    } label: { EmptyView() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(session.isConverting)
                }
            }

            OutputDirectoryRow(directory: convertDirectory, isEnabled: !session.isConverting)

            actionRow(
                actionTitle: "Convert",
                canRun: session.canConvert,
                isRunning: session.isConverting,
                progress: session.convertProgress,
                phaseLabel: session.convertPhaseLabel,
                status: session.convertStatus,
                statusKind: session.convertStatusKind,
                run: { session.runConvert(directory: convertDirectory) },
                cancel: { session.cancelConvert() }
            )
        }
    }

    // MARK: - Shared action row

    @ViewBuilder
    private func actionRow(
        actionTitle: LocalizedStringKey,
        canRun: Bool,
        isRunning: Bool,
        progress: Double,
        phaseLabel: String?,
        status: String,
        statusKind: StatusLine.Kind,
        run: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(actionTitle, action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                if isRunning {
                    Button("Cancel", action: cancel)
                }
                Button("Clear") { session.clear() }
                    .disabled(!session.canClear)
                StatusLine(text: status, kind: statusKind)
            }
            if isRunning {
                HStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 260)
                    Text(verbatim: "\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let phaseLabel, !phaseLabel.isEmpty {
                        Text(verbatim: phaseLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Drag & drop

    private func handleSingleFileDrop(_ providers: [NSItemProvider], onLoad: @escaping (URL) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = fileURL(from: item) else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { return }
            DispatchQueue.main.async { onLoad(url) }
        }
        return true
    }

    private func handleMultiFileDrop(_ providers: [NSItemProvider], onEach: @escaping (URL) -> Void) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = fileURL(from: item) else { return }
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                DispatchQueue.main.async { onEach(url) }
            }
        }
        return true
    }

    private func fileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        return item as? URL
    }
}
