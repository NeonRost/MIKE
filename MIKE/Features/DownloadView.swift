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

/// Everything Download needs to survive being navigated away from and back
/// to. `RootView` holds exactly one of these per app launch (`@StateObject`),
/// the same reasoning as `ArticleExtractionSession`: `RootView`'s `detail`
/// switch builds a fresh `DownloadView` every time the section is
/// re-selected, which would otherwise drop all `@State` on the way out. An
/// in-flight download is unaffected by the view itself being torn down —
/// `start()`'s `Task` and `runningProcess` both live here — so navigating
/// away mid-download and back still shows real progress.
@MainActor
final class DownloadSession: ObservableObject {
    @Published var urlText = ""
    @Published var audioOnly = false
    @Published var audioFormat: AudioFormat = .mp3

    @Published var sectionOnly = false
    @Published var sectionStartText = "00:00:00"
    @Published var sectionEndText = ""
    @Published var isFetchingDuration = false
    @Published var durationText: String?
    @Published var durationError: String?

    @Published var useBestQuality = true
    @Published var isProbing = false
    @Published var probeError: String?
    @Published var probeResult: FormatProbeResult?
    /// The URL the current `probeResult`/`probeError` belongs to. Compared
    /// against the live text field so an edited URL is treated as stale
    /// rather than silently reusing a different video's answer.
    @Published var probedURL: String?
    @Published var selectedAudioBitrate: Int?
    @Published var selectedVideoHeight: Int?

    @Published var isRunning = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle
    /// Held so Cancel can stop the running yt-dlp. Never read by the view, so
    /// it does not need to be `@Published`.
    private var runningProcess: Process?

    var trimmedURL: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var probeIsStale: Bool { probedURL != trimmedURL }

    /// FLAC and WAV have no bitrate concept, so the whole "best available
    /// quality" question does not apply to them — the toggle and picker are
    /// hidden in favor of a hint (see the view), and neither `canDownload`
    /// nor `start()` should gate on probe state left over from a different,
    /// lossy format.
    var qualityGateApplies: Bool {
        !(audioOnly && audioFormat.isLossless) && !useBestQuality
    }

    var canDownload: Bool {
        guard !isRunning, !trimmedURL.isEmpty else { return false }
        guard qualityGateApplies else { return true }
        guard !isProbing, !probeIsStale, probeError == nil else { return false }
        if audioOnly {
            return !(probeResult?.audioBitrates.isEmpty ?? true)
        } else {
            return !(probeResult?.videoResolutions.isEmpty ?? true)
        }
    }

    func prefillFromClipboardIfEmpty() {
        guard !isRunning, urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let found = WebURL.fromClipboard() {
            urlText = found
        }
    }

    func cancel() {
        guard let process = runningProcess, process.isRunning else { return }
        status = String(localized: "Cancelling…")
        process.terminate()
    }

    /// Resets everything the user typed or received — the URL, every toggle
    /// and its dependent state, and the status line — back to a blank
    /// section. Not offered while a download is running; use Cancel first.
    func clear() {
        guard !isRunning else { return }
        urlText = ""
        audioOnly = false
        audioFormat = .mp3
        sectionOnly = false
        sectionStartText = "00:00:00"
        sectionEndText = ""
        isFetchingDuration = false
        durationText = nil
        durationError = nil
        useBestQuality = true
        isProbing = false
        probeError = nil
        probeResult = nil
        probedURL = nil
        selectedAudioBitrate = nil
        selectedVideoHeight = nil
        status = ""
        statusKind = .idle
    }

    func fetchDuration(ytDlp: URL?) {
        guard WebURL.isValid(trimmedURL) else {
            durationText = nil
            durationError = String(localized: "That is not a valid URL.")
            return
        }
        guard let ytDlp else {
            durationText = nil
            durationError = String(localized: "yt-dlp was not found.")
            return
        }

        let target = trimmedURL
        isFetchingDuration = true
        durationError = nil

        Task {
            let value = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: DownloadRunner.fetchDuration(urlString: target, ytDlp: ytDlp))
                }
            }
            // Same stale-guard as the quality probe: an answer for a URL the
            // user has since edited away from is not applied.
            guard trimmedURL == target else {
                isFetchingDuration = false
                return
            }
            isFetchingDuration = false
            if let value {
                let formatted = Self.formatDuration(value)
                durationText = formatted
                durationError = nil
                // A suggestion, not an overwrite: only offered while End is
                // still at its untouched default, so it never clobbers a
                // value the user already typed themselves.
                if sectionEndText.trimmingCharacters(in: .whitespaces).isEmpty {
                    sectionEndText = formatted
                }
            } else {
                durationText = nil
                durationError = String(localized: "Could not fetch the duration.")
            }
        }
    }

    /// "HH:MM:SS", whole seconds — unlike Trim Video's fields, a download
    /// section has no reason to show tenths, so this stays separate from
    /// `VideoTrimmer.formatTimecode` rather than sharing it.
    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    func startProbe(ytDlp: URL?) {
        guard WebURL.isValid(trimmedURL) else {
            probeError = String(localized: "That is not a valid URL.")
            probedURL = trimmedURL
            return
        }
        guard let ytDlp else {
            probeError = String(localized: "yt-dlp was not found.")
            probedURL = trimmedURL
            return
        }

        let target = trimmedURL
        isProbing = true
        probeError = nil

        Task {
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<FormatProbeResult, FormatProbeError>, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: FormatProbe.run(urlString: target, ytDlp: ytDlp))
                }
            }

            // The URL field may have changed while the probe was running —
            // that answer belongs to a different video, so it is dropped
            // rather than applied here. The stale-check button covers
            // re-probing the new URL.
            guard trimmedURL == target else {
                isProbing = false
                return
            }

            isProbing = false
            probedURL = target
            switch result {
            case .success(let value):
                probeResult = value
                probeError = nil
                selectedAudioBitrate = value.audioBitrates.first?.id
                selectedVideoHeight = value.videoResolutions.first?.id
            case .failure(let error):
                probeResult = nil
                probeError = error.localizedDescription
            }
        }
    }

    func start(ytDlp: URL?, ffmpeg: URL?, directory: OutputDirectory) {
        guard canDownload else { return }
        let trimmed = trimmedURL

        guard WebURL.isValid(trimmed) else {
            status = String(localized: "That is not a valid URL.")
            statusKind = .failure
            return
        }
        guard let ytDlp else {
            status = String(localized: "yt-dlp was not found.")
            statusKind = .failure
            return
        }
        let target = directory.url

        // Section times are validated here, at the moment Download is
        // pressed, not while typing — the button itself stays enabled purely
        // on URL validity, per the section's own design.
        var section: DownloadSection?
        if sectionOnly {
            guard let sectionStart = VideoTrimmer.parseTimecode(sectionStartText) else {
                status = String(localized: "That start time isn't valid. Use HH:MM:SS.")
                statusKind = .failure
                return
            }
            let endText = sectionEndText.trimmingCharacters(in: .whitespaces)
            var sectionEnd: TimeInterval?
            if !endText.isEmpty {
                guard let parsedEnd = VideoTrimmer.parseTimecode(endText) else {
                    status = String(localized: "That end time isn't valid. Use HH:MM:SS.")
                    statusKind = .failure
                    return
                }
                sectionEnd = parsedEnd
            }
            if let sectionEnd, sectionStart >= sectionEnd {
                status = String(localized: "The start time must be before the end time.")
                statusKind = .failure
                return
            }
            section = DownloadSection(
                start: sectionStartText.trimmingCharacters(in: .whitespaces),
                end: endText.isEmpty ? nil : endText
            )
        }

        let mode: DownloadMode
        let startStatus: String
        if audioOnly {
            let bitrate = (useBestQuality || audioFormat.isLossless) ? nil : selectedAudioBitrate
            mode = .audio(format: audioFormat, bitrate: bitrate)
            startStatus = String(localized: "Downloading…", comment: "Audio-only download starting")
        } else {
            let profile = DownloadProfile.forURL(trimmed)
            let maxHeight = useBestQuality ? nil : selectedVideoHeight
            mode = .video(profile, maxHeight: maxHeight)
            startStatus = String(localized: "Downloading (\(profile.name))…", comment: "Placeholder is the site profile, e.g. YouTube")
        }

        isRunning = true
        statusKind = .working
        status = startStatus

        Task {
            let outcome = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = DownloadRunner.run(
                        urlString: trimmed,
                        into: target,
                        mode: mode,
                        section: section,
                        ytDlp: ytDlp,
                        ffmpeg: ffmpeg,
                        onStart: { process in
                            DispatchQueue.main.async { self.runningProcess = process }
                        }
                    ) { progress in
                        DispatchQueue.main.async {
                            if let progress {
                                if case .video(let profile, _) = mode {
                                    self.status = String(localized: "Downloading (\(profile.name))… \(progress)", comment: "Profile name and percentage")
                                } else {
                                    self.status = String(localized: "Downloading… \(progress)", comment: "Audio-only download percentage")
                                }
                            } else {
                                self.status = String(localized: "Converting…", comment: "yt-dlp moved on to post-processing")
                            }
                        }
                    }
                    continuation.resume(returning: result)
                }
            }

            isRunning = false
            runningProcess = nil
            switch outcome {
            case .finished:
                status = String(localized: "Finished — saved to \(directory.displayPath)", comment: "Placeholder is a folder path")
                statusKind = .success
            case .cancelled:
                // Stopping on purpose is not a failure, so it is not red.
                status = String(localized: "Cancelled.")
                statusKind = .idle
            case .failed(let message):
                status = message
                statusKind = .failure
            }
        }
    }
}

struct DownloadView: View {
    let onOpenTools: () -> Void
    @ObservedObject var session: DownloadSession

    @EnvironmentObject private var tools: ToolRegistry
    @StateObject private var directory = OutputDirectory(defaultsKey: "DownloadOutputDir")

    private var missingTools: [Tool] {
        tools.missing(from: AppSection.download.requiredTools)
    }

    private var isReady: Bool { missingTools.isEmpty }

    private var canClear: Bool {
        !session.isRunning && !(session.urlText.isEmpty && !session.sectionOnly && !session.audioOnly)
    }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Download",
                    subtitle: "Paste a video URL. MIKE picks the right settings for YouTube, TikTok and Instagram automatically."
                )

                if !isReady {
                    RequirementBanner(missing: missingTools, onOpenTools: onOpenTools)
                }

                VStack(alignment: .leading, spacing: 16) {
                    OutputDirectoryRow(directory: directory, isEnabled: !session.isRunning)

                    TextField("https://…", text: $session.urlText)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .onSubmit { session.start(ytDlp: tools.status(for: .ytDlp).url, ffmpeg: tools.status(for: .ffmpeg).url, directory: directory) }

                    Toggle("Audio only", isOn: $session.audioOnly)

                    if session.audioOnly {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Format")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $session.audioFormat) {
                                    ForEach(AudioFormat.allCases) { format in
                                        Text(verbatim: format.rawValue).tag(format)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 100)
                            }
                        }
                    }

                    Toggle("Download section only", isOn: $session.sectionOnly)

                    if session.sectionOnly {
                        sectionFields
                    }

                    if session.audioOnly && session.audioFormat.isLossless {
                        Text("FLAC and WAV are lossless — quality selection has no effect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Best available quality", isOn: $session.useBestQuality)
                            .onChange(of: session.useBestQuality) { newValue in
                                if !newValue, session.probeIsStale, !session.isProbing, WebURL.isValid(session.trimmedURL) {
                                    session.startProbe(ytDlp: tools.status(for: .ytDlp).url)
                                }
                            }

                        if !session.useBestQuality {
                            qualitySection
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Download") {
                            session.start(ytDlp: tools.status(for: .ytDlp).url, ffmpeg: tools.status(for: .ffmpeg).url, directory: directory)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canDownload)
                        if session.isRunning {
                            Button("Cancel") { session.cancel() }
                        }
                        Button("Clear") { session.clear() }
                            .disabled(!canClear)
                        StatusLine(text: session.status, kind: session.statusKind)
                    }
                }
                .disabled(!isReady)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { session.prefillFromClipboardIfEmpty() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            session.prefillFromClipboardIfEmpty()
        }
    }

    // MARK: - Section download

    @ViewBuilder
    private var sectionFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(text: $session.sectionStartText) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("End")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(text: $session.sectionEndText) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Button("Fetch duration") { session.fetchDuration(ytDlp: tools.status(for: .ytDlp).url) }
                    .disabled(!WebURL.isValid(session.trimmedURL) || session.isFetchingDuration)
            }

            if session.isFetchingDuration {
                ProgressView()
                    .controlSize(.small)
            } else if let durationText = session.durationText {
                Text("Duration: \(durationText)", comment: "Placeholder is a timecode, not translated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let durationError = session.durationError {
                Text(durationError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Quality probe

    @ViewBuilder
    private var qualitySection: some View {
        if session.isProbing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking available quality…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if session.probeIsStale {
            if session.trimmedURL.isEmpty {
                Text("Enter a URL first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Check available quality") { session.startProbe(ytDlp: tools.status(for: .ytDlp).url) }
            }
        } else if let probeError = session.probeError {
            VStack(alignment: .leading, spacing: 4) {
                Text(probeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Check again") { session.startProbe(ytDlp: tools.status(for: .ytDlp).url) }
            }
        } else if let probeResult = session.probeResult {
            optionPicker(for: probeResult)
        }
    }

    @ViewBuilder
    private func optionPicker(for result: FormatProbeResult) -> some View {
        if session.audioOnly {
            if result.audioBitrates.isEmpty {
                Text("MIKE couldn't determine specific options for this URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $session.selectedAudioBitrate) {
                    ForEach(result.audioBitrates) { option in
                        Text(verbatim: option.label).tag(Optional(option.id))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        } else {
            if result.videoResolutions.isEmpty {
                Text("MIKE couldn't determine specific options for this URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $session.selectedVideoHeight) {
                    ForEach(result.videoResolutions) { option in
                        Text(verbatim: option.label).tag(Optional(option.id))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }
}
