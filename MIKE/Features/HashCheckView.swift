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

/// Survives navigating away from and back to Hash Check — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class HashCheckSession: ObservableObject {
    @Published var sourceFile: URL?
    @Published var isCalculating = false
    @Published var progress: Double = 0
    @Published var hashes: FileHashes?
    @Published var expectedHashText = ""
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    private var task: Task<Void, Never>?

    enum MatchResult: Equatable {
        case empty
        case match(String)
        case noMatch
    }

    /// Case and all whitespace (including internal spacing some sites
    /// insert into published hashes) are ignored on both sides.
    var matchResult: MatchResult {
        let normalized = expectedHashText.lowercased().filter { !$0.isWhitespace }
        guard !normalized.isEmpty else { return .empty }
        guard let hashes else { return .noMatch }
        if normalized == hashes.md5 { return .match("MD5") }
        if normalized == hashes.sha1 { return .match("SHA-1") }
        if normalized == hashes.sha256 { return .match("SHA-256") }
        if normalized == hashes.sha512 { return .match("SHA-512") }
        return .noMatch
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        load(chosen)
    }

    func load(_ url: URL) {
        task?.cancel()
        sourceFile = url
        hashes = nil
        progress = 0
        status = ""
        statusKind = .idle
        isCalculating = true

        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try HashCalculator.hash(file: url) { fraction in
                    DispatchQueue.main.async {
                        guard let self, self.sourceFile == url else { return }
                        self.progress = fraction
                    }
                }
                await MainActor.run {
                    guard let self, self.sourceFile == url else { return }
                    self.hashes = result
                    self.isCalculating = false
                }
            } catch HashCalculationError.cancelled {
                await MainActor.run {
                    guard let self, self.sourceFile == url else { return }
                    self.isCalculating = false
                    self.status = String(localized: "Cancelled.")
                    self.statusKind = .idle
                }
            } catch {
                await MainActor.run {
                    guard let self, self.sourceFile == url else { return }
                    self.isCalculating = false
                    self.status = String(localized: "The file could not be read.")
                    self.statusKind = .failure
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func clear() {
        guard !isCalculating else { return }
        sourceFile = nil
        hashes = nil
        progress = 0
        expectedHashText = ""
        status = ""
        statusKind = .idle
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct HashCheckView: View {
    @ObservedObject var session: HashCheckSession

    @State private var isDropTargeted = false

    private var canClear: Bool { !session.isCalculating && session.sourceFile != nil }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Hash Check",
                    subtitle: "Computes MD5, SHA-1, SHA-256 and SHA-512 for a file, streamed so even very large files work, and checks them against an expected value."
                )

                fileRow

                if session.isCalculating {
                    progressRow
                }

                if let hashes = session.hashes {
                    hashList(hashes)
                    expectedHashSection
                }

                HStack(spacing: 12) {
                    Button("Clear") { session.clear() }
                        .disabled(!canClear)
                    StatusLine(text: session.status, kind: session.statusKind)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Input

    @ViewBuilder
    private var fileRow: some View {
        FileRow(
            label: "File",
            file: session.sourceFile,
            isEnabled: !session.isCalculating,
            onChoose: { session.chooseFile() },
            onClear: { session.clear() }
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
    private var progressRow: some View {
        HStack(spacing: 12) {
            ProgressView(value: session.progress)
                .frame(maxWidth: 280)
            Text(verbatim: "\(Int(session.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Cancel") { session.cancel() }
        }
    }

    // MARK: - Hashes

    @ViewBuilder
    private func hashList(_ hashes: FileHashes) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            hashRow(label: "MD5", value: hashes.md5)
            hashRow(label: "SHA-1", value: hashes.sha1)
            hashRow(label: "SHA-256", value: hashes.sha256)
            hashRow(label: "SHA-512", value: hashes.sha512)
        }
    }

    @ViewBuilder
    private func hashRow(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(verbatim: value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Copy") { session.copy(value) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    // MARK: - Expected hash

    @ViewBuilder
    private var expectedHashSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Expected hash")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(text: $session.expectedHashText) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .frame(maxWidth: 420)
            matchIndicator
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var matchIndicator: some View {
        switch session.matchResult {
        case .empty:
            EmptyView()
        case .match(let algorithm):
            Text("✓ Match (\(algorithm))", comment: "Shown when the expected hash matches one of the four computed hashes; placeholder is an algorithm name such as SHA-256, not translated")
                .font(.callout.bold())
                .foregroundStyle(.green)
        case .noMatch:
            Text("✗ No match")
                .font(.callout.bold())
                .foregroundStyle(.red)
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isCalculating, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { return }
            DispatchQueue.main.async { session.load(url) }
        }
        return true
    }
}
