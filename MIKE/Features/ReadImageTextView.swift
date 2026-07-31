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

struct ReadImageTextView: View {
    @State private var pickedFiles: [URL] = []
    @State private var output = ""
    @State private var isRunning = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle
    @State private var task: Task<Void, Never>?

    /// 0 while a single clipboard image is being read — that path shows only
    /// the spinner, not the N-of-M bar.
    @State private var currentIndex = 0
    @State private var totalCount = 0

    @State private var isDropTargeted = false

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
            files: $pickedFiles,
            allowedExtensions: TextRecognizer.acceptedExtensions,
            emptyMessage: "No images selected. Add some, or drag them in — text is read in the order they're listed.",
            addTitle: "Add Images…",
            isEnabled: !isRunning
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
            Button("Paste from Clipboard") { pasteFromClipboard() }
                .disabled(isRunning)
            Text("Reads an image straight from the clipboard — after Cmd-Shift-4, for instance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var runRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Recognize Text") { startBatch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || pickedFiles.isEmpty)
                if isRunning {
                    Button("Cancel") { stop() }
                }
                StatusLine(text: status, kind: statusKind)
            }
            if isRunning, totalCount > 1 {
                ProgressView(value: Double(currentIndex), total: Double(totalCount))
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
            TextEditor(text: $output)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 280)
                .disabled(isRunning)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .overlay(alignment: .topLeading) {
                    if output.isEmpty {
                        Text("Recognized text appears here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 12) {
                Button("Copy") { WebURL.copyToClipboard(output) }
                    .disabled(output.isEmpty)
                Button("Save as TXT") { saveTXT() }
                    .disabled(output.isEmpty)
                Button("Save as Markdown") { saveMarkdown() }
                    .disabled(output.isEmpty)
                Button("Save as RTF") { saveRTF() }
                    .disabled(output.isEmpty)
            }
            Text("Formatting such as bold or italic is not detected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning, !providers.isEmpty else { return false }

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
            for url in collected.value where !pickedFiles.contains(url) {
                pickedFiles.append(url)
            }
        }
        return true
    }

    // MARK: - Recognition

    private func pasteFromClipboard() {
        guard !isRunning else { return }
        guard let data = TextRecognizer.imageDataFromPasteboard() else {
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

    private func startBatch() {
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

    private func stop() {
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

    // MARK: - Saving

    private func saveTXT() {
        save(suggestedName: "Recognized Text.txt", contentType: .plainText) { url in
            try output.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func saveMarkdown() {
        save(suggestedName: "Recognized Text.md", contentType: UTType(filenameExtension: "md")!) { url in
            try TextRecognizer.makeMarkdown(from: output).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func saveRTF() {
        save(suggestedName: "Recognized Text.rtf", contentType: .rtf) { url in
            guard let data = TextRecognizer.makeRTF(from: output) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url)
        }
    }

    private func save(suggestedName: String, contentType: UTType, writer: (URL) throws -> Void) {
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
