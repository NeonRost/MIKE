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

/// Folder picker row, styled like the save-location row: path first, quiet
/// button second. Shared by Combine Images and Convert Format's batch mode.
struct FolderRow: View {
    let folder: URL?
    let detail: String?
    var isEnabled: Bool = true
    let onChoose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let folder {
                    Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("No folder selected")
                        .foregroundStyle(.secondary)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("Choose…", action: onChoose)
                .disabled(!isEnabled)
        }
    }
}
