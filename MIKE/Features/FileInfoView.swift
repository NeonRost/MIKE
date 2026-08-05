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

/// Survives navigating away from and back to File Info — see
/// `ArticleExtractionSession` for why this is needed at all.
@MainActor
final class FileInfoSession: ObservableObject {
    @Published var sourceFile: URL?
    @Published var isLoading = false
    @Published var general: FileInfoGeneral?
    @Published var xattrs: [XAttrEntry] = []
    @Published var permissions: FileInfoPermissions?
    @Published var finder: FileInfoFinder?
    @Published var status = ""
    @Published var statusKind = StatusLine.Kind.idle

    var hasQuarantine: Bool { xattrs.contains { $0.key == FileInfoReader.quarantineKey } }

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
        sourceFile = url
        general = nil
        xattrs = []
        permissions = nil
        finder = nil
        status = ""
        statusKind = .idle
        isLoading = true

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = FileInfoReader.read(url: url)
            await MainActor.run {
                guard let self, self.sourceFile == url else { return }
                self.general = result.general
                self.xattrs = result.xattrs
                self.permissions = result.permissions
                self.finder = result.finder
                self.isLoading = false
            }
        }
    }

    func rejectFolder() {
        status = String(localized: "Folders are not supported.")
        statusKind = .idle
    }

    func removeQuarantine() {
        guard let sourceFile else { return }
        let path = sourceFile.path

        Task.detached(priority: .userInitiated) { [weak self] in
            let removed = XAttr.remove(name: FileInfoReader.quarantineKey, atPath: path)
            await MainActor.run {
                guard let self, self.sourceFile?.path == path else { return }
                if removed {
                    self.xattrs.removeAll { $0.key == FileInfoReader.quarantineKey }
                    self.status = String(localized: "Quarantine removed.")
                    self.statusKind = .success
                } else {
                    self.status = String(localized: "Could not remove the quarantine flag.")
                    self.statusKind = .failure
                }
            }
        }
    }

    func clear() {
        guard !isLoading else { return }
        sourceFile = nil
        general = nil
        xattrs = []
        permissions = nil
        finder = nil
        status = ""
        statusKind = .idle
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct FileInfoView: View {
    @ObservedObject var session: FileInfoSession

    @State private var isDropTargeted = false

    private var canClear: Bool { !session.isLoading && session.sourceFile != nil }

    var body: some View {
        // The ScrollView matters beyond overflow: without it the detail column
        // sizes itself to the content's ideal height and spills out of the
        // window instead of being clamped to it.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "File Info",
                    subtitle: "Shows everything macOS knows about a file: size, type, extended attributes, permissions and Finder details."
                )

                HStack(spacing: 12) {
                    fileRow
                    Spacer(minLength: 0)
                    Button("Clear") { session.clear() }
                        .disabled(!canClear)
                }

                if session.isLoading {
                    ProgressView().controlSize(.small)
                }

                if let general = session.general {
                    InfoGroupView(title: "General") { generalRows(general) }
                    InfoGroupView(title: "Extended Attributes") { extendedAttributesContent }
                    if let permissions = session.permissions {
                        InfoGroupView(title: "Permissions") { permissionsRows(permissions) }
                    }
                    if let finder = session.finder {
                        InfoGroupView(title: "Finder") { finderRows(finder) }
                    }
                }

                StatusLine(text: session.status, kind: session.statusKind)
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
            isEnabled: !session.isLoading,
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

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !session.isLoading, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
            DispatchQueue.main.async {
                if isDirectory.boolValue {
                    session.rejectFolder()
                } else {
                    session.load(url)
                }
            }
        }
        return true
    }

    // MARK: - General

    @ViewBuilder
    private func generalRows(_ general: FileInfoGeneral) -> some View {
        InfoRow(label: "Name", value: general.name, onCopy: session.copy)
        InfoRow(label: "Path", value: general.path, onCopy: session.copy)
        InfoRow(label: "Size", value: sizeText(general.sizeBytes), onCopy: session.copy)
        if let mimeType = general.mimeType {
            InfoRow(label: "Type", value: mimeType, onCopy: session.copy)
        }
        if let created = general.created {
            InfoRow(label: "Created", value: dateText(created), onCopy: session.copy)
        }
        if let modified = general.modified {
            InfoRow(label: "Modified", value: dateText(modified), onCopy: session.copy)
        }
        if let accessed = general.accessed {
            InfoRow(label: "Last Opened", value: dateText(accessed), onCopy: session.copy)
        }
    }

    private func sizeText(_ bytes: Int64) -> String {
        let human = ByteCountFormatter()
        human.countStyle = .binary
        let exactFormatter = NumberFormatter()
        exactFormatter.numberStyle = .decimal
        let exact = exactFormatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)"
        return String(
            localized: "\(human.string(fromByteCount: bytes)) (\(exact) bytes)",
            comment: "Placeholders: human-readable size such as 4.2 MB, then the exact byte count"
        )
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Extended Attributes

    @ViewBuilder
    private var extendedAttributesContent: some View {
        if session.hasQuarantine {
            quarantineBanner
        }
        if session.xattrs.isEmpty {
            Text("No extended attributes")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(session.xattrs) { entry in
                xattrRow(entry)
            }
        }
    }

    @ViewBuilder
    private var quarantineBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("This file is quarantined by macOS. Click Remove to allow it to open.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Remove") { session.removeQuarantine() }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func xattrRow(_ entry: XAttrEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: entry.key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 220, alignment: .leading)
            Text(verbatim: entry.displayValue)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if entry.isRemovable {
                Button("Remove") { session.removeQuarantine() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Button {
                session.copy(entry.displayValue)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture { session.copy(entry.displayValue) }
    }

    // MARK: - Permissions

    @ViewBuilder
    private func permissionsRows(_ permissions: FileInfoPermissions) -> some View {
        if let owner = permissions.owner {
            InfoRow(label: "Owner", value: owner, onCopy: session.copy)
        }
        if let group = permissions.group {
            InfoRow(label: "Group", value: group, onCopy: session.copy)
        }
        InfoRow(
            label: "Permissions",
            value: "\(permissions.octal) (\(permissions.symbolic))",
            onCopy: session.copy
        )
        InfoRow(
            label: "Executable",
            value: permissions.executable ? String(localized: "Yes") : String(localized: "No"),
            onCopy: session.copy
        )
    }

    // MARK: - Finder

    @ViewBuilder
    private func finderRows(_ finder: FileInfoFinder) -> some View {
        if !finder.tags.isEmpty {
            InfoRow(label: "Tags", value: finder.tags.joined(separator: ", "), onCopy: session.copy)
        }
        if let whereFrom = finder.whereFrom {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Downloaded From")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Link(destination: whereFrom) {
                    Text(verbatim: whereFrom.absoluteString)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
            }
        }
        if let comment = finder.comment, !comment.isEmpty {
            InfoRow(label: "Comment", value: comment, onCopy: session.copy)
        }
    }
}

// MARK: - Subviews

/// One aufklappbare (collapsible) group of key/value rows — mirrors
/// `MetadataGroupView` in `MetadataView.swift`.
private struct InfoGroupView<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        } label: {
            Text(title).font(.headline)
        }
    }
}

/// One label/value row, copyable by clicking the row or the small button.
private struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String
    let onCopy: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(verbatim: value)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                onCopy(value)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture { onCopy(value) }
    }
}
