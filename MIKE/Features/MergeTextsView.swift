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

/// Survives navigating away from and back to Merge Texts — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class MergeTextsSession: ObservableObject {
    @Published var files: [URL] = []
    @Published var includeHeadings = true
    // Displayed as typed; \n and \t are unescaped only at merge time, so what
    // is shown here always matches what the user actually entered.
    @Published var separatorText = "\\n\\n"

    @Published var output = ""
    @Published var isRunning = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    func clear() {
        guard !isRunning else { return }
        files = []
        includeHeadings = true
        separatorText = "\\n\\n"
        output = ""
        status = ""
        statusKind = .idle
    }

    func merge() {
        guard !files.isEmpty else { return }
        let inputFiles = files
        let headings = includeHeadings
        let separator = TextMerger.unescapeSeparator(separatorText)

        isRunning = true
        statusKind = .working
        status = String(localized: "Merging…")

        Task {
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: TextMerger.merge(files: inputFiles, includeHeadings: headings, separator: separator)
                    )
                }
            }

            output = result.text
            isRunning = false

            if result.skipped.isEmpty {
                status = String(localized: "Done.")
                statusKind = .success
            } else {
                let list = ListFormatter.localizedString(byJoining: result.skipped)
                status = String(
                    localized: "Done. Skipped (could not be read as text): \(list)",
                    comment: "Placeholder is a comma-separated list of file names"
                )
                statusKind = .success
            }
        }
    }

    func save(extension ext: String, directory: OutputDirectory) {
        let target = ImageConverter.uniqueURL(directory: directory.url, stem: Self.outputStem, extension: ext)
        do {
            try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
            try output.write(to: target, atomically: true, encoding: .utf8)
            report(saved: target)
        } catch {
            status = error.localizedDescription
            statusKind = .failure
        }
    }

    /// PDF and EPUB go through their own writers rather than `save(extension:)`:
    /// both are containers with a structure, not the text written out verbatim.
    func savePDF(directory: OutputDirectory) {
        do {
            let target = try TextDocumentWriter.pdf(
                text: output,
                into: directory.url,
                stem: Self.outputStem
            )
            report(saved: target)
        } catch {
            status = error.localizedDescription
            statusKind = .failure
        }
    }

    func saveEPUB(directory: OutputDirectory) {
        do {
            let target = try EPUBBuilder.build(
                text: output,
                into: directory.url,
                stem: Self.outputStem,
                title: bookTitle
            )
            report(saved: target)
        } catch {
            status = error.localizedDescription
            statusKind = .failure
        }
    }

    private static let outputStem = "merged"

    /// The first source file names the book — the one name the user has
    /// already attached to this set. The text itself is editable and may no
    /// longer resemble any of the files, so the stem is the fallback.
    private var bookTitle: String {
        files.first?.deletingPathExtension().lastPathComponent ?? Self.outputStem
    }

    private func report(saved target: URL) {
        status = String(
            localized: "Saved: \(target.lastPathComponent)",
            comment: "Placeholder is the written file name"
        )
        statusKind = .success
    }
}

struct MergeTextsView: View {
    @ObservedObject var session: MergeTextsSession
    @StateObject private var directory = OutputDirectory(defaultsKey: "MergeTextsOutputDir")

    @State private var isDropTargeted = false

    private var canClear: Bool {
        !session.isRunning && !(session.files.isEmpty && session.output.isEmpty)
    }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Merge Texts",
                    subtitle: "Combines several text files into one, in the order you put them in — saved as text, Markdown, PDF or EPUB."
                )

                fileSection
                options

                HStack(spacing: 12) {
                    Button("Merge") { session.merge() }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isRunning || session.files.isEmpty)
                    Button("Clear") { session.clear() }
                        .disabled(!canClear)
                    StatusLine(text: session.status, kind: session.statusKind)
                }

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
            files: $session.files,
            allowedExtensions: TextMerger.acceptedExtensions,
            emptyMessage: "No files selected. Add some, or drag them in — the order you put them in is the order they're merged.",
            addTitle: "Add Files…",
            isEnabled: !session.isRunning,
            permitsAnyFile: true
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
    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Insert file name as a heading", isOn: $session.includeHeadings)

            VStack(alignment: .leading, spacing: 4) {
                Text("Separator between sections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(text: $session.separatorText) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 240)
                Text("\\n is a line break, \\t is a tab. Leave empty for no separator at all.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(session.isRunning)
    }

    // MARK: - Output

    @ViewBuilder
    private var resultSection: some View {
        if !session.output.isEmpty || session.isRunning {
            VStack(alignment: .leading, spacing: 6) {
                Text("Result")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Editable on purpose, like Extract Article and Read Image
                // Text: the combined text can be checked and corrected before
                // it is saved.
                TextEditor(text: $session.output)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )

                OutputDirectoryRow(directory: directory, isEnabled: true)

                HStack(spacing: 12) {
                    Button("Save as TXT") { session.save(extension: "txt", directory: directory) }
                        .disabled(session.output.isEmpty)
                    Button("Save as Markdown") { session.save(extension: "md", directory: directory) }
                        .disabled(session.output.isEmpty)
                    Button("Save as PDF") { session.savePDF(directory: directory) }
                        .disabled(session.output.isEmpty)
                    Button("Save as EPUB") { session.saveEPUB(directory: directory) }
                        .disabled(session.output.isEmpty)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isRunning, !providers.isEmpty else { return false }

        let group = DispatchGroup()
        // Collected on a lock, not `files` directly: `loadItem`'s completion
        // handlers arrive on an arbitrary queue, never the main actor.
        let collected = DropCollector()

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
                // No extension filtering here either — the same "let the read
                // attempt decide" rule as the picker and the merge itself.
                guard let url else { return }
                collected.append(url)
            }
        }

        group.notify(queue: .main) {
            for url in collected.value where !session.files.contains(url) {
                session.files.append(url)
            }
        }
        return true
    }
}

/// Minimal mutable box guarded by a lock, for collecting drop results that
/// arrive on an arbitrary queue before handing them to the main actor.
private final class DropCollector {
    private var storage: [URL] = []
    private let lock = NSLock()

    var value: [URL] { lock.lock(); defer { lock.unlock() }; return storage }

    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        storage.append(url)
    }
}
