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

/// Survives navigating away from and back to Convert Encoding — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class ConvertEncodingSession: ObservableObject {
    @Published var sourceFile: URL?
    @Published var detectedEncoding: String.Encoding?
    @Published var sourceEncoding: String.Encoding = .utf8
    @Published var targetEncoding: String.Encoding = .utf8

    @Published var decodedText: String?
    @Published var decodeError: String?

    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    var unrepresentableCount: Int {
        guard let decodedText else { return 0 }
        return EncodingConverter.unrepresentableCharacterCount(decodedText, in: targetEncoding)
    }

    var canSave: Bool {
        decodedText != nil && unrepresentableCount == 0
    }

    func chooseFile(directory: OutputDirectory) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        sourceFile = chosen
        directory.set(chosen.deletingLastPathComponent())
        status = ""
        statusKind = .idle

        let detected = EncodingConverter.detectEncoding(of: chosen)
        detectedEncoding = detected
        sourceEncoding = detected
        targetEncoding = .utf8
        redecode()
    }

    func clear() {
        sourceFile = nil
        detectedEncoding = nil
        sourceEncoding = .utf8
        targetEncoding = .utf8
        decodedText = nil
        decodeError = nil
        status = ""
        statusKind = .idle
    }

    func redecode() {
        guard let sourceFile else { return }
        do {
            decodedText = try EncodingConverter.decode(sourceFile, as: sourceEncoding)
            decodeError = nil
        } catch {
            decodedText = nil
            decodeError = error.localizedDescription
        }
    }

    func save(directory: OutputDirectory) {
        guard let sourceFile, let decodedText, canSave else { return }
        guard let data = EncodingConverter.encode(decodedText, as: targetEncoding) else {
            // canSave already guarantees this succeeds; guarded again since
            // encoding is never assumed to succeed silently.
            status = String(
                localized: "\(unrepresentableCount) characters cannot be represented in \(name(for: targetEncoding)). Choose a different target encoding, or remove them from the source.",
                comment: "First placeholder is a count, second is an encoding name"
            )
            statusKind = .failure
            return
        }

        let stem = sourceFile.deletingPathExtension().lastPathComponent
        let ext = sourceFile.pathExtension.isEmpty ? "txt" : sourceFile.pathExtension
        let suffix = shortName(for: targetEncoding).replacingOccurrences(of: "/", with: "-")
        let target = ImageConverter.uniqueURL(directory: directory.url, stem: "\(stem)_\(suffix)", extension: ext)

        do {
            try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
            try data.write(to: target)
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

    // MARK: - Naming

    func name(for encoding: String.Encoding) -> String {
        EncodingCatalog.byEncoding[encoding.rawValue]?.name ?? "Encoding \(encoding.rawValue)"
    }

    func shortName(for encoding: String.Encoding) -> String {
        EncodingCatalog.byEncoding[encoding.rawValue]?.shortName ?? "Encoding\(encoding.rawValue)"
    }
}

struct ConvertEncodingView: View {
    @ObservedObject var session: ConvertEncodingSession
    @StateObject private var directory = OutputDirectory(defaultsKey: "ConvertEncodingOutputDir")

    /// Characters shown in the preview — enough to judge whether the source
    /// encoding is right without loading or rendering an entire large file.
    private static let previewLength = 500

    private var canClear: Bool { session.sourceFile != nil }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Convert Encoding",
                    subtitle: "Reads a text file with one character encoding and writes it back out with another, leaving the original untouched."
                )

                FileRow(
                    label: "Text file",
                    file: session.sourceFile,
                    onChoose: { session.chooseFile(directory: directory) },
                    onClear: { session.clear() }
                )

                if session.sourceFile != nil {
                    detectionNote
                    encodingPickers
                    preview
                    saveSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Detection

    @ViewBuilder
    private var detectionNote: some View {
        if let detectedEncoding = session.detectedEncoding {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Detected:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: session.name(for: detectedEncoding))
                        .font(.caption)
                }
                Text("Automatic detection is not always reliable — override it below if the preview looks wrong.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pickers

    @ViewBuilder
    private var encodingPickers: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Source encoding")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                encodingPicker(selection: $session.sourceEncoding)
                    .onChange(of: session.sourceEncoding) { _ in session.redecode() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Target encoding")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                encodingPicker(selection: $session.targetEncoding)
            }
        }
    }

    @ViewBuilder
    private func encodingPicker(selection: Binding<String.Encoding>) -> some View {
        Picker(selection: selection) {
            ForEach(EncodingCatalog.common) { option in
                Text(verbatim: option.name).tag(option.encoding)
            }
            Divider()
            ForEach(EncodingCatalog.others) { option in
                Text(verbatim: option.name).tag(option.encoding)
            }
        } label: { EmptyView() }
        .labelsHidden()
        .frame(maxWidth: 280)
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let decodeError = session.decodeError {
                Text(decodeError)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let decodedText = session.decodedText {
                let shown = String(decodedText.prefix(Self.previewLength))
                Text(verbatim: shown)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                if decodedText.count > Self.previewLength {
                    Text("Showing the first \(Self.previewLength) of \(decodedText.count) characters.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if session.unrepresentableCount > 0 {
                Text(
                    "\(session.unrepresentableCount) characters cannot be represented in \(session.name(for: session.targetEncoding)). Choose a different target encoding, or remove them from the source.",
                    comment: "First placeholder is a count, second is an encoding name"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Save

    @ViewBuilder
    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            OutputDirectoryRow(directory: directory)

            HStack(spacing: 12) {
                Button("Save") { session.save(directory: directory) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canSave)
                Button("Clear") { session.clear() }
                    .disabled(!canClear)
                StatusLine(text: session.status, kind: session.statusKind)
            }
        }
        .padding(.top, 4)
    }
}
