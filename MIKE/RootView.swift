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
    case trimVideo
    case tagEditor
    case trackSplitter
    case hashCheck
    case batchRename
    case fileInfo
    case findDuplicates
    case compression
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
        case .trimVideo: return "Trim Video"
        case .tagEditor: return "Tag Editor"
        case .trackSplitter: return "Track Splitter"
        case .hashCheck: return "Hash Check"
        case .batchRename: return "Batch Rename"
        case .fileInfo: return "File Info"
        case .findDuplicates: return "Find Duplicates"
        case .compression: return "Compression"
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
        case .trimVideo: return "scissors"
        case .tagEditor: return "music.note.list"
        case .trackSplitter: return "scissors"
        case .hashCheck: return "checkmark.seal"
        case .batchRename: return "pencil.and.list.clipboard"
        case .fileInfo: return "info.circle"
        case .findDuplicates: return "doc.on.doc"
        case .compression: return "archivebox"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    /// Tools that have to be present before the section can do anything.
    ///
    /// Metadata is deliberately absent: reading works through ImageIO without
    /// any external tool, and only the edit/remove parts need exiftool — those
    /// grey themselves out, the way Convert Format does with cwebp. The whole
    /// Files category needs none either: CryptoKit, Foundation and, for
    /// Compression, the bundled SWCompression/ZIPFoundation SPM packages —
    /// no external command-line tool anywhere in this category.
    var requiredTools: [Tool] {
        switch self {
        case .download: return [.ytDlp, .ffmpeg]
        case .combineVideos: return [.ffmpeg]
        case .trimVideo: return [.ffmpeg]
        case .tagEditor: return [.ffmpeg]
        case .trackSplitter: return [.ffmpeg]
        case .directLink, .extractArticle, .readImageText, .mergeTexts, .convertEncoding, .quickEdit, .combineImages, .convertFormat, .metadata, .embedded, .hashCheck, .batchRename, .fileInfo, .findDuplicates, .compression, .tools: return []
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
    case files

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .web: return "Web"
        case .text: return "Text"
        case .images: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .files: return "Files"
        }
    }

    var sections: [AppSection] {
        switch self {
        case .web: return [.download, .directLink]
        case .text: return [.extractArticle, .readImageText, .mergeTexts, .convertEncoding]
        case .images: return [.quickEdit, .combineImages, .convertFormat, .metadata, .embedded]
        case .video: return [.combineVideos, .trimVideo]
        case .audio: return [.tagEditor, .trackSplitter]
        case .files: return [.hashCheck, .batchRename, .fileInfo, .findDuplicates, .compression]
        }
    }
}

struct RootView: View {
    @StateObject private var tools = ToolRegistry()
    @StateObject private var articleExtractionSession = ArticleExtractionSession()
    @StateObject private var downloadSession = DownloadSession()
    @StateObject private var directLinkSession = DirectLinkSession()
    @StateObject private var readImageTextSession = ReadImageTextSession()
    @StateObject private var mergeTextsSession = MergeTextsSession()
    @StateObject private var convertEncodingSession = ConvertEncodingSession()
    @StateObject private var quickEditSession = QuickEditSession()
    @StateObject private var combineImagesSession = CombineImagesSession()
    @StateObject private var convertFormatSession = ConvertFormatSession()
    @StateObject private var metadataSession = MetadataSession()
    @StateObject private var embeddedMetadataSession = EmbeddedMetadataSession()
    @StateObject private var combineVideosSession = CombineVideosSession()
    @StateObject private var trimVideoSession = TrimVideoSession()
    @StateObject private var tagEditorSession = TagEditorSession()
    @StateObject private var trackSplitterSession = TrackSplitterSession()
    @StateObject private var hashCheckSession = HashCheckSession()
    @StateObject private var batchRenameSession = BatchRenameSession()
    @StateObject private var fileInfoSession = FileInfoSession()
    @StateObject private var findDuplicatesSession = FindDuplicatesSession()
    @StateObject private var compressionSession = CompressionSession()
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
            DownloadView(onOpenTools: openTools, session: downloadSession)
        case .directLink:
            DirectLinkView(session: directLinkSession)
        case .extractArticle:
            ExtractArticleView(session: articleExtractionSession)
        case .readImageText:
            ReadImageTextView(session: readImageTextSession)
        case .mergeTexts:
            MergeTextsView(session: mergeTextsSession)
        case .convertEncoding:
            ConvertEncodingView(session: convertEncodingSession)
        case .quickEdit:
            QuickEditView(onOpenTools: openTools, session: quickEditSession)
        case .combineImages:
            CombineImagesView(session: combineImagesSession)
        case .combineVideos:
            CombineVideosView(onOpenTools: openTools, session: combineVideosSession)
        case .trimVideo:
            TrimVideoView(onOpenTools: openTools, session: trimVideoSession)
        case .tagEditor:
            TagEditorView(onOpenTools: openTools, session: tagEditorSession)
        case .trackSplitter:
            TrackSplitterView(onOpenTools: openTools, session: trackSplitterSession)
        case .convertFormat:
            ConvertFormatView(onOpenTools: openTools, session: convertFormatSession)
        case .metadata:
            MetadataView(onOpenTools: openTools, session: metadataSession)
        case .embedded:
            EmbeddedMetadataView(onOpenTools: openTools, session: embeddedMetadataSession)
        case .hashCheck:
            HashCheckView(session: hashCheckSession)
        case .batchRename:
            BatchRenameView(session: batchRenameSession)
        case .fileInfo:
            FileInfoView(session: fileInfoSession)
        case .findDuplicates:
            FindDuplicatesView(session: findDuplicatesSession)
        case .compression:
            CompressionView(session: compressionSession)
        case .tools:
            ToolsView()
        }
    }
}
