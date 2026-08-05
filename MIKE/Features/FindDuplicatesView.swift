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

enum SearchPhase: Equatable {
    case scanning(current: Int, total: Int)
    case comparing(current: Int, total: Int)
}

/// Survives navigating away from and back to Find Duplicates — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class FindDuplicatesSession: ObservableObject {
    @Published var folders: [URL] = []
    @Published var includeSubfolders = true
    @Published var isSearching = false
    @Published var phase: SearchPhase?
    @Published var groups: [DuplicateGroup] = []
    @Published var showTrashConfirmation = false
    @Published var isTrashing = false
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    private var searchTask: Task<Void, Never>?

    var hasResults: Bool { !groups.isEmpty }

    var trashCount: Int {
        groups.reduce(0) { $0 + $1.files.filter { !$0.keep }.count }
    }

    private var trashBytes: Int64 {
        groups.reduce(Int64(0)) { total, group in
            total + Int64(group.files.filter { !$0.keep }.count) * group.fileSize
        }
    }

    var summaryText: String {
        String(
            localized: "Found \(groups.count) duplicate groups — \(trashCount) files can be removed, saving \(Self.byteString(trashBytes))",
            comment: "Placeholders: group count, removable file count, human-readable size such as 234 MB"
        )
    }

    static func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Folders

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", comment: "Confirm button in the folder picker")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFolder(url) }
    }

    func addFolder(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
    }

    // MARK: - Search

    func find() {
        guard !folders.isEmpty, !isSearching else { return }
        let inputFolders = folders
        let recursive = includeSubfolders

        isSearching = true
        groups = []
        phase = nil
        status = ""
        statusKind = .working

        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let files = DuplicateFinder.collectFiles(in: inputFolders, includeSubfolders: recursive)
            do {
                let result = try DuplicateFinder.findDuplicates(
                    files: files,
                    onScanProgress: { current, total in
                        DispatchQueue.main.async { self?.phase = .scanning(current: current, total: total) }
                    },
                    onCompareProgress: { current, total in
                        DispatchQueue.main.async { self?.phase = .comparing(current: current, total: total) }
                    },
                    isCancelled: { Task.isCancelled }
                )
                await MainActor.run {
                    guard let self else { return }
                    self.groups = result
                    self.isSearching = false
                    self.phase = nil
                    self.status = result.isEmpty ? String(localized: "No duplicates found.") : ""
                    self.statusKind = .idle
                }
            } catch {
                // Cancellation only ever throws `DuplicateFinderError.cancelled`
                // — either way, no partial results are kept.
                await MainActor.run {
                    guard let self else { return }
                    self.isSearching = false
                    self.phase = nil
                    self.groups = []
                    self.status = String(localized: "Cancelled.")
                    self.statusKind = .idle
                }
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
    }

    // MARK: - Keep / Trash selection

    func selectAllDuplicates() {
        for groupIndex in groups.indices {
            let files = groups[groupIndex].files
            guard let oldest = files.indices.min(by: {
                (files[$0].modified ?? .distantFuture) < (files[$1].modified ?? .distantFuture)
            }) else { continue }
            for fileIndex in groups[groupIndex].files.indices {
                groups[groupIndex].files[fileIndex].keep = (fileIndex == oldest)
            }
        }
    }

    func deselectAll() {
        for groupIndex in groups.indices {
            for fileIndex in groups[groupIndex].files.indices {
                groups[groupIndex].files[fileIndex].keep = true
            }
        }
    }

    // MARK: - Trash

    func confirmMoveToTrash() {
        guard trashCount > 0 else { return }
        showTrashConfirmation = true
    }

    func moveToTrash() {
        let toTrash = groups.flatMap { group in group.files.filter { !$0.keep }.map(\.url) }
        guard !toTrash.isEmpty else { return }

        isTrashing = true
        statusKind = .working
        status = String(localized: "Moving to Trash…")

        Task.detached(priority: .userInitiated) { [weak self] in
            var succeeded: [URL] = []
            var failures: [(name: String, error: String)] = []
            for url in toTrash {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    succeeded.append(url)
                } catch {
                    failures.append((url.lastPathComponent, error.localizedDescription))
                }
            }

            await MainActor.run {
                guard let self else { return }
                let succeededSet = Set(succeeded)
                for index in self.groups.indices {
                    self.groups[index].files.removeAll { succeededSet.contains($0.url) }
                }
                // A group with one file left is no longer a duplicate.
                self.groups.removeAll { $0.files.count <= 1 }

                self.isTrashing = false
                if failures.isEmpty {
                    self.status = String(
                        localized: "Done. \(succeeded.count) files moved to Trash.",
                        comment: "Placeholder is a count of files"
                    )
                    self.statusKind = .success
                } else {
                    let list = ListFormatter.localizedString(byJoining: failures.map(\.name))
                    self.status = String(
                        localized: "Done. \(succeeded.count) moved, \(failures.count) failed: \(list)",
                        comment: "Placeholders: succeeded count, failed count, comma-separated file names"
                    )
                    self.statusKind = .failure
                }
            }
        }
    }

    func clear() {
        guard !isSearching, !isTrashing else { return }
        searchTask?.cancel()
        folders = []
        includeSubfolders = true
        phase = nil
        groups = []
        showTrashConfirmation = false
        status = ""
        statusKind = .idle
    }
}

struct FindDuplicatesView: View {
    @ObservedObject var session: FindDuplicatesSession

    @State private var isDropTargeted = false

    private var canClear: Bool {
        !session.isSearching && !session.isTrashing && !(session.folders.isEmpty && session.groups.isEmpty)
    }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Find Duplicates",
                    subtitle: "Finds identical files across one or more folders by size and then by content, so nothing is judged a duplicate by name alone."
                )

                folderListSection
                searchControls

                if session.hasResults {
                    resultsSection
                    trashSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Move \(session.trashCount) files to Trash?",
            isPresented: $session.showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { session.moveToTrash() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Folders

    @ViewBuilder
    private var folderListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.folders.isEmpty {
                Text("No folders selected. Add one or more, or drag them in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(session.folders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button {
                                session.removeFolder(folder)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 12) {
                Button("Choose Folder…") { session.chooseFolder() }
                Button("Clear") { session.clear() }
                    .disabled(!canClear)
            }

            Toggle("Include subfolders", isOn: $session.includeSubfolders)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .disabled(session.isSearching)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isSearching, !providers.isEmpty else { return false }

        let group = DispatchGroup()
        // Collected on a lock, not `folders` directly: `loadItem`'s completion
        // handlers arrive on an arbitrary queue, never the main actor.
        let collected = FindDuplicatesDropCollector()

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
                guard let url else { return }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
                else { return }
                collected.append(url)
            }
        }

        group.notify(queue: .main) {
            for url in collected.value {
                session.addFolder(url)
            }
        }
        return true
    }

    // MARK: - Search controls

    @ViewBuilder
    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("Find Duplicates") { session.find() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.folders.isEmpty || session.isSearching)
                if session.isSearching {
                    Button("Cancel") { session.cancel() }
                }
                StatusLine(text: session.status, kind: session.statusKind)
            }
            if let phase = session.phase {
                progressView(phase)
            }
        }
    }

    @ViewBuilder
    private func progressView(_ phase: SearchPhase) -> some View {
        switch phase {
        case .scanning(let current, let total):
            VStack(alignment: .leading, spacing: 4) {
                Text("Scanning files… \(current) of \(total)", comment: "Progress while reading file sizes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(current), total: Double(max(total, 1)))
                    .frame(maxWidth: 280)
            }
        case .comparing(let current, let total):
            VStack(alignment: .leading, spacing: 4) {
                Text("Comparing… \(current) of \(total)", comment: "Progress while hashing same-size candidate files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(current), total: Double(max(total, 1)))
                    .frame(maxWidth: 280)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(verbatim: session.summaryText)
                    .font(.callout.bold())
                Spacer(minLength: 8)
                Button("Select all duplicates") { session.selectAllDuplicates() }
                    .buttonStyle(.link)
                    .font(.caption)
                Button("Deselect all") { session.deselectAll() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach($session.groups) { $group in
                DuplicateGroupView(group: $group)
            }
        }
    }

    @ViewBuilder
    private var trashSection: some View {
        HStack(spacing: 12) {
            Button("Move to Trash") { session.confirmMoveToTrash() }
                .buttonStyle(.borderedProminent)
                .disabled(session.trashCount == 0 || session.isTrashing)
            if session.isTrashing {
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Subviews

private struct DuplicateGroupView: View {
    @Binding var group: DuplicateGroup
    @State private var expanded = true

    private var wastedBytes: Int64 {
        Int64(group.files.count - 1) * group.fileSize
    }

    private var headerText: String {
        let name = group.files.first?.url.lastPathComponent ?? ""
        return String(
            localized: "\(name) (\(group.files.count) copies, \(FindDuplicatesSession.byteString(group.fileSize)) each — \(FindDuplicatesSession.byteString(wastedBytes)) wasted)",
            comment: "Placeholders: representative file name, copy count, size per copy, total wasted size"
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($group.files) { $file in
                    DuplicateFileRow(file: $file, group: group)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        } label: {
            Text(verbatim: headerText)
                .font(.callout.bold())
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DuplicateFileRow: View {
    @Binding var file: DuplicateFile
    let group: DuplicateGroup

    private var isLastKeep: Bool {
        file.keep && group.files.filter(\.keep).count == 1
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.url.path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let modified = file.modified {
                    Text(verbatim: modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Picker(selection: $file.keep) {
                Text("Keep").tag(true)
                Text("Trash").tag(false)
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)
            .disabled(isLastKeep)
        }
    }
}

/// Minimal mutable box guarded by a lock, for collecting drop results that
/// arrive on an arbitrary queue before handing them to the main actor.
private final class FindDuplicatesDropCollector {
    private var storage: [URL] = []
    private let lock = NSLock()

    var value: [URL] { lock.lock(); defer { lock.unlock() }; return storage }

    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        storage.append(url)
    }
}
