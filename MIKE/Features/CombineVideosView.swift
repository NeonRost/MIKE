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

struct CombineVideosView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry
    @StateObject private var directory = OutputDirectory(defaultsKey: "CombineVideosOutputDir")

    @State private var source = CombineSource.folder
    @State private var folder: URL?
    @State private var fileCount = 0
    @State private var pickedFiles: [URL] = []
    @State private var isRunning = false
    @State private var isInspecting = false
    @State private var problems: [(file: String, reasons: [String])] = []
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle
    /// Held so Cancel can stop the running ffmpeg.
    @State private var runningProcess: Process?

    private var missingTools: [Tool] {
        tools.missing(from: AppSection.combineVideos.requiredTools)
    }

    private var isReady: Bool { missingTools.isEmpty }

    private var hasInput: Bool {
        source == .folder ? folder != nil : !pickedFiles.isEmpty
    }

    private var canCombine: Bool {
        !isRunning && !isInspecting && hasInput && problems.isEmpty
    }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Combine Videos",
                    subtitle: "Joins MP4s without re-encoding, saved as \(VideoConcatenator.outputName). All inputs need the same codec and format."
                )

                if !isReady {
                    RequirementBanner(missing: missingTools, onOpenTools: onOpenTools)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Picker("Source", selection: $source) {
                        ForEach(CombineSource.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(isRunning)
                    .onChange(of: source) { _ in refreshInspection() }

                    if source == .folder {
                        FolderRow(
                            folder: folder,
                            detail: folderDetail,
                            isEnabled: !isRunning && !isInspecting,
                            onChoose: chooseFolder
                        )
                    } else {
                        FileListEditor(
                            files: $pickedFiles,
                            allowedExtensions: VideoConcatenator.acceptedExtensions,
                            emptyMessage: "No videos selected. Add some — the order you put them in is the order they are combined.",
                            addTitle: "Add Videos…",
                            isEnabled: !isRunning && !isInspecting
                        )
                        .onChange(of: pickedFiles) { _ in refreshInspection() }
                    }

                    if !problems.isEmpty {
                        mismatchNotice
                    }

                    OutputDirectoryRow(directory: directory, isEnabled: !isRunning)

                    HStack(spacing: 12) {
                        Button("Combine") { combine() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canCombine)
                        if isRunning {
                            Button("Cancel") { cancel() }
                        }
                        StatusLine(text: status, kind: statusKind)
                    }
                }
                .disabled(!isReady)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var folderDetail: String? {
        guard folder != nil else { return nil }
        if isInspecting { return String(localized: "Checking files…") }
        return String(
            localized: "\(fileCount) videos found, in name order",
            comment: "Count of videos in the chosen folder"
        )
    }

    /// Joining without re-encoding needs identical streams. ffmpeg would
    /// happily produce a broken file instead of failing, so the mismatch is
    /// spelled out here and the button stays off.
    private var mismatchNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("These videos do not match and cannot be joined without re-encoding.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(problems, id: \.file) { problem in
                    Text(verbatim: "\(problem.file): \(ListFormatter.localizedString(byJoining: problem.reasons))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Joining them anyway would give you a file with broken timing or audio, so MIKE does not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func cancel() {
        guard let process = runningProcess, process.isRunning else { return }
        status = String(localized: "Cancelling…")
        process.terminate()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the folder picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        folder = chosen
        fileCount = VideoConcatenator.candidates(in: chosen).count
        // Folder mode keeps writing next to the sources, as it always has —
        // only now it is visible and can be redirected.
        directory.set(chosen)
        status = ""
        statusKind = .idle
        refreshInspection()
    }

    /// Runs whenever the input changes, so a mismatch is visible before the
    /// user commits to anything.
    private func refreshInspection() {
        problems = []
        guard let ffmpeg = tools.status(for: .ffmpeg).url else { return }

        let files = source == .folder
            ? (folder.map { VideoConcatenator.candidates(in: $0) } ?? [])
            : pickedFiles
        guard files.count > 1 else { return }

        isInspecting = true
        Task {
            let found = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let check = VideoConcatenator.preflight(files: files, ffmpeg: ffmpeg)
                    continuation.resume(returning: check.problems)
                }
            }
            problems = found
            isInspecting = false
        }
    }

    private func combine() {
        guard canCombine, let ffmpeg = tools.status(for: .ffmpeg).url else { return }

        let target = directory.url
        let files = source == .folder
            ? (folder.map { VideoConcatenator.candidates(in: $0) } ?? [])
            : pickedFiles

        isRunning = true
        statusKind = .working
        status = String(localized: "Joining…")

        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let output = try VideoConcatenator.concatenate(
                            files: files,
                            into: target,
                            ffmpeg: ffmpeg,
                            onStart: { process in
                                DispatchQueue.main.async { runningProcess = process }
                            }
                        )
                        continuation.resume(returning: Result<URL, Error>.success(output))
                    } catch {
                        continuation.resume(returning: Result<URL, Error>.failure(error))
                    }
                }
            }

            isRunning = false
            runningProcess = nil
            switch result {
            case .success(let output):
                status = String(localized: "Finished: \(output.lastPathComponent)", comment: "Placeholder is the written file name")
                statusKind = .success
                if let folder { fileCount = VideoConcatenator.candidates(in: folder).count }
            case .failure(let error):
                // Stopping on purpose is not a failure, so it is not red.
                let cancelled = (error as? VideoConcatError).map {
                    if case .cancelled = $0 { return true } else { return false }
                } ?? false
                status = error.localizedDescription
                statusKind = cancelled ? .idle : .failure
            }
        }
    }
}
