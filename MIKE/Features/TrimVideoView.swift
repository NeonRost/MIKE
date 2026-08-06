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

import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// A bare `AVPlayerView` with the built-in transport bar turned off — Trim
/// Video draws its own play/pause button and timeline with start/end
/// markers, so the native controls would only duplicate (and fight with)
/// that.
private struct AVPlayerContainer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// Survives navigating away from and back to Trim Video — see
/// `ArticleExtractionSession` for why this is needed at all. The `AVPlayer`
/// itself lives here too, so scrubbing position and the loaded asset are not
/// rebuilt on return; the view pauses it on `onDisappear` (see
/// `pauseForNavigation()`) so audio does not keep playing while a different
/// section is shown.
@MainActor
final class TrimVideoSession: ObservableObject {
    @Published var sourceFile: URL?
    @Published var player: AVPlayer?
    private var timeObserverToken: Any?
    @Published var isPlaying = false
    @Published var isCheckingPlayability = false
    @Published var isPlayable = false

    @Published var duration: TimeInterval = 0
    @Published var currentTime: TimeInterval = 0
    @Published var startTime: TimeInterval = 0
    @Published var endTime: TimeInterval = 0
    @Published var startText = "00:00:00.0"
    @Published var endText = "00:00:00.0"

    /// The video's *displayed* pixel size — natural size with the track's
    /// own rotation already applied — so the crop overlay lines up with what
    /// the preview actually shows, not the raw sensor frame. `nil` until the
    /// track has loaded, or if it never can (crop stays unavailable then,
    /// same as the preview itself).
    @Published var displaySize: CGSize?
    @Published var cropEnabled = false
    /// Always in `displaySize` coordinates — see `VideoTrimmer.cropArguments`
    /// for why that is also exactly the space ffmpeg's own `-vf crop` needs.
    @Published var cropRect: CGRect = .zero
    static let minCropSize: CGFloat = 10

    @Published var isRunning = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle
    /// Held so Cancel can stop the running ffmpeg.
    private var runningProcess: Process?

    /// The minimum clip length the spec calls for, and the minimum gap kept
    /// between the two markers so neither can be dragged or typed past the
    /// other.
    static let minimumClipLength: TimeInterval = 0.1

    var isRangeValid: Bool {
        startTime >= 0
            && endTime <= duration
            && endTime - startTime >= Self.minimumClipLength
    }

    var canTrim: Bool {
        sourceFile != nil && !isRunning && duration > 0 && isRangeValid
    }

    // MARK: - Loading

    func load(_ url: URL, ffmpeg: URL?, directory: OutputDirectory) {
        guard let ffmpeg else { return }

        stopObservingPlayback()
        sourceFile = url
        player = nil
        isPlayable = false
        duration = 0
        currentTime = 0
        startTime = 0
        endTime = 0
        startText = "00:00:00.0"
        endText = "00:00:00.0"
        displaySize = nil
        cropEnabled = false
        cropRect = .zero
        status = ""
        statusKind = .idle
        // Matches Combine Videos' folder mode: writes next to the source by
        // default, but stays redirectable.
        directory.set(url.deletingLastPathComponent())

        // Duration always comes from ffmpeg, never from AVFoundation — see
        // VideoTrimmer.duration's doc comment for why: AVFoundation cannot
        // even read a duration out of a format it cannot open, such as AVI.
        Task { [weak self] in
            let value = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: VideoTrimmer.duration(of: url, ffmpeg: ffmpeg))
                }
            }
            guard let self, sourceFile == url else { return }
            guard let value else {
                status = VideoTrimError.cannotReadDuration.localizedDescription
                statusKind = .failure
                return
            }
            duration = value
            startTime = 0
            endTime = value
        }

        // Playability and the actual player are independent of the ffmpeg
        // duration probe above — verified directly that AVFoundation and
        // ffmpeg simply disagree about which formats they can open at all.
        isCheckingPlayability = true
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard let self, sourceFile == url else { return }
            isCheckingPlayability = false
            isPlayable = playable
            guard playable else { return }

            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = newPlayer
            observePlayback(newPlayer)

            // The *displayed* size, not the raw encoded frame size: applying
            // the track's own transform to its naturalSize is the standard,
            // sign-agnostic way to get a track's on-screen bounding size
            // regardless of rotation — the same computation AVPlayerLayer
            // itself relies on to show the video upright. This sidesteps
            // ever having to work out clockwise/counterclockwise by hand,
            // which is exactly the kind of sign convention Quick Edit's own
            // rotation code got backwards once before.
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            guard let naturalSize = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform)
            else { return }
            guard self.sourceFile == url else { return }
            let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let size = CGSize(width: abs(rect.width), height: abs(rect.height))
            guard size.width > 0, size.height > 0 else { return }
            self.displaySize = size
            self.cropRect = CGRect(origin: .zero, size: size)
        }
    }

    func resetCrop() {
        guard let displaySize else { return }
        cropRect = CGRect(origin: .zero, size: displaySize)
    }

    func clear() {
        guard !isRunning else { return }
        stopObservingPlayback()
        sourceFile = nil
        player = nil
        isPlayable = false
        isCheckingPlayability = false
        duration = 0
        currentTime = 0
        startTime = 0
        endTime = 0
        startText = "00:00:00.0"
        endText = "00:00:00.0"
        displaySize = nil
        cropEnabled = false
        cropRect = .zero
        status = ""
        statusKind = .idle
    }

    // MARK: - Playback

    private func observePlayback(_ player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = time.seconds
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
    }

    private func stopObservingPlayback() {
        if let player, let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        player?.pause()
        isPlaying = false
    }

    /// Called from the view's `onDisappear` — pauses playback without tearing
    /// down the player, timeline position, or any other state, so returning
    /// to the section resumes exactly where it was left, just not playing.
    func pauseForNavigation() {
        player?.pause()
        isPlaying = false
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Field sync

    /// Unparsable text is reverted to the last valid value rather than
    /// rejected outright — there is no partial-input state worth preserving
    /// for a structured timecode field.
    func applyStartText() {
        guard let parsed = VideoTrimmer.parseTimecode(startText) else {
            startText = VideoTrimmer.formatTimecode(startTime)
            return
        }
        startTime = min(max(parsed, 0), endTime - Self.minimumClipLength)
        startText = VideoTrimmer.formatTimecode(startTime)
        seek(to: startTime)
    }

    func applyEndText() {
        guard let parsed = VideoTrimmer.parseTimecode(endText) else {
            endText = VideoTrimmer.formatTimecode(endTime)
            return
        }
        endTime = max(min(parsed, duration), startTime + Self.minimumClipLength)
        endText = VideoTrimmer.formatTimecode(endTime)
        seek(to: endTime)
    }

    // MARK: - Trim

    func cancel() {
        guard let process = runningProcess, process.isRunning else { return }
        status = String(localized: "Cancelling…")
        process.terminate()
    }

    func trim(ffmpeg: URL?, directory: OutputDirectory) {
        guard canTrim, let sourceFile, let ffmpeg else { return }

        let start = startTime
        let end = endTime
        let target = directory.url
        let crop = (cropEnabled && cropRect.width > 0 && cropRect.height > 0) ? cropRect : nil

        isRunning = true
        statusKind = .working
        status = String(localized: "Trimming…")

        Task { [weak self] in
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<URL, Error>, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let output = try VideoTrimmer.trim(
                            input: sourceFile,
                            start: start,
                            end: end,
                            cropRect: crop,
                            into: target,
                            ffmpeg: ffmpeg,
                            onStart: { process in
                                DispatchQueue.main.async { self?.runningProcess = process }
                            }
                        ) { progress in
                            guard let progress else { return }
                            DispatchQueue.main.async {
                                self?.status = String(
                                    localized: "Trimming… \(Int(progress * 100))%",
                                    comment: "Percentage while trimming"
                                )
                            }
                        }
                        continuation.resume(returning: .success(output))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }

            guard let self else { return }
            isRunning = false
            runningProcess = nil
            switch result {
            case .success(let output):
                status = String(localized: "Finished: \(output.lastPathComponent)", comment: "Placeholder is the written file name")
                statusKind = .success
            case .failure(let error):
                // Stopping on purpose is not a failure, so it is not red.
                let cancelled = (error as? VideoTrimError).map {
                    if case .cancelled = $0 { return true } else { return false }
                } ?? false
                status = error.localizedDescription
                statusKind = cancelled ? .idle : .failure
            }
        }
    }
}

struct TrimVideoView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry
    @ObservedObject var session: TrimVideoSession
    @StateObject private var directory = OutputDirectory(defaultsKey: "TrimVideoOutputDir")

    private var missingTools: [Tool] {
        tools.missing(from: AppSection.trimVideo.requiredTools)
    }

    private var isReady: Bool { missingTools.isEmpty }
    private var ffmpeg: URL? { tools.status(for: .ffmpeg).url }

    private var canClear: Bool { !session.isRunning && session.sourceFile != nil }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Trim Video",
                    subtitle: "Cuts a clip out of a video without re-encoding, so there is no quality loss. Cropping the frame is also possible, but re-encodes, since a crop cannot be a plain stream copy."
                )

                if !isReady {
                    RequirementBanner(missing: missingTools, onOpenTools: onOpenTools)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        FileRow(
                            label: "Video file",
                            file: session.sourceFile,
                            isEnabled: !session.isRunning,
                            onChoose: chooseFile,
                            onClear: { session.clear() }
                        )
                        Spacer(minLength: 0)
                        Button("Clear") { session.clear() }
                            .disabled(!canClear)
                    }

                    if session.sourceFile != nil {
                        previewArea
                        cropSection
                        timelineSection
                        fieldsSection

                        Text("Trim points snap to keyframes — the result may be off by a fraction of a second.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if session.cropEnabled {
                            Text("Cropping re-encodes the video (H.264/AAC in MP4), so trimming alone is no longer lossless while it is on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        OutputDirectoryRow(directory: directory, isEnabled: !session.isRunning)

                        HStack(spacing: 12) {
                            Button("Trim") { session.trim(ffmpeg: ffmpeg, directory: directory) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!session.canTrim)
                            if session.isRunning {
                                Button("Cancel") { session.cancel() }
                            }
                            StatusLine(text: session.status, kind: session.statusKind)
                        }
                    }
                }
                .disabled(!isReady)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 560)
        .onDisappear { session.pauseForNavigation() }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            if let player = session.player {
                AVPlayerContainer(player: player)
                if session.cropEnabled, let displaySize = session.displaySize {
                    CropOverlay(
                        displaySize: displaySize,
                        cropRect: $session.cropRect,
                        minCropSize: TrimVideoSession.minCropSize,
                        isEnabled: !session.isRunning
                    )
                }
            } else if session.isCheckingPlayability {
                ProgressView()
            } else {
                previewUnavailableHint
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))

        Button {
            session.togglePlayback()
        } label: {
            Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 20)
        }
        .disabled(session.player == nil)
    }

    // MARK: - Crop

    @ViewBuilder
    private var cropSection: some View {
        if session.player != nil, let displaySize = session.displaySize {
            HStack(spacing: 12) {
                Toggle("Crop", isOn: $session.cropEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(session.isRunning)

                if session.cropEnabled {
                    Text(
                        "\(Int(session.cropRect.width.rounded()))×\(Int(session.cropRect.height.rounded())) of \(Int(displaySize.width))×\(Int(displaySize.height))",
                        comment: "Placeholders: crop width, crop height, full video width, full video height, all in pixels"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button("Reset Crop") { session.resetCrop() }
                        .disabled(session.isRunning)
                }
            }
        }
    }

    private var previewUnavailableHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No preview for this format. Type the start and end times directly — trimming still works.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .padding(20)
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineSection: some View {
        TrimTimeline(
            duration: session.duration,
            startTime: $session.startTime,
            endTime: $session.endTime,
            currentTime: session.currentTime,
            isEnabled: !session.isRunning && session.duration > 0,
            minimumClipLength: TrimVideoSession.minimumClipLength,
            onSeek: { session.seek(to: $0) }
        )
        .frame(height: 28)
        .onChange(of: session.startTime) { _ in session.startText = VideoTrimmer.formatTimecode(session.startTime) }
        .onChange(of: session.endTime) { _ in session.endText = VideoTrimmer.formatTimecode(session.endTime) }
    }

    @ViewBuilder
    private var fieldsSection: some View {
        HStack(spacing: 24) {
            timeField(label: "Start", text: $session.startText, apply: { session.applyStartText() })
            timeField(label: "End", text: $session.endText, apply: { session.applyEndText() })

            VStack(alignment: .leading, spacing: 4) {
                Text("Duration: \(VideoTrimmer.formatTimecode(session.duration))", comment: "Placeholder is a timecode, not translated")
                Text("Clip length: \(VideoTrimmer.formatTimecode(max(session.endTime - session.startTime, 0)))", comment: "Placeholder is a timecode, not translated")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func timeField(label: LocalizedStringKey, text: Binding<String>, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(text: text) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .disabled(session.isRunning)
                .onSubmit(apply)
        }
    }

    // MARK: - Loading

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = VideoTrimmer.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        session.load(chosen, ffmpeg: ffmpeg, directory: directory)
    }
}

// MARK: - Timeline with draggable markers

/// The horizontal scrubber: a track spanning the whole duration, a thin
/// playhead at the current playback position, and two draggable markers
/// (green start, red end) with the selected range highlighted between them.
/// Drag position is read from a named coordinate space spanning the full
/// track width rather than each marker's own tiny local frame — the marker
/// a gesture is attached to is not the same thing as the range it is allowed
/// to move across.
private struct TrimTimeline: View {
    let duration: TimeInterval
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval
    let currentTime: TimeInterval
    let isEnabled: Bool
    let minimumClipLength: TimeInterval
    let onSeek: (TimeInterval) -> Void

    private let markerDiameter: CGFloat = 14
    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: trackHeight)

                let startX = x(for: startTime, width: width)
                let endX = x(for: endTime, width: width)

                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(endX - startX, 0), height: trackHeight)
                    .offset(x: startX)

                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2, height: trackHeight + 10)
                    .offset(x: x(for: currentTime, width: width) - 1, y: -2)

                marker(color: .green, x: startX)
                    .gesture(dragGesture(width: width, isStart: true))

                marker(color: .red, x: endX)
                    .gesture(dragGesture(width: width, isStart: false))
            }
            .coordinateSpace(name: "timeline")
        }
    }

    private func fraction(_ time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1))
    }

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        fraction(time) * width
    }

    private func marker(color: Color, x: CGFloat) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .frame(width: markerDiameter, height: markerDiameter)
            .contentShape(Circle().inset(by: -8))
            .offset(x: x - markerDiameter / 2)
    }

    private func dragGesture(width: CGFloat, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { value in
                guard isEnabled, duration > 0, width > 0 else { return }
                let time = TimeInterval(min(max(value.location.x / width, 0), 1)) * duration
                if isStart {
                    startTime = min(max(time, 0), endTime - minimumClipLength)
                    onSeek(startTime)
                } else {
                    endTime = max(min(time, duration), startTime + minimumClipLength)
                    onSeek(endTime)
                }
            }
    }
}

// MARK: - Crop overlay

/// The draggable crop frame, layered on top of `AVPlayerContainer`. Unlike
/// Quick Edit's `CropCanvas` this draws no image of its own — the player
/// behind it already renders the video — so it only needs the same
/// letterbox math to line its frame and handles up with where
/// `AVPlayerView`'s default `.resizeAspect` gravity actually draws the
/// picture inside its bounds. `cropRect`/`displaySize` are both in the
/// video's displayed (post-rotation) pixel space — see
/// `TrimVideoSession.displaySize`'s doc comment.
private struct CropOverlay: View {
    let displaySize: CGSize
    @Binding var cropRect: CGRect
    let minCropSize: CGFloat
    let isEnabled: Bool

    @State private var dragStartRect: CGRect?

    private let handleDiameter: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let scale = displayScale(for: geo.size)
            let renderedSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
            let origin = CGPoint(x: (geo.size.width - renderedSize.width) / 2, y: (geo.size.height - renderedSize.height) / 2)
            let displayRect = CGRect(
                x: origin.x + cropRect.origin.x * scale,
                y: origin.y + cropRect.origin.y * scale,
                width: cropRect.width * scale,
                height: cropRect.height * scale
            )

            ZStack(alignment: .topLeading) {
                // Even-odd fill: the outer rect minus the crop rect, dimmed —
                // darkens everything outside the frame, leaves the inside
                // clear, so the video keeps showing through unobstructed.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRect(displayRect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: max(displayRect.width, 0), height: max(displayRect.height, 0))
                    .position(x: displayRect.midX, y: displayRect.midY)
                    .contentShape(Rectangle())
                    .gesture(isEnabled ? moveGesture(scale: scale) : nil)

                if isEnabled {
                    ForEach(Array(CropHandle.allCases.enumerated()), id: \.offset) { _, handle in
                        let position = CropGeometry.handlePosition(handle, in: displayRect)
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                            .frame(width: handleDiameter, height: handleDiameter)
                            .contentShape(Circle().inset(by: -8))
                            .position(position)
                            .gesture(dragGesture(for: handle, scale: scale))
                    }
                }
            }
            .clipped()
        }
    }

    private func displayScale(for size: CGSize) -> CGFloat {
        guard displaySize.width > 0, displaySize.height > 0, size.width > 0, size.height > 0 else { return 1 }
        return min(size.width / displaySize.width, size.height / displaySize.height)
    }

    private func dragGesture(for handle: CropHandle, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = cropRect }
                guard let start = dragStartRect else { return }
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                cropRect = CropGeometry.applyHandleDrag(handle, delta: delta, start: start, bounds: displaySize, minSize: minCropSize)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    private func moveGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = cropRect }
                guard let start = dragStartRect else { return }
                let delta = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                var rect = start
                rect.origin.x += delta.width
                rect.origin.y += delta.height
                cropRect = CropGeometry.clamp(rect, to: displaySize, minSize: minCropSize)
            }
            .onEnded { _ in dragStartRect = nil }
    }
}
