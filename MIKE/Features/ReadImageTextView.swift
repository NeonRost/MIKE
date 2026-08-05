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

/// Survives navigating away from and back to Read Image Text — see
/// `ArticleExtractionSession` for why this is needed at all. `task` lives
/// here too, so a batch still finishes and lands its result even if the
/// section is not on screen when it completes.
@MainActor
final class ReadImageTextSession: ObservableObject {
    @Published var pickedFiles: [URL] = []
    @Published var output = ""
    @Published var isRunning = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    /// 0 while a single clipboard image is being read — that path shows only
    /// the spinner, not the N-of-M bar.
    @Published var currentIndex = 0
    @Published var totalCount = 0

    private var task: Task<Void, Never>?

    func clear() {
        guard !isRunning else { return }
        pickedFiles = []
        output = ""
        status = ""
        statusKind = .idle
    }

    func pasteFromClipboard() {
        guard !isRunning else { return }
        guard let data = ClipboardImage.data() else {
            status = String(localized: "No image in the clipboard.")
            statusKind = .idle
            return
        }

        isRunning = true
        statusKind = .working
        totalCount = 0
        status = String(localized: "Recognizing…")

        task = Task {
            let outcome: Result<String, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let image = try ImageConverter.load(from: data)
                        let orientation = TextRecognizer.orientation(from: data)
                        let text = try TextRecognizer.recognizeText(in: image, orientation: orientation)
                        continuation.resume(returning: .success(text))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }

            isRunning = false
            switch outcome {
            case .success(let text):
                output = text
                status = String(localized: "Done.")
                statusKind = .success
            case .failure(let error):
                status = error.localizedDescription
                statusKind = .failure
            }
        }
    }

    func startBatch() {
        guard !isRunning, !pickedFiles.isEmpty else { return }
        let files = pickedFiles

        isRunning = true
        statusKind = .working
        totalCount = files.count
        currentIndex = 0
        output = ""
        status = String(localized: "Recognizing…")

        task = Task {
            var sections: [String] = []
            var skipped: [String] = []

            for (index, url) in files.enumerated() {
                if Task.isCancelled { break }
                currentIndex = index + 1
                status = String(
                    localized: "Recognizing \(currentIndex) of \(totalCount): \(url.lastPathComponent)",
                    comment: "Progress while reading text from a batch of images"
                )

                let outcome: Result<String, Error> = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let image = try ImageConverter.load(from: url)
                            let orientation = TextRecognizer.orientation(from: url)
                            let text = try TextRecognizer.recognizeText(in: image, orientation: orientation)
                            continuation.resume(returning: .success(text))
                        } catch {
                            continuation.resume(returning: .failure(error))
                        }
                    }
                }

                switch outcome {
                case .success(let text):
                    // A heading only earns its keep once there is more than one
                    // section — a single file's result should read exactly like
                    // Extract Article's: plain text, no added structure.
                    sections.append(files.count > 1 ? url.lastPathComponent + "\n\n" + text : text)
                case .failure:
                    skipped.append(url.lastPathComponent)
                }
                output = sections.joined(separator: "\n\n---\n\n")
            }

            let wasCancelled = Task.isCancelled
            isRunning = false
            finish(processed: sections.count, skipped: skipped, cancelled: wasCancelled)
        }
    }

    func stop() {
        task?.cancel()
    }

    private func finish(processed: Int, skipped: [String], cancelled: Bool) {
        let skippedList = skipped.isEmpty ? nil : ListFormatter.localizedString(byJoining: skipped)

        if cancelled {
            if processed == 0 {
                status = String(localized: "Cancelled.")
                statusKind = .idle
            } else {
                status = String(
                    localized: "Cancelled after \(processed) files. What was already recognized is kept.",
                    comment: "Placeholder is a count of files"
                )
                statusKind = .idle
            }
            return
        }

        if processed == 0 {
            status = String(localized: "No text was found in any of the files.")
            statusKind = .failure
            return
        }

        var message = String(
            localized: "Done. \(processed) files recognized.",
            comment: "Placeholder is a count of files"
        )
        if let skippedList {
            message += " " + String(
                localized: "Skipped (no readable image or no text found): \(skippedList)",
                comment: "Placeholder is a comma-separated list of file names"
            )
        }
        status = message
        statusKind = .success
    }

    func save(suggestedName: String, contentType: UTType, writer: (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.prompt = String(localized: "Save", comment: "Confirm button in the save dialog")
        guard panel.runModal() == .OK, let target = panel.url else { return }

        do {
            try writer(target)
            status = String(
                localized: "Saved: \(target.lastPathComponent)",
                comment: "Placeholder is the written file name"
            )
            statusKind = .success
        } catch {
            status = error.localizedDescription
            statusKind = .failure
        }
    }
}

struct ReadImageTextView: View {
    @ObservedObject var session: ReadImageTextSession

    @State private var isDropTargeted = false

    private var canClear: Bool {
        !session.isRunning && !(session.pickedFiles.isEmpty && session.output.isEmpty)
    }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Read Image Text",
                    subtitle: "Recognizes text in images with on-device text recognition. Needs no external tools."
                )

                fileSection
                clipboardRow
                runRow
                resultSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Input

    @ViewBuilder
    private var fileSection: some View {
        FileListEditor(
            files: $session.pickedFiles,
            allowedExtensions: TextRecognizer.acceptedExtensions,
            emptyMessage: "No images selected. Add some, or drag them in — text is read in the order they're listed.",
            addTitle: "Add Images…",
            isEnabled: !session.isRunning
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var clipboardRow: some View {
        HStack(spacing: 8) {
            Button("Paste from Clipboard") { session.pasteFromClipboard() }
                .disabled(session.isRunning)
            Text("Reads an image straight from the clipboard — after Cmd-Shift-4, for instance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var runRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Recognize Text") { session.startBatch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isRunning || session.pickedFiles.isEmpty)
                if session.isRunning {
                    Button("Cancel") { session.stop() }
                }
                Button("Clear") { session.clear() }
                    .disabled(!canClear)
                StatusLine(text: session.status, kind: session.statusKind)
            }
            if session.isRunning, session.totalCount > 1 {
                ProgressView(value: Double(session.currentIndex), total: Double(session.totalCount))
                    .frame(maxWidth: 260)
            }
        }
    }

    // MARK: - Output

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Result")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Editable on purpose, like Extract Article: the recognized text
            // can be corrected before it is copied or saved. Disabled while a
            // batch is running so progressive updates never clash with an
            // in-progress edit.
            TextEditor(text: $session.output)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 280)
                .disabled(session.isRunning)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .overlay(alignment: .topLeading) {
                    if session.output.isEmpty {
                        Text("Recognized text appears here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 12) {
                Button("Copy") { WebURL.copyToClipboard(session.output) }
                    .disabled(session.output.isEmpty)
                Button("Save as TXT") { saveTXT() }
                    .disabled(session.output.isEmpty)
                Button("Save as Markdown") { saveMarkdown() }
                    .disabled(session.output.isEmpty)
                Button("Save as RTF") { saveRTF() }
                    .disabled(session.output.isEmpty)
            }
            Text("Formatting such as bold or italic is not detected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isRunning, !providers.isEmpty else { return false }

        let group = DispatchGroup()
        // Collected on a lock, not `pickedFiles` directly: `loadItem`'s
        // completion handlers arrive on an arbitrary queue, never the main
        // actor.
        let collected = Locked<[URL]>([])

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url, TextRecognizer.acceptedExtensions.contains(url.pathExtension.lowercased())
                else { return }
                collected.withValue { $0.append(url) }
            }
        }

        group.notify(queue: .main) {
            for url in collected.value where !session.pickedFiles.contains(url) {
                session.pickedFiles.append(url)
            }
        }
        return true
    }

    // MARK: - Saving

    private func saveTXT() {
        session.save(suggestedName: "Recognized Text.txt", contentType: .plainText) { url in
            try session.output.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func saveMarkdown() {
        session.save(suggestedName: "Recognized Text.md", contentType: UTType(filenameExtension: "md")!) { url in
            try TextRecognizer.makeMarkdown(from: session.output).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func saveRTF() {
        session.save(suggestedName: "Recognized Text.rtf", contentType: .rtf) { url in
            guard let data = TextRecognizer.makeRTF(from: session.output) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url)
        }
    }
}

/// Minimal mutable box guarded by a lock, for collecting drop results that
/// arrive on an arbitrary queue before handing them to the main actor.
private final class Locked<Value> {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) { storage = value }

    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
