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

/// Where a combine section takes its input from.
enum CombineSource: String, CaseIterable, Identifiable {
    case folder = "Folder"
    case files = "Files"

    var id: String { rawValue }

    /// The raw value is a stable key; this is what the picker shows.
    var title: LocalizedStringKey {
        switch self {
        case .folder: return "Folder"
        case .files: return "Files"
        }
    }
}

/// Hand-picked, hand-ordered list of files, shared by both combine sections.
///
/// The list order is the output order — that is the point of picking files
/// individually rather than handing over a folder.
struct FileListEditor: View {
    @Binding var files: [URL]
    let allowedExtensions: Set<String>
    /// Passed in fully formed rather than composed from a noun — languages do
    /// not build "Add images…" the same way.
    let emptyMessage: LocalizedStringKey
    let addTitle: LocalizedStringKey
    var isEnabled: Bool = true
    /// When true, the picker accepts any file regardless of extension — for
    /// consumers whose input is plain text with no reliable, listable set of
    /// extensions (e.g. Merge Texts' "general text files with no extension").
    /// `allowedExtensions` still describes what belongs in the list, but no
    /// longer gates what the panel shows or what a pick is allowed to be.
    var permitsAnyFile: Bool = false
    /// When true, the picker also accepts folders — each chosen folder is
    /// expanded into the files directly inside it (no subfolders) via
    /// `expand(folder:allowedExtensions:permitsAnyFile:)`. Off by default so
    /// every existing consumer keeps picking files only.
    var permitsFolders: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if files.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 12)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            } else {
                // Fixed height on purpose: a List inside the section's scroll
                // view must not negotiate its own height.
                List {
                    ForEach(Array(files.enumerated()), id: \.element) { index, url in
                        HStack(spacing: 8) {
                            Text(verbatim: "\(index + 1).")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 22, alignment: .trailing)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(url.path)
                            Spacer(minLength: 8)
                            Button {
                                files.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                    .onMove { source, destination in
                        files.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button(addTitle) { add() }
                Button("Sort by Name") { sortNaturally() }
                    .disabled(files.count < 2)
                Button("Clear") { files.removeAll() }
                    .disabled(files.isEmpty)
                if files.count > 1 {
                    Text("Drag to reorder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!isEnabled)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = permitsFolders
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", comment: "Confirm button in the file picker")
        if !permitsAnyFile {
            panel.allowedContentTypes = allowedExtensions.compactMap {
                UTType(filenameExtension: $0)
            }
        }
        guard panel.runModal() == .OK else { return }

        // Appending rather than replacing, so files can be collected from
        // several folders in a row.
        for url in panel.urls {
            var isDirectory: ObjCBool = false
            if permitsFolders,
               FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                for expanded in Self.expand(folder: url, allowedExtensions: allowedExtensions, permitsAnyFile: permitsAnyFile)
                where !files.contains(expanded) {
                    files.append(expanded)
                }
            } else if (permitsAnyFile || allowedExtensions.contains(url.pathExtension.lowercased()))
                && !files.contains(url) {
                files.append(url)
            }
        }
    }

    private func sortNaturally() {
        files.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
    }

    /// Non-recursive: a folder's own subfolders are skipped entirely rather
    /// than descended into, matching the "no subfolders" rule callers rely on.
    static func expand(folder: URL, allowedExtensions: Set<String>, permitsAnyFile: Bool) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
            return permitsAnyFile || allowedExtensions.contains(url.pathExtension.lowercased())
        }
    }
}
