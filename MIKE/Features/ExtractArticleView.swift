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

struct ExtractArticleView: View {
    @StateObject private var extractor = ArticleExtractor()

    @State private var urlText = ""
    @State private var format = ArticleExtractor.Format.plain
    @State private var output = ""
    @State private var articleTitle: String?
    @State private var isRunning = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle
    @State private var task: Task<Void, Never>?

    private var wordCount: Int {
        output.split(whereSeparator: \.isWhitespace).count
    }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Extract Article",
                    subtitle: "Pulls the readable text out of a web page — no ads, no navigation. Needs no external tools."
                )

                HStack(spacing: 8) {
                    TextField("https://…", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .onSubmit { start() }
                    Button("Paste") { pasteFromClipboard() }
                        .help("Paste a URL from the clipboard")
                }
                .disabled(isRunning)

                Picker("Format", selection: $format) {
                    ForEach(ArticleExtractor.Format.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(isRunning)

                HStack(spacing: 12) {
                    Button("Extract") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if isRunning {
                        Button("Cancel") { stop() }
                    }
                    StatusLine(text: status, kind: statusKind)
                }

                resultSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Result")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !output.isEmpty {
                    // Recomputed from the field, so editing updates it.
                    Text("\(wordCount) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Editable on purpose: trimming before saving is a normal thing to
            // want, and Copy and Save both read from here.
            TextEditor(text: $output)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 280)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .overlay(alignment: .topLeading) {
                    if output.isEmpty {
                        Text("The cleaned-up article text appears here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Button("Copy") { WebURL.copyToClipboard(output) }
                    .disabled(output.isEmpty)
                Button("Save…") { save() }
                    .disabled(output.isEmpty)
            }
        }
        .padding(.top, 4)
    }

    private func pasteFromClipboard() {
        if let found = WebURL.fromClipboard() {
            urlText = found
        } else if let raw = NSPasteboard.general.string(forType: .string) {
            urlText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func start() {
        guard !isRunning else { return }
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenFormat = format

        isRunning = true
        statusKind = .working
        status = String(localized: "Loading page…")

        task = Task {
            do {
                let article = try await extractor.extract(from: trimmed, format: chosenFormat)
                output = article.text
                articleTitle = article.title
                status = String(localized: "Done.")
                statusKind = .success
            } catch is CancellationError {
                status = String(localized: "Cancelled.")
                statusKind = .idle
            } catch {
                status = error.localizedDescription
                statusKind = .failure
            }
            isRunning = false
        }
    }

    private func stop() {
        extractor.cancel()
        task?.cancel()
        task = nil
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName()
        panel.allowedContentTypes = [format == .markdown ? .init(filenameExtension: "md")! : .plainText]
        panel.prompt = String(localized: "Save", comment: "Confirm button in the save dialog")
        guard panel.runModal() == .OK, let target = panel.url else { return }

        do {
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

    /// Readability's own title makes the best file name; the host is only a
    /// fallback when a page has no usable title.
    private func suggestedFileName() -> String {
        var base = articleTitle ?? ""
        if base.isEmpty {
            base = URL(string: urlText.trimmingCharacters(in: .whitespaces))?.host ?? "article"
        }
        // Slashes and colons are the two characters the file system and the
        // Finder disagree about.
        base = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.count > 60 {
            base = String(base.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        if base.isEmpty { base = "article" }
        return "\(base).\(format.fileExtension)"
    }
}
