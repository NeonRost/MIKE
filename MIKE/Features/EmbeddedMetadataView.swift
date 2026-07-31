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

/// A working copy of one entry, holding the edit state before the batch write.
struct EditRow: Identifiable {
    let id = UUID()
    var key: String
    var originalValue: String
    var currentValue: String
    var writeTag: String?
    var pngKeyword: String?
    var source: String
    var kind: EmbeddedValueKind
    var prettyValue: String?
    var byteSize: Int?
    var structured: Bool
    var isNew: Bool = false
    var deleted: Bool = false
    var isEditing: Bool = false

    var isEditable: Bool { writeTag != nil && !structured && kind != .binary }
    var isDeletable: Bool { writeTag != nil }
    var isModified: Bool { !isNew && currentValue != originalValue }
    var characterCount: Int { currentValue.count }
    var approximateTokens: Int { max(1, (currentValue.count + 3) / 4) }
}

struct EditGroup: Identifiable {
    let id = UUID()
    var title: String
    var kind: EmbeddedGroupKind
    var allowsAdditions: Bool
    var rows: [EditRow]
    var newKey: String = ""
    var newValue: String = ""
    var addError: String?
}

struct EmbeddedMetadataView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry

    @State private var sourceFile: URL?
    @State private var groups: [EditGroup] = []
    @State private var readResult: EmbeddedReadResult?
    @State private var hasReadEmpty = false

    @State private var isWorking = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle
    @State private var showBackupConfirm = false

    /// Values longer than this are collapsed by default so a huge ComfyUI
    /// `workflow` does not unfurl thousands of lines at once.
    private static let longValueThreshold = 800

    private var canEdit: Bool { tools.isAvailable(.exiftool) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Embedded",
                    subtitle: "Shows and edits embedded text blocks that the Metadata section does not: PNG text chunks, XMP packets and other blocks outside the EXIF group."
                )

                FileRow(
                    label: "Image file",
                    file: sourceFile,
                    isEnabled: !isWorking,
                    onChoose: chooseFile,
                    onClear: clearFile
                )

                if sourceFile != nil {
                    notes
                    ForEach($groups) { $group in
                        GroupView(
                            group: $group,
                            canEdit: canEdit,
                            longThreshold: Self.longValueThreshold
                        )
                    }
                    if canEdit {
                        writeBar
                    } else {
                        unavailableNote("Editing and removing embedded blocks needs exiftool.")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "A backup already exists",
            isPresented: $showBackupConfirm,
            titleVisibility: .visible
        ) {
            Button("Continue without a new backup") { performWrite() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An unedited original is already saved next to this file from an earlier run. It will be kept, and this change is written without a second backup.")
        }
    }

    // MARK: - Notes

    @ViewBuilder
    private var notes: some View {
        if let result = readResult {
            switch result.format {
            case .unsupported:
                infoNote("This format does not carry embedded text blocks of this kind.")
            case .exiftoolFormat, .unknown:
                if result.limitedByMissingExiftool {
                    unavailableNote("Reading embedded blocks in this format needs exiftool.")
                }
            case .png:
                EmptyView()
            }

            if result.xmpNeedsExiftool {
                unavailableNote("This PNG has an XMP packet — install exiftool to show it structured.")
            }
            if let size = result.exifChunkByteSize {
                infoNote("An eXIf chunk is present (\(byteString(size))). Its EXIF content is shown in the Metadata section.")
            }
            if result.format == .png, hasReadEmpty {
                infoNote("No embedded text blocks found. You can add one below.")
            }
        }
    }

    @ViewBuilder
    private func infoNote(_ message: LocalizedStringKey) -> some View {
        Label(message, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func unavailableNote(_ message: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Setup", action: onOpenTools)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    // MARK: - Write bar

    @ViewBuilder
    private var writeBar: some View {
        Divider()
        HStack(spacing: 12) {
            Button("Write changes") { start() }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || !hasPendingChanges)
            if hasPendingChanges {
                Text("\(pendingCount) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            StatusLine(text: status, kind: statusKind)
        }
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the file picker")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        sourceFile = chosen
        status = ""
        statusKind = .idle
        reload()
    }

    private func clearFile() {
        sourceFile = nil
        groups = []
        readResult = nil
        hasReadEmpty = false
        status = ""
        statusKind = .idle
    }

    private func reload() {
        guard let sourceFile else { return }
        let exiftool = tools.status(for: .exiftool).url
        let result = EmbeddedMetadata.read(from: sourceFile, exiftool: exiftool)
        readResult = result
        groups = result.groups.map(editGroup(from:))
        // "Empty" ignores the always-present, possibly-empty PNG text group.
        hasReadEmpty = result.groups.allSatisfy { $0.entries.isEmpty }
    }

    private func editGroup(from group: EmbeddedGroup) -> EditGroup {
        EditGroup(
            title: group.title,
            kind: group.kind,
            allowsAdditions: group.allowsAdditions,
            rows: group.entries.map { entry in
                EditRow(
                    key: entry.key,
                    originalValue: entry.rawValue,
                    currentValue: entry.rawValue,
                    writeTag: entry.writeTag,
                    pngKeyword: entry.writeTag?.hasPrefix("PNG:") == true ? entry.key : nil,
                    source: entry.source,
                    kind: entry.kind,
                    prettyValue: entry.prettyValue,
                    byteSize: entry.byteSize,
                    structured: entry.structured
                )
            }
        )
    }

    private var pendingOps: [EmbeddedWriteOp] {
        var ops: [EmbeddedWriteOp] = []
        for group in groups {
            for row in group.rows {
                guard let writeTag = row.writeTag else { continue }
                if row.isNew {
                    guard !row.deleted else { continue }
                    let key = row.key.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty, !row.currentValue.isEmpty else { continue }
                    ops.append(EmbeddedWriteOp(writeTag: "PNG:\(key)", pngKeyword: key, value: row.currentValue))
                } else if row.deleted {
                    ops.append(EmbeddedWriteOp(writeTag: writeTag, pngKeyword: row.pngKeyword, value: nil))
                } else if row.isModified {
                    ops.append(EmbeddedWriteOp(writeTag: writeTag, pngKeyword: row.pngKeyword, value: row.currentValue))
                }
            }
        }
        return ops
    }

    private var hasPendingChanges: Bool { !pendingOps.isEmpty }
    private var pendingCount: Int { pendingOps.count }

    private func start() {
        guard let sourceFile, hasPendingChanges else { return }
        if ExifToolWrite.backupExists(for: sourceFile) {
            showBackupConfirm = true
        } else {
            performWrite()
        }
    }

    private func performWrite() {
        guard let file = sourceFile, let exiftool = tools.status(for: .exiftool).url else { return }
        let ops = pendingOps
        guard !ops.isEmpty else { return }

        isWorking = true
        statusKind = .working
        status = String(localized: "Writing…")

        Task {
            do {
                let result = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { continuation.resume(returning: try EmbeddedMetadataWriter.write(ops, to: file, exiftool: exiftool)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                switch result {
                case .updated(let backup):
                    status = backup == .created
                        ? String(localized: "Done. The original was saved as a “_original” file next to it.")
                        : String(localized: "Done. The existing “_original” backup was left untouched.")
                    statusKind = .success
                    reload()
                case .nothingToDo:
                    status = String(localized: "Nothing changed.")
                    statusKind = .idle
                }
            } catch {
                status = error.localizedDescription
                statusKind = .failure
            }
            isWorking = false
        }
    }

    private func byteString(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(count))
    }
}

// MARK: - Group

private struct GroupView: View {
    @Binding var group: EditGroup
    let canEdit: Bool
    let longThreshold: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: group.title)
                    .font(.headline)
                Spacer()
                if canEdit, group.rows.contains(where: { $0.isDeletable && !$0.deleted && !$0.isNew }) {
                    Button("Delete all") {
                        for index in group.rows.indices where !group.rows[index].isNew {
                            group.rows[index].deleted = true
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if group.rows.isEmpty {
                Text("No entries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach($group.rows) { $row in
                RowView(row: $row, canEdit: canEdit, longThreshold: longThreshold)
                Divider()
            }

            if group.allowsAdditions, canEdit {
                addForm
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add entry")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Key", text: $group.newKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                TextField("Value", text: $group.newValue)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addEntry() }
                    .disabled(group.newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = group.addError {
                Text(verbatim: error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Text("Keys use letters, numbers and hyphens. Changes are written when you press “Write changes”.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func addEntry() {
        let key = group.newKey.trimmingCharacters(in: .whitespaces)
        guard EmbeddedMetadataWriter.isValidKey(key) else {
            group.addError = String(
                localized: "“\(key)” is not a valid key. Use letters, numbers and hyphens only.",
                comment: "Rejected metadata key. Placeholder is the entered key."
            )
            return
        }
        group.addError = nil
        group.rows.append(EditRow(
            key: key,
            originalValue: "",
            currentValue: group.newValue,
            writeTag: "PNG:\(key)",
            pngKeyword: key,
            source: "tEXt",
            kind: .text,
            prettyValue: nil,
            byteSize: nil,
            structured: false,
            isNew: true
        ))
        group.newKey = ""
        group.newValue = ""
    }
}

// MARK: - Row

private struct RowView: View {
    @Binding var row: EditRow
    let canEdit: Bool
    let longThreshold: Int

    @State private var expanded = false

    private var isLong: Bool { row.currentValue.count > longThreshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            valueArea
        }
        .opacity(row.deleted ? 0.5 : 1)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: row.key.isEmpty ? "—" : row.key)
                .font(.callout.monospaced().bold())
            Text(verbatim: row.source)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if row.isNew {
                tag("new")
            }
            if row.isModified {
                tag("edited")
            }
            Spacer()
            if isLong {
                Text("\(row.characterCount) chars · ≈\(row.approximateTokens) tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if canEdit { controls }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if row.deleted {
            Button("Undo") { row.deleted = false }
                .buttonStyle(.link)
                .font(.caption)
        } else {
            if row.isEditable {
                Button(row.isEditing ? "Done" : "Edit") { row.isEditing.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if row.isDeletable {
                Button("Delete") { row.deleted = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var valueArea: some View {
        if row.deleted {
            Text("Will be deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        } else if row.isEditing {
            editor
        } else {
            display
        }
    }

    @ViewBuilder
    private var editor: some View {
        TextEditor(text: $row.currentValue)
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 60, maxHeight: 260)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
    }

    @ViewBuilder
    private var display: some View {
        if row.kind == .binary, let size = row.byteSize {
            Text(verbatim: "\(size) bytes")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isLong {
            DisclosureGroup(isExpanded: $expanded) {
                valueText
            } label: {
                Text("Show value (\(row.characterCount) characters)")
                    .font(.caption)
            }
        } else {
            valueText
        }
    }

    /// Laying out a single SwiftUI `Text` of a whole ComfyUI `workflow` — tens
    /// of thousands of characters over thousands of lines — janks on expand, so
    /// the display is capped here. The full value is untouched in `currentValue`
    /// and reachable through Edit; only what is drawn is trimmed.
    private static let displayCap = 5000

    @ViewBuilder
    private var valueText: some View {
        // JSON is pretty-printed for reading; the raw string is what gets
        // written. Editing shows the raw value, not this display copy.
        let full = (row.kind == .json && !row.isModified ? row.prettyValue : nil) ?? row.currentValue
        let capped = full.count > Self.displayCap
        let shown = capped ? String(full.prefix(Self.displayCap)) : full
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: shown)
                    .font(.system(.caption, design: row.kind == .json ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // A double-click on the value opens the editor, as asked.
                    .onTapGesture(count: 2) {
                        if canEdit, row.isEditable { row.isEditing = true }
                    }
                if capped {
                    Text("Preview truncated — open Edit to see or change the full value.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: isLong ? 300 : .infinity)
    }

    private func tag(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.15), in: Capsule())
    }
}
