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

/// One row of the live "Current name → New name" preview. Identity is the
/// source file's URL, since that never changes while the row is being edited.
struct RenamePreviewRow: Identifiable {
    let id: URL
    let originalName: String
    let newName: String
    /// Informational only — the EXIF step found no date for this file.
    let problem: String?
    /// Two files of this batch would end up with the same name in the same
    /// folder.
    var isConflict: Bool = false
    /// Why this row cannot be renamed at all: the name is not a usable file
    /// name, or a file that is not part of the batch already has it. Shown in
    /// place of the generic conflict label, and blocks the rename like one.
    var blocking: String?

    var blocksRename: Bool { isConflict || blocking != nil }
}

/// Survives navigating away from and back to Batch Rename — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class BatchRenameSession: ObservableObject {
    @Published var files: [URL] = []
    /// Read once per file and cached, so typing in an unrelated field (prefix,
    /// find & replace, …) never re-reads EXIF from disk.
    @Published private(set) var dateInfo: [URL: FileDateInfo] = [:]

    @Published var exifDateEnabled = false
    @Published var exifDateFormatText = "yyyy-MM-dd_HH-mm-ss"
    @Published var exifDateFallbackToModDate = true

    @Published var prefixEnabled = false
    @Published var prefixText = ""

    @Published var suffixEnabled = false
    @Published var suffixText = ""

    @Published var findReplaceEnabled = false
    @Published var findText = ""
    @Published var replaceText = ""
    @Published var findReplaceCaseSensitive = false

    @Published var caseConversionEnabled = false
    @Published var caseConversion = CaseConversion.lowercase

    @Published var spaceReplacementEnabled = false
    @Published var spaceReplacement = SpaceReplacement.underscore

    @Published var isRenaming = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    /// What the last rename did, newest state last, for undoing it.
    @Published private(set) var lastRename: [(old: URL, new: URL)] = []

    private var dateInfoTask: Task<Void, Never>?

    /// The preview for exactly the inputs it was built from. `previewRows` is
    /// read several times per redraw — once by the list, again by `canRename`
    /// — and building it means a pass over every file plus a look at the
    /// disk, so it is kept until something it depends on changes.
    private var previewCache: (files: [URL], settings: BatchRenameSettings, dataVersion: Int, rows: [RenamePreviewRow])?
    /// Bumped whenever the date cache or the folder contents change under an
    /// unchanged file list.
    private var dataVersion = 0

    private var settings: BatchRenameSettings {
        var settings = BatchRenameSettings()
        settings.exifDateEnabled = exifDateEnabled
        settings.exifDateFormat = exifDateFormatText
        settings.exifDateFallbackToModDate = exifDateFallbackToModDate
        settings.prefixEnabled = prefixEnabled
        settings.prefixText = prefixText
        settings.suffixEnabled = suffixEnabled
        settings.suffixText = suffixText
        settings.findReplaceEnabled = findReplaceEnabled
        settings.findText = findText
        settings.replaceText = replaceText
        settings.findReplaceCaseSensitive = findReplaceCaseSensitive
        settings.caseConversionEnabled = caseConversionEnabled
        settings.caseConversion = caseConversion
        settings.spaceReplacementEnabled = spaceReplacementEnabled
        settings.spaceReplacement = spaceReplacement
        return settings
    }

    var previewRows: [RenamePreviewRow] {
        let currentSettings = settings
        if let cache = previewCache, cache.dataVersion == dataVersion,
           cache.settings == currentSettings, cache.files == files {
            return cache.rows
        }
        let rows = buildPreviewRows(settings: currentSettings)
        previewCache = (files, currentSettings, dataVersion, rows)
        return rows
    }

    private func buildPreviewRows(settings: BatchRenameSettings) -> [RenamePreviewRow] {
        let planned = BatchRenamer.plan(files: files, dateInfo: dateInfo, settings: settings)
        var rows = planned.map {
            RenamePreviewRow(id: $0.source, originalName: $0.source.lastPathComponent, newName: $0.newName, problem: $0.problem)
        }

        // Where each row would end up. Compared per folder and without regard
        // to case: two files only collide if they land in the same folder,
        // and on the default volume format `A.jpg` and `a.jpg` are one name.
        let targets = rows.map { row in
            BatchRenamer.key(for: row.id.deletingLastPathComponent().appendingPathComponent(row.newName))
        }
        var counts: [String: Int] = [:]
        for target in targets { counts[target, default: 0] += 1 }
        let sources = Set(files.map { BatchRenamer.key(for: $0) })

        for index in rows.indices {
            let row = rows[index]
            guard row.newName != row.originalName else { continue }

            if let problem = FileName.problem(inStem: planned[index].newStem) {
                rows[index].blocking = problem.message
                continue
            }
            if (counts[targets[index]] ?? 0) > 1 {
                rows[index].isConflict = true
                continue
            }
            // Taken by a file that is not being renamed here. A file of this
            // batch that currently holds the name is fine — it moves too, and
            // `BatchRenamer.execute` orders that correctly.
            let target = row.id.deletingLastPathComponent().appendingPathComponent(row.newName)
            if !sources.contains(targets[index]), FileManager.default.fileExists(atPath: target.path) {
                rows[index].blocking = String(localized: "A file with this name already exists.")
            }
        }
        return rows
    }

    var canRename: Bool {
        guard !isRenaming, !files.isEmpty, settings.hasAnyOperation else { return false }
        let rows = previewRows
        guard !rows.contains(where: { $0.blocksRename }) else { return false }
        return rows.contains { $0.newName != $0.originalName }
    }

    /// Called whenever `files` changes — from the picker, a drop, a removal,
    /// or a completed rename. Keeps the list in Finder order and the date
    /// cache in sync without the caller having to know which of those happened.
    func filesDidChange() {
        files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let current = Set(files)
        dateInfo = dateInfo.filter { current.contains($0.key) }
        refreshDateInfo()
    }

    private func refreshDateInfo() {
        let missing = files.filter { dateInfo[$0] == nil }
        guard !missing.isEmpty else { return }

        dateInfoTask?.cancel()
        dateInfoTask = Task.detached(priority: .userInitiated) {
            var results: [URL: FileDateInfo] = [:]
            for url in missing {
                if Task.isCancelled { break }
                let capture = ImageMetadata.captureDate(from: url)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                results[url] = FileDateInfo(captureDate: capture, modificationDate: modified)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (url, info) in results { self.dateInfo[url] = info }
                self.dataVersion += 1
            }
        }
    }

    func clear() {
        guard !isRenaming else { return }
        dateInfoTask?.cancel()
        files = []
        dateInfo = [:]
        lastRename = []
        dataVersion += 1
        exifDateEnabled = false
        exifDateFormatText = "yyyy-MM-dd_HH-mm-ss"
        exifDateFallbackToModDate = true
        prefixEnabled = false
        prefixText = ""
        suffixEnabled = false
        suffixText = ""
        findReplaceEnabled = false
        findText = ""
        replaceText = ""
        findReplaceCaseSensitive = false
        caseConversionEnabled = false
        caseConversion = .lowercase
        spaceReplacementEnabled = false
        spaceReplacement = .underscore
        status = ""
        statusKind = .idle
    }

    func rename() {
        guard canRename else { return }
        let changed = previewRows.filter { $0.newName != $0.originalName }
        let pairs: [(source: URL, target: URL)] = changed.map { row in
            (row.id, row.id.deletingLastPathComponent().appendingPathComponent(row.newName))
        }

        isRenaming = true
        statusKind = .working
        status = String(localized: "Renaming…")

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = BatchRenamer.execute(pairs)
            await MainActor.run {
                guard let self else { return }
                for (old, new) in result.succeeded {
                    if let index = self.files.firstIndex(of: old) {
                        self.files[index] = new
                    }
                    if let info = self.dateInfo.removeValue(forKey: old) {
                        self.dateInfo[new] = info
                    }
                }
                self.lastRename = result.succeeded
                self.dataVersion += 1
                self.isRenaming = false
                if result.failures.isEmpty {
                    self.status = String(
                        localized: "Done. \(result.succeeded.count) files renamed.",
                        comment: "Placeholder is a count of files"
                    )
                    self.statusKind = .success
                } else {
                    let list = ListFormatter.localizedString(byJoining: result.failures.map(\.name))
                    self.status = String(
                        localized: "Done. \(result.succeeded.count) renamed, \(result.failures.count) failed: \(list)",
                        comment: "Placeholders: succeeded count, failed count, comma-separated file names"
                    )
                    self.statusKind = .failure
                }
            }
        }
    }

    var canUndo: Bool { !isRenaming && !lastRename.isEmpty }

    /// Puts the files of the last rename back under their old names. Goes
    /// through the same executor, so a batch that swapped names is swapped
    /// back correctly too.
    func undoLastRename() {
        guard canUndo else { return }
        let pairs: [(source: URL, target: URL)] = lastRename.map { ($0.new, $0.old) }

        isRenaming = true
        statusKind = .working
        status = String(localized: "Undoing…")

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = BatchRenamer.execute(pairs)
            await MainActor.run {
                guard let self else { return }
                for (current, restored) in result.succeeded {
                    if let index = self.files.firstIndex(of: current) {
                        self.files[index] = restored
                    }
                    if let info = self.dateInfo.removeValue(forKey: current) {
                        self.dateInfo[restored] = info
                    }
                }
                self.lastRename = []
                self.dataVersion += 1
                self.isRenaming = false
                if result.failures.isEmpty {
                    self.status = String(localized: "Undone. The files have their previous names again.")
                    self.statusKind = .success
                } else {
                    let list = ListFormatter.localizedString(byJoining: result.failures.map(\.name))
                    self.status = String(
                        localized: "Could not restore every name: \(list)",
                        comment: "Placeholder is a comma-separated list of file names"
                    )
                    self.statusKind = .failure
                }
            }
        }
    }
}

struct BatchRenameView: View {
    @ObservedObject var session: BatchRenameSession

    @State private var isDropTargeted = false

    private var canClear: Bool { !session.isRenaming && !session.files.isEmpty }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Batch Rename",
                    subtitle: "Renames several files at once using a fixed pipeline of combinable operations."
                )

                fileListSection

                if !session.files.isEmpty {
                    operationsSection
                    previewSection
                    renameSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Input

    @ViewBuilder
    private var fileListSection: some View {
        FileListEditor(
            files: $session.files,
            allowedExtensions: [],
            emptyMessage: "No files selected. Add some, or drag them in — whole folders work too (their files are added, subfolders are skipped).",
            addTitle: "Add Files or Folders…",
            isEnabled: !session.isRenaming,
            permitsAnyFile: true,
            permitsFolders: true
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: session.files) { _ in session.filesDidChange() }
    }

    // MARK: - Operations

    @ViewBuilder
    private var operationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Operations")
                .font(.headline)

            OperationBlock(title: "EXIF Date as Name", isEnabled: $session.exifDateEnabled, isBusy: session.isRenaming) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(text: $session.exifDateFormatText) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .frame(maxWidth: 260)
                    Text(verbatim: "yyyy-MM-dd_HH-mm-ss   yyyyMMdd_HHmmss   yyyy-MM-dd")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Toggle("Fall back to file modification date", isOn: $session.exifDateFallbackToModDate)
                }
            }

            OperationBlock(title: "Add Prefix", isEnabled: $session.prefixEnabled, isBusy: session.isRenaming) {
                TextField(text: $session.prefixText) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            OperationBlock(title: "Add Suffix", isEnabled: $session.suffixEnabled, isBusy: session.isRenaming) {
                TextField(text: $session.suffixText) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            OperationBlock(title: "Find & Replace", isEnabled: $session.findReplaceEnabled, isBusy: session.isRenaming) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        labeledField("Find", $session.findText)
                        labeledField("Replace with", $session.replaceText)
                    }
                    Toggle("Case sensitive", isOn: $session.findReplaceCaseSensitive)
                }
            }

            OperationBlock(title: "Change Case", isEnabled: $session.caseConversionEnabled, isBusy: session.isRenaming) {
                Picker("Change Case", selection: $session.caseConversion) {
                    ForEach(CaseConversion.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }

            OperationBlock(title: "Replace Spaces", isEnabled: $session.spaceReplacementEnabled, isBusy: session.isRenaming) {
                Picker("Replace Spaces", selection: $session.spaceReplacement) {
                    ForEach(SpaceReplacement.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func labeledField(_ label: LocalizedStringKey, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(text: text) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Fixed height on purpose: a List inside the section's scroll
            // view must not negotiate its own height, matching FileListEditor.
            List(session.previewRows) { row in
                HStack(spacing: 8) {
                    Text(verbatim: row.originalName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: row.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let blocking = row.blocking {
                        Text(verbatim: blocking)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if row.isConflict {
                        Text("Name conflict")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if let problem = row.problem {
                        Text(verbatim: problem)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(
                    row.blocksRename ? Color.red
                        : row.newName == row.originalName ? Color.secondary
                        : Color.primary
                )
            }
            .frame(height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Rename

    @ViewBuilder
    private var renameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check the preview before continuing. The last rename can be undone while MIKE stays open.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Rename") { session.rename() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canRename)
                Button("Undo Last Rename") { session.undoLastRename() }
                    .disabled(!session.canUndo)
                Button("Clear") { session.clear() }
                    .disabled(!canClear)
                StatusLine(text: session.status, kind: session.statusKind)
            }
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isRenaming, !providers.isEmpty else { return false }
        FileDrop.urls(from: providers) { urls in
            for url in urls {
                if FileDrop.isDirectory(url) {
                    for expanded in FileListEditor.expand(folder: url, allowedExtensions: [], permitsAnyFile: true)
                    where !session.files.contains(expanded) {
                        session.files.append(expanded)
                    }
                } else if !session.files.contains(url) {
                    session.files.append(url)
                }
            }
        }
        return true
    }
}

/// Each operation's own expandable, individually-toggled block. Expansion is
/// purely cosmetic — a collapsed block still applies if its checkbox is on.
private struct OperationBlock<Content: View>: View {
    let title: LocalizedStringKey
    @Binding var isEnabled: Bool
    let isBusy: Bool
    @ViewBuilder let content: () -> Content

    @State private var expanded = true

    /// The header is a hand-built row rather than a `DisclosureGroup`, and
    /// that is the whole point: a `Toggle` placed in a `DisclosureGroup`'s
    /// `label:` closure is not exposed to the accessibility layer at all.
    /// Verified by enumerating the window's accessibility tree — with the
    /// old structure, all six operation checkboxes and their titles were
    /// missing outright, leaving only the two sub-options that live inside
    /// the disclosure *content* ("Fall back to file modification date" and
    /// "Case sensitive"). VoiceOver could therefore not switch a single
    /// rename operation on or off, which made the section unusable. Splitting
    /// the row into a real expander button plus a real `Toggle` puts both
    /// back in the tree. Do not fold this back into a `DisclosureGroup`.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show or hide this operation's settings")

                Toggle(isOn: $isEnabled) {
                    Text(title).font(.callout.bold())
                }
                // Named explicitly rather than leaving it to the styled
                // `Text` inside the toggle. Unverified, unlike the rest of
                // this: System Events reports *every* checkbox in the app —
                // including ones this change never touched — as carrying no
                // AXTitle at all, so whether a name reaches VoiceOver is an
                // app-wide question to settle with Accessibility Inspector,
                // not something this file can answer on its own.
                .accessibilityLabel(Text(title))
            }

            if expanded {
                content()
                    .padding(.top, 8)
                    // Matches the indent DisclosureGroup gave the content
                    // before, so the blocks still read the same way.
                    .padding(.leading, 20)
                    .disabled(!isEnabled)
            }
        }
        .disabled(isBusy)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
