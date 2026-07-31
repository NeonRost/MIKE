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

struct TrackSplitterView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry
    @StateObject private var directory = OutputDirectory(defaultsKey: "TrackSplitterOutputDir")

    @State private var sourceFile: URL?
    @State private var thresholdDB: Double = -30
    @State private var minDuration: Double = 0.5

    @State private var isAnalyzing = false
    @State private var analysis: SilenceAnalysis?
    @State private var trackRanges: [TrackRange] = []
    @State private var trackNames: [String] = []
    @State private var patternText = ""

    @State private var isSplitting = false
    @State private var currentTrackIndex = 0
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle
    @State private var runningProcess: Process?
    @State private var isDropTargeted = false

    private var missingTools: [Tool] {
        tools.missing(from: AppSection.trackSplitter.requiredTools)
    }

    private var isReady: Bool { missingTools.isEmpty }
    private var isBusy: Bool { isAnalyzing || isSplitting }
    private var hasAnalyzed: Bool { analysis != nil }
    private var canSplit: Bool { !isBusy && !trackRanges.isEmpty }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Track Splitter",
                    subtitle: "Splits one audio file into several at the silences between tracks, without re-encoding."
                )

                if !isReady {
                    RequirementBanner(missing: missingTools, onOpenTools: onOpenTools)
                }

                VStack(alignment: .leading, spacing: 16) {
                    fileRow

                    if sourceFile != nil {
                        analysisStep
                        if hasAnalyzed {
                            analysisResult
                        }
                        if !trackRanges.isEmpty {
                            namingStep
                            OutputDirectoryRow(directory: directory, isEnabled: !isSplitting)
                            splitStep
                        }
                    }
                }
                .disabled(!isReady)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Input

    @ViewBuilder
    private var fileRow: some View {
        FileRow(
            label: "Audio file",
            file: sourceFile,
            isEnabled: !isBusy,
            onChoose: chooseFile,
            onClear: clearFile
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Step 1: analyze

    @ViewBuilder
    private var analysisStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Silence threshold")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: "\(Int(thresholdDB)) dB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $thresholdDB, in: -60...(-10), step: 1)
            }
            .frame(maxWidth: 320)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minimum silence duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: String(format: "%.1f s", minDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $minDuration, in: 0.1...5.0, step: 0.1)
            }
            .frame(maxWidth: 320)

            HStack(spacing: 12) {
                Button("Analyze") { analyze() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                if isAnalyzing {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isSplitting)
    }

    @ViewBuilder
    private var analysisResult: some View {
        if trackRanges.isEmpty {
            Label(
                "No silence found with these settings. Try a higher threshold or a shorter minimum duration.",
                systemImage: "waveform.slash"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Found \(trackRanges.count) tracks",
                    comment: "Placeholder is a count of detected tracks"
                )
                .font(.callout.bold())
                Text(verbatim: trackRanges.map { "\(timestamp($0.start))–\(timestamp($0.end))" }.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 2: name tracks

    @ViewBuilder
    private var namingStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name pattern")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Albumname_%n", text: $patternText)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 280)
                    .onChange(of: patternText) { newValue in
                        guard !newValue.isEmpty else { return }
                        trackNames = AudioSplitter.applyPattern(newValue, trackCount: trackRanges.count)
                    }
                Text(verbatim: "%n   track number (01, 02, …)\n%t   total number of tracks")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Track names")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(trackNames.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text(verbatim: "\(index + 1).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 22, alignment: .trailing)
                        TextField(text: Binding(
                            get: { trackNames[index] },
                            set: { trackNames[index] = $0 }
                        )) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    }
                }
            }
            .frame(maxWidth: 320)
        }
        .disabled(isSplitting)
    }

    // MARK: - Step 3: split

    @ViewBuilder
    private var splitStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Split") { split() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSplit)
                if isSplitting {
                    Button("Cancel") { cancel() }
                }
                StatusLine(text: status, kind: statusKind)
            }
            if isSplitting {
                ProgressView(value: Double(currentTrackIndex), total: Double(trackRanges.count))
                    .frame(maxWidth: 260)
            }
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isBusy, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url, AudioSplitter.acceptedExtensions.contains(url.pathExtension.lowercased())
            else { return }
            DispatchQueue.main.async { load(url) }
        }
        return true
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        load(chosen)
    }

    private func load(_ url: URL) {
        sourceFile = url
        directory.set(url.deletingLastPathComponent())
        resetAnalysis()
    }

    private func clearFile() {
        sourceFile = nil
        resetAnalysis()
    }

    private func resetAnalysis() {
        analysis = nil
        trackRanges = []
        trackNames = []
        patternText = ""
        status = ""
        statusKind = .idle
    }

    private func analyze() {
        guard let sourceFile, let ffmpeg = tools.status(for: .ffmpeg).url, !isBusy else { return }
        let threshold = thresholdDB
        let minDur = minDuration

        isAnalyzing = true
        status = String(localized: "Analyzing…")
        statusKind = .working

        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: AudioSplitter.analyze(
                            file: sourceFile, thresholdDB: threshold, minDuration: minDur, ffmpeg: ffmpeg
                        )
                    )
                }
            }

            isAnalyzing = false
            guard let result else {
                status = String(localized: "The file could not be analyzed.")
                statusKind = .failure
                return
            }

            analysis = result
            let ranges = AudioSplitter.trackRanges(duration: result.duration, silences: result.silences)
            trackRanges = ranges
            trackNames = AudioSplitter.defaultNames(trackCount: ranges.count)
            patternText = ""
            status = ""
            statusKind = .idle
        }
    }

    private func cancel() {
        guard let process = runningProcess, process.isRunning else { return }
        status = String(localized: "Cancelling…")
        process.terminate()
    }

    private func split() {
        guard canSplit, let sourceFile, let ffmpeg = tools.status(for: .ffmpeg).url else { return }
        let ranges = trackRanges
        let names = trackNames
        let extension_ = sourceFile.pathExtension
        let target = directory.url

        isSplitting = true
        currentTrackIndex = 0
        statusKind = .working
        status = String(localized: "Splitting…")

        Task {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

            var completed = 0
            for (index, range) in ranges.enumerated() {
                currentTrackIndex = index + 1
                let stem = names[index].trimmingCharacters(in: .whitespaces).isEmpty
                    ? "track_\(index + 1)" : names[index]
                status = String(
                    localized: "Cutting \(currentTrackIndex) of \(ranges.count): \(stem)",
                    comment: "Progress while splitting a track out of the source file"
                )

                let destination = ImageConverter.uniqueURL(directory: target, stem: stem, extension: extension_)
                let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try AudioSplitter.cut(
                                source: sourceFile, range: range, to: destination, ffmpeg: ffmpeg,
                                onStart: { process in DispatchQueue.main.async { runningProcess = process } }
                            )
                            continuation.resume(returning: .success(()))
                        } catch {
                            continuation.resume(returning: .failure(error))
                        }
                    }
                }

                switch outcome {
                case .success:
                    completed += 1
                case .failure(let error):
                    isSplitting = false
                    runningProcess = nil
                    if error is CancellationError {
                        status = String(
                            localized: "Cancelled after \(completed) tracks. The finished ones are kept.",
                            comment: "Placeholder is a count of tracks"
                        )
                        statusKind = .idle
                    } else {
                        status = error.localizedDescription
                        statusKind = .failure
                    }
                    return
                }
            }

            isSplitting = false
            runningProcess = nil
            status = String(localized: "Done. \(completed) tracks written.", comment: "Placeholder is a count of tracks")
            statusKind = .success
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
