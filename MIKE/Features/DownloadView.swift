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

struct DownloadView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry
    @StateObject private var directory = OutputDirectory(defaultsKey: "DownloadOutputDir")

    @State private var urlText = ""
    @State private var audioOnly = false
    @State private var audioFormat: AudioFormat = .mp3

    // "Best available" (checked, default) is exactly today's unconstrained
    // yt-dlp behavior — no probe, no promises. Unchecking it is what asks
    // yt-dlp what this specific URL actually offers, so the picker that then
    // appears only ever lists real options, never a number MIKE invented.
    @State private var useBestQuality = true
    @State private var isProbing = false
    @State private var probeError: String?
    @State private var probeResult: FormatProbeResult?
    /// The URL the current `probeResult`/`probeError` belongs to. Compared
    /// against the live text field so an edited URL is treated as stale
    /// rather than silently reusing a different video's answer.
    @State private var probedURL: String?
    @State private var selectedAudioBitrate: Int?
    @State private var selectedVideoHeight: Int?

    @State private var isRunning = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle
    /// Held so Cancel can stop the running yt-dlp.
    @State private var runningProcess: Process?

    private var missingTools: [Tool] {
        tools.missing(from: AppSection.download.requiredTools)
    }

    private var isReady: Bool { missingTools.isEmpty }

    private var trimmedURL: String { urlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var probeIsStale: Bool { probedURL != trimmedURL }

    /// FLAC and WAV have no bitrate concept, so the whole "best available
    /// quality" question does not apply to them — the toggle and picker are
    /// hidden in favor of a hint (see `body`), and neither `canDownload` nor
    /// `start()` should gate on probe state left over from a different,
    /// lossy format.
    private var qualityGateApplies: Bool {
        !(audioOnly && audioFormat.isLossless) && !useBestQuality
    }

    private var canDownload: Bool {
        guard !isRunning, !trimmedURL.isEmpty else { return false }
        guard qualityGateApplies else { return true }
        guard !isProbing, !probeIsStale, probeError == nil else { return false }
        if audioOnly {
            return !(probeResult?.audioBitrates.isEmpty ?? true)
        } else {
            return !(probeResult?.videoResolutions.isEmpty ?? true)
        }
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
                    OutputDirectoryRow(directory: directory, isEnabled: !isRunning)

                    TextField("https://…", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .onSubmit { start() }

                    Toggle("Audio only", isOn: $audioOnly)

                    if audioOnly {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Format")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $audioFormat) {
                                    ForEach(AudioFormat.allCases) { format in
                                        Text(verbatim: format.rawValue).tag(format)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 100)
                            }
                        }
                    }

                    if audioOnly && audioFormat.isLossless {
                        Text("FLAC and WAV are lossless — quality selection has no effect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Best available quality", isOn: $useBestQuality)
                            .onChange(of: useBestQuality) { newValue in
                                if !newValue, probeIsStale, !isProbing, WebURL.isValid(trimmedURL) {
                                    startProbe()
                                }
                            }

                        if !useBestQuality {
                            qualitySection
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Download") { start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canDownload)
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
        .onAppear { prefillFromClipboardIfEmpty() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            prefillFromClipboardIfEmpty()
        }
    }

    // MARK: - Quality probe

    @ViewBuilder
    private var qualitySection: some View {
        if isProbing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking available quality…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if probeIsStale {
            if trimmedURL.isEmpty {
                Text("Enter a URL first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Check available quality") { startProbe() }
            }
        } else if let probeError {
            VStack(alignment: .leading, spacing: 4) {
                Text(probeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Check again") { startProbe() }
            }
        } else if let probeResult {
            optionPicker(for: probeResult)
        }
    }

    @ViewBuilder
    private func optionPicker(for result: FormatProbeResult) -> some View {
        if audioOnly {
            if result.audioBitrates.isEmpty {
                Text("MIKE couldn't determine specific options for this URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selectedAudioBitrate) {
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
                Picker("", selection: $selectedVideoHeight) {
                    ForEach(result.videoResolutions) { option in
                        Text(verbatim: option.label).tag(Optional(option.id))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    private func startProbe() {
        guard WebURL.isValid(trimmedURL) else {
            probeError = String(localized: "That is not a valid URL.")
            probedURL = trimmedURL
            return
        }
        guard let ytDlp = tools.status(for: .ytDlp).url else {
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

    // MARK: - Actions

    private func prefillFromClipboardIfEmpty() {
        guard !isRunning, urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let found = WebURL.fromClipboard() {
            urlText = found
        }
    }

    private func cancel() {
        guard let process = runningProcess, process.isRunning else { return }
        status = String(localized: "Cancelling…")
        process.terminate()
    }

    private func start() {
        guard canDownload, isReady else { return }
        let trimmed = trimmedURL

        guard WebURL.isValid(trimmed) else {
            status = String(localized: "That is not a valid URL.")
            statusKind = .failure
            return
        }
        guard let ytDlp = tools.status(for: .ytDlp).url else {
            status = String(localized: "yt-dlp was not found.")
            statusKind = .failure
            return
        }
        let ffmpeg = tools.status(for: .ffmpeg).url
        let target = directory.url

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
                        ytDlp: ytDlp,
                        ffmpeg: ffmpeg,
                        onStart: { process in
                            DispatchQueue.main.async { runningProcess = process }
                        }
                    ) { progress in
                        DispatchQueue.main.async {
                            if let progress {
                                if case .video(let profile, _) = mode {
                                    status = String(localized: "Downloading (\(profile.name))… \(progress)", comment: "Profile name and percentage")
                                } else {
                                    status = String(localized: "Downloading… \(progress)", comment: "Audio-only download percentage")
                                }
                            } else {
                                status = String(localized: "Converting…", comment: "yt-dlp moved on to post-processing")
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
