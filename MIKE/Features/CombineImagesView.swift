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

struct CombineImagesView: View {
    @StateObject private var directory = OutputDirectory(defaultsKey: "CombineImagesOutputDir")

    // Remembered like the output folder, so a chosen layout survives restarts.
    @AppStorage("CombineImagesDirection") private var directionRaw = StackDirection.vertical.rawValue
    @AppStorage("CombineImagesSizeHandling") private var handlingRaw = SizeHandling.whiteStart.rawValue

    @State private var source = CombineSource.folder
    @State private var folder: URL?
    @State private var fileCount = 0
    @State private var pickedFiles: [URL] = []
    @State private var isRunning = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle

    private var direction: StackDirection {
        StackDirection(rawValue: directionRaw) ?? .vertical
    }

    private var handling: SizeHandling {
        SizeHandling(rawValue: handlingRaw) ?? .whiteStart
    }

    private var canCombine: Bool {
        guard !isRunning else { return false }
        return source == .folder ? folder != nil : !pickedFiles.isEmpty
    }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Combine Images",
                    subtitle: "Joins JPEGs and PNGs into a single image — stacked into a tall one or lined up into a wide one."
                )

                Picker("Source", selection: $source) {
                    ForEach(CombineSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(isRunning)

                if source == .folder {
                    FolderRow(
                        folder: folder,
                        detail: folder == nil
                            ? nil
                            : String(
                                localized: "\(fileCount) images found, in name order",
                                comment: "Count of images in the chosen folder"
                              ),
                        isEnabled: !isRunning,
                        onChoose: chooseFolder
                    )
                } else {
                    FileListEditor(
                        files: $pickedFiles,
                        allowedExtensions: ImageStacker.acceptedExtensions,
                        emptyMessage: "No images selected. Add some — the order you put them in is the order they are combined.",
                        addTitle: "Add Images…",
                        isEnabled: !isRunning
                    )
                }

                layoutOptions

                OutputDirectoryRow(directory: directory, isEnabled: !isRunning)

                HStack(spacing: 12) {
                    Button("Combine") { combine() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCombine)
                    StatusLine(text: status, kind: statusKind)
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

            // The choice decides the file type, so it is spelled out rather
            // than left as a surprise.
            Text("Saved as \(ImageStacker.outputName(for: handling))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(isRunning)
    }

    private func chooseFolder() {
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

    private func combine() {
        guard canCombine else { return }

        let target = directory.url
        let chosenDirection = direction
        let chosenHandling = handling
        let files = source == .folder
            ? (folder.map { ImageStacker.candidates(in: $0) } ?? [])
            : pickedFiles

        isRunning = true
        statusKind = .working
        status = String(localized: "Combining…")

        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let output = try ImageStacker.stack(
                            files: files,
                            into: target,
                            direction: chosenDirection,
                            handling: chosenHandling
                        )
                        continuation.resume(returning: Result<URL, Error>.success(output))
                    } catch {
                        continuation.resume(returning: Result<URL, Error>.failure(error))
                    }
                }
            }

            isRunning = false
            switch result {
            case .success(let output):
                status = String(localized: "Finished: \(output.lastPathComponent)", comment: "Placeholder is the written file name")
                statusKind = .success
                if let folder { fileCount = ImageStacker.candidates(in: folder).count }
            case .failure(let error):
                status = error.localizedDescription
                statusKind = .failure
            }
        }
    }
}
