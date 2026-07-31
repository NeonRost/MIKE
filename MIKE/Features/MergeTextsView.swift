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

struct MergeTextsView: View {
    @StateObject private var directory = OutputDirectory(defaultsKey: "MergeTextsOutputDir")

    @State private var files: [URL] = []
    @State private var includeHeadings = true
    // Displayed as typed; \n and \t are unescaped only at merge time, so what
    // is shown here always matches what the user actually entered.
    @State private var separatorText = "\\n\\n"

    @State private var output = ""
    @State private var isRunning = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle
    @State private var isDropTargeted = false

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Merge Texts",
                    subtitle: "Combines several text files into one, in the order you put them in."
                )

                fileSection
                options

                HStack(spacing: 12) {
                    Button("Merge") { merge() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning || files.isEmpty)
                    StatusLine(text: status, kind: statusKind)
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
            files: $files,
            allowedExtensions: TextMerger.acceptedExtensions,
            emptyMessage: "No files selected. Add some, or drag them in — the order you put them in is the order they're merged.",
            addTitle: "Add Files…",
            isEnabled: !isRunning,
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
            Toggle("Insert file name as a heading", isOn: $includeHeadings)

            VStack(alignment: .leading, spacing: 4) {
                Text("Separator between sections")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(text: $separatorText) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 240)
                Text("\\n is a line break, \\t is a tab. Leave empty for no separator at all.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isRunning)
    }

    // MARK: - Output

    @ViewBuilder
    private var resultSection: some View {
        if !output.isEmpty || isRunning {
            VStack(alignment: .leading, spacing: 6) {
                Text("Result")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Editable on purpose, like Extract Article and Read Image
                // Text: the combined text can be checked and corrected before
                // it is saved.
                TextEditor(text: $output)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )

                OutputDirectoryRow(directory: directory, isEnabled: true)

                HStack(spacing: 12) {
                    Button("Save as TXT") { save(extension: "txt") }
                        .disabled(output.isEmpty)
                    Button("Save as Markdown") { save(extension: "md") }
                        .disabled(output.isEmpty)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning, !providers.isEmpty else { return false }

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
            for url in collected.value where !files.contains(url) {
                files.append(url)
            }
        }
        return true
    }

    // MARK: - Actions

    private func merge() {
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

    private func save(extension ext: String) {
        let target = ImageConverter.uniqueURL(directory: directory.url, stem: "merged", extension: ext)
        do {
            try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
            try output.write(to: target, atomically: true, encoding: .utf8)
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
private final class DropCollector {
    private var storage: [URL] = []
    private let lock = NSLock()

    var value: [URL] { lock.lock(); defer { lock.unlock() }; return storage }

    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        storage.append(url)
    }
}
