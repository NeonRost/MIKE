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

/// Survives navigating away from and back to Combine Images — see
/// `ArticleExtractionSession` for why this is needed at all. The
/// direction/size-handling pickers are `@AppStorage` in the view and already
/// persist on their own, so they are not part of this.
@MainActor
final class CombineImagesSession: ObservableObject {
    @Published var source = CombineSource.folder
    @Published var folder: URL?
    @Published var fileCount = 0
    @Published var pickedFiles: [URL] = []
    @Published var isRunning = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    var canCombine: Bool {
        guard !isRunning else { return false }
        return source == .folder ? folder != nil : !pickedFiles.isEmpty
    }

    func clear() {
        guard !isRunning else { return }
        source = .folder
        folder = nil
        fileCount = 0
        pickedFiles = []
        status = ""
        statusKind = .idle
    }

    func chooseFolder(directory: OutputDirectory) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the folder picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        folder = chosen
        fileCount = ImageStacker.candidates(in: chosen).count
        // Folder mode keeps writing next to the sources, as it always has —
        // only now it is visible and can be redirected.
        directory.set(chosen)
        status = ""
        statusKind = .idle
    }

    func combine(
        output: CombineOutput,
        direction: StackDirection,
        handling: SizeHandling,
        directory: OutputDirectory
    ) {
        guard canCombine else { return }

        let target = directory.url
        let files = source == .folder
            ? (folder.map { ImageStacker.candidates(in: $0) } ?? [])
            : pickedFiles
        // An EPUB carries a title. The folder the images came from is the one
        // name the user has already given this set; the output stem is the
        // fallback when they came from scattered files.
        let title = (source == .folder ? folder : pickedFiles.first?.deletingLastPathComponent())?
            .lastPathComponent ?? ImageStacker.outputStem

        isRunning = true
        statusKind = .working
        status = String(localized: "Combining…")

        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let produced: ImageStacker.Output
                        switch output {
                        case .pdf:
                            produced = try ImageStacker.pdf(files: files, into: target)
                        case .epub:
                            let url = try EPUBBuilder.build(files: files, into: target, title: title)
                            produced = ImageStacker.Output(url: url, usedPNGFallback: false)
                        case .image:
                            produced = try ImageStacker.stack(
                                files: files,
                                into: target,
                                direction: direction,
                                handling: handling
                            )
                        }
                        let output = produced
                        continuation.resume(returning: Result<ImageStacker.Output, Error>.success(output))
                    } catch {
                        continuation.resume(returning: Result<ImageStacker.Output, Error>.failure(error))
                    }
                }
            }

            isRunning = false
            switch result {
            case .success(let output):
                // Silently handing back a .png where the label promised .jpg
                // would look like a bug, so the reason comes with the result.
                status = output.usedPNGFallback
                    ? String(
                        localized: "Finished: \(output.url.lastPathComponent) — too tall for JPEG, saved as PNG",
                        comment: "Placeholder is the written file name"
                      )
                    : String(
                        localized: "Finished: \(output.url.lastPathComponent)",
                        comment: "Placeholder is the written file name"
                      )
                statusKind = .success
                if let folder { fileCount = ImageStacker.candidates(in: folder).count }
            case .failure(let error):
                status = error.localizedDescription
                statusKind = .failure
            }
        }
    }
}

struct CombineImagesView: View {
    @ObservedObject var session: CombineImagesSession
    @StateObject private var directory = OutputDirectory(defaultsKey: "CombineImagesOutputDir")

    // Remembered like the output folder, so a chosen layout survives restarts.
    @AppStorage("CombineImagesDirection") private var directionRaw = StackDirection.vertical.rawValue
    @AppStorage("CombineImagesSizeHandling") private var handlingRaw = SizeHandling.whiteStart.rawValue
    @AppStorage("CombineImagesOutput") private var outputRaw = CombineOutput.image.rawValue

    private var output: CombineOutput {
        CombineOutput(rawValue: outputRaw) ?? .image
    }

    private var direction: StackDirection {
        StackDirection(rawValue: directionRaw) ?? .vertical
    }

    private var handling: SizeHandling {
        SizeHandling(rawValue: handlingRaw) ?? .whiteStart
    }

    private var canClear: Bool {
        !session.isRunning && !(session.folder == nil && session.pickedFiles.isEmpty)
    }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Combine Images",
                    subtitle: "Joins JPEGs and PNGs into a single image — stacked into a tall one or lined up into a wide one — or into a PDF or EPUB with one page per image."
                )

                Picker("Source", selection: $session.source) {
                    ForEach(CombineSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(session.isRunning)

                if session.source == .folder {
                    FolderRow(
                        folder: session.folder,
                        detail: session.folder == nil
                            ? nil
                            : String(
                                localized: "\(session.fileCount) images found, in name order",
                                comment: "Count of images in the chosen folder"
                              ),
                        isEnabled: !session.isRunning,
                        onChoose: { session.chooseFolder(directory: directory) }
                    )
                } else {
                    FileListEditor(
                        files: $session.pickedFiles,
                        allowedExtensions: ImageStacker.acceptedExtensions,
                        emptyMessage: "No images selected. Add some — the order you put them in is the order they are combined.",
                        addTitle: "Add Images…",
                        isEnabled: !session.isRunning
                    )
                }

                layoutOptions

                OutputDirectoryRow(directory: directory, isEnabled: !session.isRunning)

                HStack(spacing: 12) {
                    Button("Combine") {
                        session.combine(
                            output: output,
                            direction: direction,
                            handling: handling,
                            directory: directory
                        )
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canCombine)
                    Button("Clear") { session.clear() }
                        .disabled(!canClear)
                    StatusLine(text: session.status, kind: session.statusKind)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var layoutOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Combine into")
                Picker("Combine into", selection: $outputRaw) {
                    ForEach(CombineOutput.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            // Layout has nothing to say about a PDF: every image is its own
            // page at its own size, so the two pickers are hidden rather than
            // shown having no effect.
            if output.isStacked {
                HStack(spacing: 10) {
                    Text("Direction")
                    Picker("Direction", selection: $directionRaw) {
                        ForEach(StackDirection.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                HStack(spacing: 10) {
                    Text("If sizes differ")
                    // Five wordy options: a menu reads better than a segmented row.
                    Picker("If sizes differ", selection: $handlingRaw) {
                        ForEach(SizeHandling.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // The choice decides the file type, so it is spelled out rather
            // than left as a surprise.
            Group {
                switch output {
                case .pdf:
                    Text("Saved as \(ImageStacker.pdfOutputName) — one page per image, no size limit")
                case .epub:
                    Text("Saved as \(EPUBBuilder.outputName) — one page per image, images kept as they are")
                case .image:
                    Text("Saved as \(ImageStacker.outputName(for: handling))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .disabled(session.isRunning)
    }
}
