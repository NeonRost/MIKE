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

/// Survives navigating away from and back to Tag Editor — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class TagEditorSession: ObservableObject {
    @Published var sourceFile: URL?
    @Published var tags = AudioTags()
    @Published var coverImage: NSImage?
    @Published var coverEdit: CoverEdit = .unchanged
    @Published var isLoading = false
    @Published var isRunning = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    var capabilities: AudioFormatCapabilities {
        guard let sourceFile else {
            return AudioFormatCapabilities(supportsTags: true, supportsCoverArt: true, unsupportedFields: [])
        }
        return AudioFormatCapabilities.forExtension(sourceFile.pathExtension)
    }

    func clear() {
        guard !isRunning, !isLoading else { return }
        sourceFile = nil
        tags = AudioTags()
        coverImage = nil
        coverEdit = .unchanged
        status = ""
        statusKind = .idle
    }

    func chooseCover() {
        guard capabilities.supportsCoverArt else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png]
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        coverImage = NSImage(contentsOf: chosen)
        coverEdit = .replace(chosen)
    }

    func removeCover() {
        coverImage = nil
        coverEdit = .remove
    }

    func chooseFile(ffmpeg: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        load(chosen, ffmpeg: ffmpeg)
    }

    func load(_ url: URL, ffmpeg: URL?) {
        guard let ffmpeg else { return }
        sourceFile = url
        tags = AudioTags()
        coverImage = nil
        coverEdit = .unchanged
        status = ""
        statusKind = .idle

        let formatCapabilities = AudioFormatCapabilities.forExtension(url.pathExtension)
        guard formatCapabilities.supportsTags else { return }

        isLoading = true
        Task { [weak self] in
            let (readTags, cover) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let readTags = AudioTagEditor.readTags(from: url, ffmpeg: ffmpeg)
                    let cover = formatCapabilities.supportsCoverArt
                        ? AudioTagEditor.extractCover(from: url, ffmpeg: ffmpeg)
                        : nil
                    continuation.resume(returning: (readTags, cover))
                }
            }
            // The user may have picked a different file while this was loading.
            guard let self, sourceFile == url else { return }
            tags = readTags
            coverImage = cover
            isLoading = false
        }
    }

    func save(ffmpeg: URL?) {
        guard let sourceFile, let ffmpeg else { return }
        let currentTags = tags
        let currentCover = coverEdit

        isRunning = true
        statusKind = .working
        status = String(localized: "Saving…")

        Task { [weak self] in
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try AudioTagEditor.write(tags: currentTags, cover: currentCover, to: sourceFile, ffmpeg: ffmpeg)
                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }

            guard let self else { return }
            isRunning = false
            switch result {
            case .success:
                coverEdit = .unchanged
                status = String(localized: "Saved.")
                statusKind = .success
            case .failure(let error):
                status = error.localizedDescription
                statusKind = .failure
            }
        }
    }
}

struct TagEditorView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry
    @ObservedObject var session: TagEditorSession

    @State private var isDropTargeted = false

    private var missingTools: [Tool] {
        tools.missing(from: AppSection.tagEditor.requiredTools)
    }

    private var isReady: Bool { missingTools.isEmpty }
    private var ffmpeg: URL? { tools.status(for: .ffmpeg).url }

    private var canClear: Bool { !session.isRunning && !session.isLoading && session.sourceFile != nil }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Tag Editor",
                    subtitle: "Reads and writes the title, artist and other tags of an audio file, losslessly."
                )

                if !isReady {
                    RequirementBanner(missing: missingTools, onOpenTools: onOpenTools)
                }

                VStack(alignment: .leading, spacing: 16) {
                    fileRow

                    if session.sourceFile != nil {
                        if !session.capabilities.supportsTags {
                            noMetadataNote
                        } else {
                            editor
                        }
                    }
                }
                .disabled(!isReady)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Input

    @ViewBuilder
    private var fileRow: some View {
        HStack(spacing: 12) {
            FileRow(
                label: "Audio file",
                file: session.sourceFile,
                isEnabled: !session.isRunning,
                onChoose: { session.chooseFile(ffmpeg: ffmpeg) },
                onClear: { session.clear() }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            Spacer(minLength: 0)
            Button("Clear") { session.clear() }
                .disabled(!canClear)
        }
    }

    @ViewBuilder
    private var noMetadataNote: some View {
        Label(
            "This file format carries no metadata container — nothing can be read or written for it.",
            systemImage: "info.circle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                coverArea
                VStack(alignment: .leading, spacing: 10) {
                    field("Title", $session.tags.title, .title)
                    field("Artist", $session.tags.artist, .artist)
                    field("Album Artist", $session.tags.albumArtist, .albumArtist)
                    field("Album", $session.tags.album, .album)
                }
                .frame(maxWidth: .infinity)
            }

            HStack(alignment: .top, spacing: 20) {
                field("Year", $session.tags.year, .year)
                field("Track (e.g. 3/12)", $session.tags.track, .track)
                field("Genre", $session.tags.genre, .genre)
            }
            field("Comment", $session.tags.comment, .comment)

            Text("Empty fields are left unchanged. Filled ones are written.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Button("Save") { session.save(ffmpeg: ffmpeg) }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isRunning || session.isLoading)
                    StatusLine(text: session.status, kind: session.statusKind)
                }
                Text("Changes will be written directly to the file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(session.isLoading)
    }

    @ViewBuilder
    private func field(_ label: LocalizedStringKey, _ binding: Binding<String>, _ tagField: TagField) -> some View {
        let unsupported = session.capabilities.unsupportedFields.contains(tagField)
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(text: binding) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .disabled(unsupported || session.isRunning)
            if unsupported {
                Text("Not supported for this format.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Cover

    @ViewBuilder
    private var coverArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { session.chooseCover() }) {
                ZStack {
                    if let coverImage = session.coverImage {
                        Image(nsImage: coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color(nsColor: .controlBackgroundColor)
                        Text("No cover – click to add")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(10)
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
            .buttonStyle(.plain)
            .disabled(!session.capabilities.supportsCoverArt || session.isRunning)

            if session.coverImage != nil {
                Button("Remove") { session.removeCover() }
                    .disabled(!session.capabilities.supportsCoverArt || session.isRunning)
            }
            if !session.capabilities.supportsCoverArt {
                Text("Not supported for this format.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isRunning, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url, AudioTagEditor.acceptedExtensions.contains(url.pathExtension.lowercased())
            else { return }
            DispatchQueue.main.async { session.load(url, ffmpeg: ffmpeg) }
        }
        return true
    }
}
