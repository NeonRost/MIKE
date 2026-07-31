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

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case download
    case directLink
    case extractArticle
    case readImageText
    case mergeTexts
    case convertEncoding
    case quickEdit
    case combineImages
    case convertFormat
    case metadata
    case embedded
    case combineVideos
    case tagEditor
    case trackSplitter
    case tools

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .download: return "Download"
        case .directLink: return "Direct Link"
        case .extractArticle: return "Extract Article"
        case .readImageText: return "Read Image Text"
        case .mergeTexts: return "Merge Texts"
        case .convertEncoding: return "Convert Encoding"
        case .quickEdit: return "Quick Edit"
        case .combineImages: return "Combine Images"
        case .convertFormat: return "Convert Format"
        case .metadata: return "Metadata"
        case .embedded: return "Embedded"
        case .combineVideos: return "Combine Videos"
        case .tagEditor: return "Tag Editor"
        case .trackSplitter: return "Track Splitter"
        case .tools: return "Setup"
        }
    }

    var symbol: String {
        switch self {
        case .download: return "arrow.down.circle"
        case .directLink: return "link"
        case .extractArticle: return "doc.plaintext"
        case .readImageText: return "text.viewfinder"
        case .mergeTexts: return "doc.on.doc"
        case .convertEncoding: return "character.book.closed"
        case .quickEdit: return "crop"
        case .combineImages: return "photo.on.rectangle.angled"
        case .convertFormat: return "arrow.triangle.2.circlepath"
        case .metadata: return "tag"
        case .embedded: return "curlybraces"
        case .combineVideos: return "film"
        case .tagEditor: return "music.note.list"
        case .trackSplitter: return "scissors"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    /// Tools that have to be present before the section can do anything.
    ///
    /// Metadata is deliberately absent: reading works through ImageIO without
    /// any external tool, and only the edit/remove parts need exiftool — those
    /// grey themselves out, the way Convert Format does with cwebp.
    var requiredTools: [Tool] {
        switch self {
        case .download: return [.ytDlp, .ffmpeg]
        case .combineVideos: return [.ffmpeg]
        case .tagEditor: return [.ffmpeg]
        case .trackSplitter: return [.ffmpeg]
        case .directLink, .extractArticle, .readImageText, .mergeTexts, .convertEncoding, .quickEdit, .combineImages, .convertFormat, .metadata, .embedded, .tools: return []
        }
    }
}

/// The groups the sidebar is divided into. Setup is deliberately not a member:
/// it is not one of Mike's tools but the place to check and install what they
/// need, so it is pinned below the categories instead of sitting inside one.
enum SectionGroup: String, CaseIterable, Identifiable {
    case web
    case text
    case images
    case video
    case audio

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .web: return "Web"
        case .text: return "Text"
        case .images: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        }
    }

    var sections: [AppSection] {
        switch self {
        case .web: return [.download, .directLink]
        case .text: return [.extractArticle, .readImageText, .mergeTexts, .convertEncoding]
        case .images: return [.quickEdit, .combineImages, .convertFormat, .metadata, .embedded]
        case .video: return [.combineVideos]
        case .audio: return [.tagEditor, .trackSplitter]
        }
    }
}

struct RootView: View {
    @StateObject private var tools = ToolRegistry()
    @State private var selection: AppSection? = .download
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            detail
        }
        .environmentObject(tools)
        .navigationTitle("MIKE")
        .onAppear { appDelegate.registry = tools }
    }

    /// Two lists sharing one selection: the grouped one takes the free space,
    /// the second holds Setup against the bottom edge. A trailing section
    /// inside the first list would merely follow the last group and leave a
    /// gap underneath, which is not the same thing as being pinned.
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SectionGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.symbol)
                        }
                    }
                }
            }

            Divider()

            List(selection: $selection) {
                Label(AppSection.tools.title, systemImage: AppSection.tools.symbol)
                    .tag(AppSection.tools)
            }
            .frame(height: 42)
            .scrollDisabled(true)
        }
    }

    @ViewBuilder
    private var detail: some View {
        let openTools = { selection = .tools }

        switch selection ?? .download {
        case .download:
            DownloadView(onOpenTools: openTools)
        case .directLink:
            DirectLinkView()
        case .extractArticle:
            ExtractArticleView()
        case .readImageText:
            ReadImageTextView()
        case .mergeTexts:
            MergeTextsView()
        case .convertEncoding:
            ConvertEncodingView()
        case .quickEdit:
            QuickEditView(onOpenTools: openTools)
        case .combineImages:
            CombineImagesView()
        case .combineVideos:
            CombineVideosView(onOpenTools: openTools)
        case .tagEditor:
            TagEditorView(onOpenTools: openTools)
        case .trackSplitter:
            TrackSplitterView(onOpenTools: openTools)
        case .convertFormat:
            ConvertFormatView(onOpenTools: openTools)
        case .metadata:
            MetadataView(onOpenTools: openTools)
        case .embedded:
            EmbeddedMetadataView(onOpenTools: openTools)
        case .tools:
            ToolsView()
        }
    }
}
