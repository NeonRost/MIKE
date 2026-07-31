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

struct ToolsView: View {
    @EnvironmentObject private var tools: ToolRegistry

    private static let brewCommand = "brew install yt-dlp ffmpeg webp exiftool"
    /// Homebrew's own published installer, verbatim from brew.sh. MIKE only
    /// offers it for copying — running a remote script is the user's call, in
    /// their own Terminal.
    private static let brewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
    private static let homebrewSite = URL(string: "https://brew.sh")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    title: "Setup",
                    subtitle: "MIKE uses these tools from your system. They are not bundled, so they stay up to date through your package manager."
                )

                ForEach(Tool.allCases) { tool in
                    ToolStatusCard(tool: tool, status: tools.status(for: tool))
                }

                Divider()

                homebrewBlock

                VStack(alignment: .leading, spacing: 6) {
                    Text("Without Homebrew")
                        .font(.headline)
                    Text("Each tool is also available as a standalone binary. Download one, put it anywhere you like, and enter its full path above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Four links no longer fit on one line at the narrow
                    // detail width, so they wrap instead of being squeezed.
                    FlowingLinks {
                        Link("yt-dlp releases", destination: Tool.ytDlp.downloadPage)
                        Link("ffmpeg downloads", destination: Tool.ffmpeg.downloadPage)
                        Link("cwebp downloads", destination: Tool.cwebp.downloadPage)
                        Link("exiftool downloads", destination: Tool.exiftool.downloadPage)
                    }
                    .font(.callout)
                }

                HStack {
                    Button("Check again") { tools.refresh(force: true) }
                    if tools.isChecking {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The `brew install` line only helps if Homebrew is actually there, so
    /// the block says which of the two situations the user is in.
    @ViewBuilder
    private var homebrewBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install with Homebrew")
                .font(.headline)

            if tools.homebrew.isAvailable {
                Label {
                    if let version = tools.homebrew.version {
                        Text("Homebrew \(version) is installed.")
                    } else {
                        Text("Homebrew is installed.")
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                CommandRow(command: Self.brewCommand)
            } else {
                Label(
                    "Homebrew is not installed, so the command below would not work yet.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

                Text("Set it up first — this is the official installer from brew.sh. Paste it into Terminal and follow the prompts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                CommandRow(command: Self.brewInstallCommand)

                Link("Check the command on brew.sh", destination: Self.homebrewSite)
                    .font(.caption)

                Text("Then install the tools:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                CommandRow(command: Self.brewCommand)
            }
        }
    }
}

/// A shell command in a box with its own copy button. Each row tracks its own
/// "Copied" feedback, so two of them on screen do not confuse each other.
private struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(verbatim: command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            Button(copied ? "Copied" : "Copy command") {
                WebURL.copyToClipboard(command)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .fixedSize()
        }
    }
}

/// Lays its children out left to right and wraps to the next line when the row
/// is full. Used for the download links, which no longer fit on one line once
/// there are four of them at the narrow detail width.
private struct FlowingLinks: Layout {
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct ToolStatusCard: View {
    let tool: Tool
    let status: ToolStatus

    @EnvironmentObject private var tools: ToolRegistry
    @FocusState private var pathFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(
                        status.isAvailable ? Color.green : (tool.isOptional ? Color.secondary : Color.red)
                    )
                Text(tool.executableName)
                    .font(.headline)
                if let version = status.version {
                    Text(version)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let purpose = tool.purpose {
                Text(purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let url = status.url {
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if tool == .ffmpeg, status.isAvailable, !status.supportsWebP {
                Label(
                    "This ffmpeg was built without WebP support — cwebp handles WebP export instead.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if status.customPathFailed {
                Label(
                    "The custom path below does not run — using the standard location instead.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack {
                TextField(
                    "Custom path (optional)",
                    text: tools.binding(for: tool)
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .focused($pathFieldFocused)
                // Saved when the entry is finished — on Return, or when the
                // field is left — rather than on every keystroke.
                .onSubmit {
                    tools.commitCustomPaths()
                    tools.refresh(force: true)
                }
                .onChange(of: pathFieldFocused) { focused in
                    if !focused {
                        tools.commitCustomPaths()
                        tools.refresh(force: true)
                    }
                }

                Button("Choose…") { chooseBinary() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Choose", comment: "Confirm button in the binary picker")
        if panel.runModal() == .OK, let chosen = panel.url {
            tools.customPaths[tool] = chosen.path
            tools.commitCustomPaths()
            tools.refresh(force: true)
        }
    }
}
