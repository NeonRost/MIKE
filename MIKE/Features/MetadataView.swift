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

struct MetadataView: View {
    let onOpenTools: () -> Void

    @EnvironmentObject private var tools: ToolRegistry

    @State private var sourceFile: URL?
    @State private var groups: [MetadataGroup] = []
    @State private var hasReadEmpty = false

    // Edit fields.
    @State private var copyright = ""
    @State private var artist = ""
    @State private var imageDescription = ""
    @State private var dateEnabled = false
    @State private var date = Date()
    @State private var latitudeText = ""
    @State private var longitudeText = ""

    @State private var isWorking = false
    @State private var status = ""
    @State private var statusKind = StatusLine.Kind.idle

    // The confirmation shown when a `_original` backup is already present.
    @State private var pendingAction: MetadataAction?

    private var canEdit: Bool { tools.isAvailable(.exiftool) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Metadata",
                    subtitle: "Shows the EXIF, GPS and other metadata in an image. With exiftool installed, common fields can be edited and metadata removed."
                )

                FileRow(
                    label: "Image file",
                    file: sourceFile,
                    isEnabled: !isWorking,
                    onChoose: chooseFile,
                    onClear: clearFile
                )

                if sourceFile != nil {
                    displaySection
                    Divider()
                    editSection
                    Divider()
                    removeSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "A backup already exists",
            isPresented: showingBackupConfirm,
            titleVisibility: .visible
        ) {
            Button("Continue without a new backup") {
                if let pendingAction { run(pendingAction) }
                pendingAction = nil
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("An unedited original is already saved next to this file from an earlier run. It will be kept, and this change is written without a second backup.")
        }
    }

    // MARK: - Display

    @ViewBuilder
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if groups.isEmpty {
                if hasReadEmpty {
                    Text("This image carries no readable metadata.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(groups) { group in
                    MetadataGroupView(group: group)
                }
            }
        }
    }

    // MARK: - Edit

    @ViewBuilder
    private var editSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit")
                .font(.headline)

            if !canEdit {
                unavailableNote(
                    "Editing metadata needs exiftool."
                )
            }

            Group {
                LabeledField(label: "Copyright", text: $copyright)
                LabeledField(label: "Artist", text: $artist)
                LabeledField(label: "Description", text: $imageDescription)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $dateEnabled) {
                        Text("Set capture date")
                    }
                    DatePicker(
                        selection: $date,
                        displayedComponents: [.date, .hourAndMinute]
                    ) { EmptyView() }
                    .labelsHidden()
                    .disabled(!dateEnabled)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("GPS coordinates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Latitude", text: $latitudeText)
                            .textFieldStyle(.roundedBorder)
                        TextField("Longitude", text: $longitudeText)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Decimal degrees, e.g. 47.3769 and 8.5417. South and West are negative.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!canEdit || isWorking)

            Text("Empty fields are left unchanged. Filled ones are written.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Apply changes") { start(.edit) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canEdit || isWorking)
                StatusLine(text: status, kind: statusKind)
            }
        }
    }

    // MARK: - Remove

    @ViewBuilder
    private var removeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remove")
                .font(.headline)
            Text("Removing writes the edited file and keeps the untouched original as a “_original” file next to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !canEdit {
                unavailableNote("Removing metadata needs exiftool.")
            }

            HStack(spacing: 12) {
                Button("Remove all metadata") { start(.removeAll) }
                    .disabled(!canEdit || isWorking)
                Button("Remove GPS only") { start(.removeGPS) }
                    .disabled(!canEdit || isWorking)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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

    // MARK: - Actions

    private var showingBackupConfirm: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )
    }

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
        reloadMetadata()
    }

    private func clearFile() {
        sourceFile = nil
        groups = []
        hasReadEmpty = false
        status = ""
        statusKind = .idle
    }

    private func reloadMetadata() {
        guard let sourceFile else { return }
        groups = ImageMetadata.read(from: sourceFile)
        hasReadEmpty = groups.isEmpty
    }

    /// Validates, then either runs straight away or asks first when a backup is
    /// already on disk.
    private func start(_ action: MetadataAction) {
        guard sourceFile != nil else { return }

        if action == .edit {
            switch coordinateInput {
            case .invalid:
                status = String(localized: "Enter both coordinates as numbers within ±90 and ±180.")
                statusKind = .failure
                return
            case .none, .valid:
                break
            }
        }

        guard let sourceFile else { return }
        // A backup already on disk means an earlier run's untouched original is
        // at stake — confirm before writing in place. Otherwise go straight
        // through; the writer creates the first backup itself.
        if MetadataWriter.backupExists(for: sourceFile) {
            pendingAction = action
        } else {
            run(action)
        }
    }

    private func run(_ action: MetadataAction) {
        guard let file = sourceFile, let exiftool = tools.status(for: .exiftool).url else { return }

        // Snapshot the inputs so the background task never reads @State.
        let edits = currentEdits
        let work: (URL) throws -> ExifWriteOutcome

        switch action {
        case .edit:
            guard edits.hasAnything else {
                status = String(localized: "Nothing to change — every field is empty.")
                statusKind = .idle
                return
            }
            work = { try MetadataWriter.apply(edits, to: $0, exiftool: exiftool) }
        case .removeAll:
            work = { try MetadataWriter.removeAll(from: $0, exiftool: exiftool) }
        case .removeGPS:
            work = { try MetadataWriter.removeGPS(from: $0, exiftool: exiftool) }
        }

        isWorking = true
        statusKind = .working
        status = String(localized: "Working…")

        Task {
            do {
                let result = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { continuation.resume(returning: try work(file)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                switch result {
                case .updated(let backup):
                    status = message(for: backup)
                    statusKind = .success
                    reloadMetadata()
                case .nothingToDo:
                    status = String(localized: "Nothing to change.")
                    statusKind = .idle
                }
            } catch {
                status = error.localizedDescription
                statusKind = .failure
            }
            isWorking = false
        }
    }

    private func message(for backup: BackupState) -> String {
        switch backup {
        case .created:
            return String(localized: "Done. The original was saved as a “_original” file next to it.")
        case .preserved:
            return String(localized: "Done. The existing “_original” backup was left untouched.")
        case .skipped:
            // Unreachable here: this section never sets `skipBackup`. Kept
            // exhaustive rather than a `default:` so a future change that
            // does pass it can't fall through silently.
            return String(localized: "Done.")
        }
    }

    // MARK: - Input gathering

    private var currentEdits: MetadataEdits {
        var edits = MetadataEdits()
        edits.copyright = copyright
        edits.artist = artist
        edits.imageDescription = imageDescription
        edits.dateTimeOriginal = dateEnabled ? date : nil
        if case .valid(let lat, let lon) = coordinateInput {
            edits.latitude = lat
            edits.longitude = lon
        }
        return edits
    }

    private enum CoordinateInput {
        case none
        case valid(Double, Double)
        case invalid
    }

    /// Both empty means "leave GPS alone"; one filled or an out-of-range value
    /// is a mistake worth stopping on.
    private var coordinateInput: CoordinateInput {
        let latRaw = latitudeText.trimmingCharacters(in: .whitespaces)
        let lonRaw = longitudeText.trimmingCharacters(in: .whitespaces)
        if latRaw.isEmpty && lonRaw.isEmpty { return .none }

        guard let lat = decimal(latRaw), let lon = decimal(lonRaw),
              (-90...90).contains(lat), (-180...180).contains(lon)
        else { return .invalid }
        return .valid(lat, lon)
    }

    /// Accepts a comma as the decimal separator too, since a German or Spanish
    /// keyboard yields one.
    private func decimal(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }
}

private enum MetadataAction {
    case edit
    case removeAll
    case removeGPS
}

// MARK: - Subviews

/// One EXIF/GPS/TIFF/IPTC block as a collapsible list. Tag names and values are
/// verbatim: they are the file's own data and the standard's vocabulary, not UI
/// copy to translate.
private struct MetadataGroupView: View {
    let group: MetadataGroup
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let location = group.location {
                    LocationView(location: location)
                    if !group.rows.isEmpty {
                        Divider().padding(.vertical, 2)
                    }
                }
                ForEach(group.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: row.label)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading)
                        Text(verbatim: row.value)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        } label: {
            Text(verbatim: group.title)
                .font(.headline)
        }
    }
}

/// The derived, readable location line that leads the GPS group.
private struct LocationView: View {
    let location: LocationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Coordinates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: location.decimal)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            Text(verbatim: location.dms)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let altitude = location.altitude {
                HStack(spacing: 8) {
                    Text("Altitude")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(verbatim: altitude)
                        .font(.caption2)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct LabeledField: View {
    let label: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(text: $text) { EmptyView() }
                .textFieldStyle(.roundedBorder)
        }
    }
}
