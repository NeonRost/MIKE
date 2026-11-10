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

/// Survives navigating away from and back to Track Splitter — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class TrackSplitterSession: ObservableObject {
    @Published var sourceFile: URL?
    @Published var thresholdDB: Double = -30
    @Published var minDuration: Double = 0.5

    @Published var isAnalyzing = false
    @Published var analysis: SilenceAnalysis?
    @Published var trackRanges: [TrackRange] = []
    @Published var trackNames: [String] = []
    @Published var trackStartTexts: [String] = []
    @Published var trackEndTexts: [String] = []
    @Published var patternText = ""

    /// Kept apart from Trim Video's own constant of the same value — a
    /// coincidence of both sections wanting a sane non-zero minimum, not a
    /// shared concept worth wiring together.
    static let minimumTrackLength: Double = 0.1

    // Tags applied to every track alike. Nothing is pre-filled — an empty
    // field is left unwritten by `AudioTagEditor.write`, the same rule Tag
    // Editor already follows.
    @Published var tagArtist = ""
    @Published var tagAlbumArtist = ""
    @Published var tagAlbum = ""
    @Published var tagYear = ""
    @Published var tagGenre = ""
    @Published var tagComment = ""
    @Published var coverImage: NSImage?
    @Published var coverEdit: CoverEdit = .unchanged

    @Published var isSplitting = false
    @Published var currentTrackIndex = 0
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle
    @Published var statusDetails: String?
    /// 0…1 while the silence analysis decodes the file.
    @Published var analysisProgress: Double = 0
    private var runningProcess: Process?
    /// Set by Cancel and checked between steps. Stopping the process alone is
    /// not enough here: a split is many short ffmpeg runs in a row, and a
    /// click that lands between two of them would find nothing to stop.
    private var cancelRequested = false

    var isBusy: Bool { isAnalyzing || isSplitting }
    var hasAnalyzed: Bool { analysis != nil }
    var canSplit: Bool { !isBusy && !trackRanges.isEmpty }

    /// All tracks come from one source file cut with `-c copy`, so they all
    /// share its extension and therefore its tagging capabilities — computed
    /// once here rather than per track.
    var tagCapabilities: AudioFormatCapabilities {
        guard let sourceFile else {
            return AudioFormatCapabilities(supportsTags: true, supportsCoverArt: true, unsupportedFields: [])
        }
        return AudioFormatCapabilities.forExtension(sourceFile.pathExtension)
    }

    // MARK: - Cover

    func chooseCover() {
        guard tagCapabilities.supportsCoverArt else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png]
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        coverImage = NSImage(contentsOf: chosen)
        coverEdit = .replace(chosen)
    }

    func removeCover() {
        coverImage = nil
        coverEdit = .remove
    }

    // MARK: - Actions

    func chooseFile(directory: OutputDirectory) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AudioSplitter.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        load(chosen, directory: directory)
    }

    func load(_ url: URL, directory: OutputDirectory) {
        sourceFile = url
        directory.set(url.deletingLastPathComponent())
        resetAnalysis()
    }

    func clear() {
        guard !isBusy else { return }
        sourceFile = nil
        resetAnalysis()
    }

    private func resetAnalysis() {
        analysis = nil
        trackRanges = []
        trackNames = []
        trackStartTexts = []
        trackEndTexts = []
        patternText = ""
        tagArtist = ""
        tagAlbumArtist = ""
        tagAlbum = ""
        tagYear = ""
        tagGenre = ""
        tagComment = ""
        coverImage = nil
        coverEdit = .unchanged
        status = ""
        statusKind = .idle
        statusDetails = nil
    }

    func analyze(ffmpeg: URL?) {
        guard let sourceFile, let ffmpeg, !isBusy else { return }
        let threshold = thresholdDB
        let minDur = minDuration

        isAnalyzing = true
        cancelRequested = false
        analysisProgress = 0
        status = String(localized: "Analyzing…")
        statusKind = .working
        statusDetails = nil

        Task { [weak self] in
            let result: Result<SilenceAnalysis, Error> = await Background.attempt {
                let analysis = try AudioSplitter.analyze(
                    file: sourceFile, thresholdDB: threshold, minDuration: minDur, ffmpeg: ffmpeg,
                    onStart: { process in DispatchQueue.main.async { self?.runningProcess = process } },
                    onProgress: { fraction in DispatchQueue.main.async { self?.analysisProgress = fraction } }
                )
                return analysis
            }

            guard let self else { return }
            isAnalyzing = false
            runningProcess = nil

            switch result {
            case .failure(let error):
                if error is CancellationError {
                    status = String(localized: "Cancelled.")
                    statusKind = .idle
                } else {
                    status = error.localizedDescription
                    statusKind = .failure
                    statusDetails = (error as? ToolLogCarrying)?.toolLog
                }
            case .success(let result):
                analysis = result
                let ranges = AudioSplitter.trackRanges(duration: result.duration, silences: result.silences)
                trackRanges = ranges
                trackNames = AudioSplitter.defaultNames(trackCount: ranges.count)
                trackStartTexts = ranges.map { VideoTrimmer.formatTimecode($0.start) }
                trackEndTexts = ranges.map { VideoTrimmer.formatTimecode($0.end) }
                patternText = ""
                status = ""
                statusKind = .idle
            }
        }
    }

    /// Unparsable text reverts to the last valid value rather than being
    /// rejected outright — matches Trim Video's own fields. Values are
    /// clamped to the file's bounds and to keep start below end, but nothing
    /// enforces consistency between tracks: there is no preview here, and a
    /// track's window is deliberately allowed to overlap or leave a gap if
    /// that is genuinely what the file needs.
    func applyTrackStartText(_ index: Int) {
        guard trackRanges.indices.contains(index) else { return }
        guard let parsed = VideoTrimmer.parseTimecode(trackStartTexts[index]) else {
            trackStartTexts[index] = VideoTrimmer.formatTimecode(trackRanges[index].start)
            return
        }
        let upperBound = max(trackRanges[index].end - Self.minimumTrackLength, 0)
        trackRanges[index].start = min(max(parsed, 0), upperBound)
        trackStartTexts[index] = VideoTrimmer.formatTimecode(trackRanges[index].start)
    }

    func applyTrackEndText(_ index: Int) {
        guard trackRanges.indices.contains(index) else { return }
        guard let parsed = VideoTrimmer.parseTimecode(trackEndTexts[index]) else {
            trackEndTexts[index] = VideoTrimmer.formatTimecode(trackRanges[index].end)
            return
        }
        let fileDuration = analysis?.duration ?? parsed
        let lowerBound = trackRanges[index].start + Self.minimumTrackLength
        trackRanges[index].end = max(min(parsed, fileDuration), lowerBound)
        trackEndTexts[index] = VideoTrimmer.formatTimecode(trackRanges[index].end)
    }

    /// Takes over every start/end field as it stands. The fields commit on
    /// Return or on losing focus; pressing Split guarantees neither, so
    /// without this a typed boundary could sit in its field while the cut ran
    /// with the old one. Start and end of a track are resolved together, for
    /// the same reason `TrimVideoSession.commitFields` does it.
    func commitTrackFields() {
        let fileDuration = analysis?.duration
        for index in trackRanges.indices {
            guard trackStartTexts.indices.contains(index), trackEndTexts.indices.contains(index) else { continue }
            let parsedStart = VideoTrimmer.parseTimecode(trackStartTexts[index]) ?? trackRanges[index].start
            let parsedEnd = VideoTrimmer.parseTimecode(trackEndTexts[index]) ?? trackRanges[index].end
            let upper = fileDuration ?? max(parsedEnd, Self.minimumTrackLength)
            let end = min(max(parsedEnd, Self.minimumTrackLength), upper)
            let start = max(min(max(parsedStart, 0), end - Self.minimumTrackLength), 0)
            trackRanges[index].start = start
            trackRanges[index].end = end
            trackStartTexts[index] = VideoTrimmer.formatTimecode(start)
            trackEndTexts[index] = VideoTrimmer.formatTimecode(end)
        }
    }

    func cancel() {
        guard isBusy else { return }
        cancelRequested = true
        status = String(localized: "Cancelling…")
        if let process = runningProcess { ProcessRunner.cancel(process) }
    }

    func split(ffmpeg: URL?, directory: OutputDirectory) {
        commitTrackFields()
        guard canSplit, let sourceFile, let ffmpeg else { return }
        let ranges = trackRanges
        let names = trackNames
        let extension_ = sourceFile.pathExtension
        let target = directory.url
        let capabilities = tagCapabilities
        let cover = coverEdit
        let artist = tagArtist
        let albumArtist = tagAlbumArtist
        let album = tagAlbum
        let year = tagYear
        let genre = tagGenre
        let comment = tagComment

        isSplitting = true
        cancelRequested = false
        currentTrackIndex = 0
        statusKind = .working
        statusDetails = nil
        status = String(localized: "Splitting…")

        Task { [weak self] in
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

            var completed = 0
            var tagFailures = 0
            for (index, range) in ranges.enumerated() {
                guard let self else { return }
                if cancelRequested {
                    finishCancelled(completed: completed)
                    return
                }
                currentTrackIndex = index + 1
                let typed = names.indices.contains(index)
                    ? names[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let fallback = "track_\(index + 1)"
                // The typed name stays the track's *title*; only the file name
                // has to obey file-name rules. "AC/DC - Thunderstruck" used to
                // be handed to ffmpeg as a path into a folder called "AC".
                let title = typed.isEmpty ? fallback : typed
                let stem = FileName.sanitizedStem(typed, fallback: fallback)
                status = String(
                    localized: "Cutting \(currentTrackIndex) of \(ranges.count): \(stem)",
                    comment: "Progress while splitting a track out of the source file"
                )

                let destination = ImageConverter.uniqueURL(directory: target, stem: stem, extension: extension_)
                let outcome: Result<Void, Error> = await Background.attempt {
                    try AudioSplitter.cut(
                        source: sourceFile, range: range, to: destination, ffmpeg: ffmpeg,
                        onStart: { process in DispatchQueue.main.async { self.runningProcess = process } }
                    )
                }

                switch outcome {
                case .success:
                    completed += 1

                    // Tagging is secondary to the cut itself: a failure here
                    // is counted, not fatal — the track that was actually
                    // requested (the audio) already exists and is kept.
                    if capabilities.supportsTags, !cancelRequested {
                        var tags = AudioTags()
                        tags.title = title
                        tags.track = "\(index + 1)/\(ranges.count)"
                        tags.artist = artist
                        tags.albumArtist = albumArtist
                        tags.album = album
                        tags.year = year
                        tags.genre = genre
                        tags.comment = comment

                        let tagOutcome: Result<Void, Error> = await Background.attempt {
                            try AudioTagEditor.write(
                                tags: tags, cover: cover, to: destination, ffmpeg: ffmpeg,
                                onStart: { process in DispatchQueue.main.async { self.runningProcess = process } }
                            )
                        }
                        // A cancel that lands mid-tagging leaves the cut track
                        // complete and merely untagged; the loop's own check
                        // ends the run at the top of the next round.
                        if case .failure(let error) = tagOutcome, !(error is CancellationError) {
                            tagFailures += 1
                        }
                    }
                case .failure(let error):
                    if error is CancellationError {
                        finishCancelled(completed: completed)
                    } else {
                        isSplitting = false
                        runningProcess = nil
                        status = error.localizedDescription
                        statusKind = .failure
                        statusDetails = (error as? ToolLogCarrying)?.toolLog
                    }
                    return
                }
            }

            guard let self else { return }
            if cancelRequested {
                finishCancelled(completed: completed)
                return
            }
            isSplitting = false
            runningProcess = nil
            if tagFailures > 0 {
                status = String(
                    localized: "Done. \(completed) tracks written, \(tagFailures) not tagged.",
                    comment: "Placeholders are track counts"
                )
            } else {
                status = String(localized: "Done. \(completed) tracks written.", comment: "Placeholder is a count of tracks")
            }
            statusKind = .success
        }
    }

    private func finishCancelled(completed: Int) {
        isSplitting = false
        runningProcess = nil
        status = String(
            localized: "Cancelled after \(completed) tracks. The finished ones are kept.",
            comment: "Placeholder is a count of tracks"
        )
        // Stopping on purpose is not a failure, so it is not red.
        statusKind = .idle
    }
}

struct TrackSplitterView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry
    @ObservedObject var session: TrackSplitterSession
    @StateObject private var directory = OutputDirectory(defaultsKey: "TrackSplitterOutputDir")

    @State private var isDropTargeted = false

    private var missingTools: [Tool] {
        tools.missing(from: AppSection.trackSplitter.requiredTools)
    }

    private var isReady: Bool { missingTools.isEmpty }
    private var ffmpeg: URL? { tools.status(for: .ffmpeg).url }

    private var canClear: Bool { !session.isBusy && session.sourceFile != nil }

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

                    if session.sourceFile != nil {
                        analysisStep
                        if session.hasAnalyzed {
                            analysisResult
                        }
                        if !session.trackRanges.isEmpty {
                            patternStep
                            tagBlock
                            trackListStep
                            OutputDirectoryRow(directory: directory, isEnabled: !session.isSplitting)
                            splitStep
                        }
                    }
                }
                .disabled(!isReady && !session.isBusy)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640)
    }

    // MARK: - Input

    @ViewBuilder
    private var fileRow: some View {
        HStack(spacing: 12) {
            FileRow(
                label: "Audio file",
                file: session.sourceFile,
                isEnabled: !session.isBusy,
                onChoose: { session.chooseFile(directory: directory) },
                onClear: { session.clear() }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            Spacer(minLength: 0)
            Button("Clear") { session.clear() }
                .disabled(!canClear)
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
                    Text(verbatim: "\(Int(session.thresholdDB)) dB")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $session.thresholdDB, in: -60...(-10), step: 1)
            }
            .frame(maxWidth: 320)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minimum silence duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: String(format: "%.1f s", session.minDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $session.minDuration, in: 0.1...5.0, step: 0.1)
            }
            .frame(maxWidth: 320)

            HStack(spacing: 12) {
                Button("Analyze") { session.analyze(ffmpeg: ffmpeg) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isBusy)
                if session.isAnalyzing {
                    Button("Cancel") { session.cancel() }
                    ProgressView(value: session.analysisProgress)
                        .frame(width: 140)
                }
                // The split row further down carries the status once there are
                // tracks to split. Until then that row does not exist, and an
                // analysis that failed used to fail without a word.
                if session.trackRanges.isEmpty {
                    StatusLine(text: session.status, kind: session.statusKind, details: session.statusDetails)
                }
            }
        }
        .disabled(session.isSplitting)
    }

    @ViewBuilder
    private var analysisResult: some View {
        if session.trackRanges.isEmpty {
            Label(
                "No silence found with these settings. Try a higher threshold or a shorter minimum duration.",
                systemImage: "waveform.slash"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(
                "Found \(session.trackRanges.count) tracks",
                comment: "Placeholder is a count of detected tracks"
            )
            .font(.callout.bold())
        }
    }

    // MARK: - Step 2: name pattern

    @ViewBuilder
    private var patternStep: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name pattern")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. Albumname_%n", text: $session.patternText)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .frame(maxWidth: 280)
                .onChange(of: session.patternText) { newValue in
                    guard !newValue.isEmpty else { return }
                    session.trackNames = AudioSplitter.applyPattern(newValue, trackCount: session.trackRanges.count)
                }
            // The two placeholders are literal and go in verbatim; what they
            // stand for is prose and is translated.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(verbatim: "%n").font(.caption2.monospaced())
                    Text("track number (01, 02, …)").font(.caption2)
                }
                HStack(spacing: 8) {
                    Text(verbatim: "%t").font(.caption2.monospaced())
                    Text("total number of tracks").font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        }
        .disabled(session.isSplitting)
    }

    // MARK: - Tags for all tracks

    @ViewBuilder
    private var tagBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags (applied to all tracks)")
                .font(.callout.bold())

            if !session.tagCapabilities.supportsTags {
                Text("This file format carries no metadata container — nothing can be read or written for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        tagField("Artist", $session.tagArtist, .artist)
                        tagField("Album Artist", $session.tagAlbumArtist, .albumArtist)
                        tagField("Album", $session.tagAlbum, .album)
                        tagField("Year", $session.tagYear, .year)
                        tagField("Genre", $session.tagGenre, .genre)
                        tagField("Comment", $session.tagComment, .comment)
                    }
                    .frame(maxWidth: 280)

                    coverPicker
                }
            }
        }
        .disabled(session.isSplitting)
    }

    @ViewBuilder
    private func tagField(_ label: LocalizedStringKey, _ binding: Binding<String>, _ field: TagField) -> some View {
        let unsupported = session.tagCapabilities.unsupportedFields.contains(field)
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(text: binding) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .disabled(unsupported)
            if unsupported {
                Text("Not supported for this format.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var coverPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { session.chooseCover() }) {
                ZStack {
                    if let coverImage = session.coverImage {
                        Image(nsImage: coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color(nsColor: .controlBackgroundColor)
                        Text("Click to add cover")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(6)
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
            .buttonStyle(.plain)
            .disabled(!session.tagCapabilities.supportsCoverArt)

            if session.coverImage != nil {
                Button("Remove") { session.removeCover() }
                    .disabled(!session.tagCapabilities.supportsCoverArt)
            }
            if !session.tagCapabilities.supportsCoverArt {
                Text("Not supported for this format.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 3: track list

    @ViewBuilder
    private var trackListStep: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Track names")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(session.trackNames.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(verbatim: "\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
                    TextField(text: Binding(
                        get: { session.trackNames.indices.contains(index) ? session.trackNames[index] : "" },
                        set: { if session.trackNames.indices.contains(index) { session.trackNames[index] = $0 } }
                    )) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(width: 140)

                    if index < session.trackRanges.count {
                        let range = session.trackRanges[index]
                        Text(verbatim: "[\(VideoTrimmer.formatTimecode(range.end - range.start))]")
                            .font(.callout.monospacedDigit())
                            .frame(minWidth: 90, alignment: .leading)

                        Text(verbatim: "(")
                            .foregroundStyle(.secondary)
                        TextField(text: Binding(
                            get: { session.trackStartTexts.indices.contains(index) ? session.trackStartTexts[index] : "" },
                            set: { if session.trackStartTexts.indices.contains(index) { session.trackStartTexts[index] = $0 } }
                        )) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospacedDigit())
                        .frame(width: 100)
                        .onSubmit { session.applyTrackStartText(index) }
                        .commitOnBlur { session.applyTrackStartText(index) }

                        Text(verbatim: "–")
                            .foregroundStyle(.secondary)
                        TextField(text: Binding(
                            get: { session.trackEndTexts.indices.contains(index) ? session.trackEndTexts[index] : "" },
                            set: { if session.trackEndTexts.indices.contains(index) { session.trackEndTexts[index] = $0 } }
                        )) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospacedDigit())
                        .frame(width: 100)
                        .onSubmit { session.applyTrackEndText(index) }
                        .commitOnBlur { session.applyTrackEndText(index) }
                        Text(verbatim: ")")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(session.isSplitting)
    }

    // MARK: - Step 4: split

    @ViewBuilder
    private var splitStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Split") { session.split(ffmpeg: ffmpeg, directory: directory) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canSplit)
                if session.isSplitting {
                    Button("Cancel") { session.cancel() }
                }
                StatusLine(text: session.status, kind: session.statusKind, details: session.statusDetails)
            }
            if session.isSplitting {
                ProgressView(value: Double(session.currentTrackIndex), total: Double(session.trackRanges.count))
                    .frame(maxWidth: 260)
            }
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isBusy, !providers.isEmpty else { return false }
        FileDrop.urls(from: providers) { urls in
            guard let url = urls.first(where: {
                AudioSplitter.acceptedExtensions.contains($0.pathExtension.lowercased())
            }) else { return }
            session.load(url, directory: directory)
        }
        return true
    }
}
