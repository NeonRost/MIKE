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


import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Turns what was dropped onto a view into file URLs.
///
/// Every section that takes a drop used to carry its own copy of this: ask
/// each provider for its file URL, accept it as `Data` or as `URL`, gather
/// the answers behind a lock because they arrive on arbitrary queues, and hop
/// back to the main thread. Three of those copies each brought a collector
/// class of their own. The sections now only say what they do with the URLs.
enum FileDrop {

    /// Resolves `providers` and hands the URLs over on the main actor, in the
    /// order they were dropped. Providers that are not files are left out;
    /// `deliver` is not called at all when nothing usable was dropped.
    static func urls(from providers: [NSItemProvider], deliver: @escaping @MainActor ([URL]) -> Void) {
        guard !providers.isEmpty else { return }

        let group = DispatchGroup()
        let collected = Slots(count: providers.count)

        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data {
                    collected.set(URL(dataRepresentation: data, relativeTo: nil), at: index)
                } else {
                    collected.set(item as? URL, at: index)
                }
            }
        }

        group.notify(queue: .main) {
            let urls = collected.values
            guard !urls.isEmpty else { return }
            MainActor.assumeIsolated { deliver(urls) }
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// One slot per provider, so the result keeps the drop order no matter
    /// which provider answers first.
    private final class Slots: @unchecked Sendable {
        private var storage: [URL?]
        private let lock = NSLock()

        init(count: Int) { storage = Array(repeating: nil, count: count) }

        func set(_ url: URL?, at index: Int) {
            lock.lock(); storage[index] = url; lock.unlock()
        }

        var values: [URL] {
            lock.lock(); defer { lock.unlock() }
            return storage.compactMap { $0 }
        }
    }
}

/// The drop target most sections want: an accent-coloured outline while
/// something is held over the view, and the dropped file URLs handed to a
/// closure.
private struct FileDropTarget: ViewModifier {
    let isEnabled: Bool
    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isTargeted && isEnabled ? Color.accentColor : .clear, lineWidth: 2)
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard isEnabled, !providers.isEmpty else { return false }
                FileDrop.urls(from: providers) { onDrop($0) }
                return true
            }
    }
}

extension View {
    func acceptsFileDrop(isEnabled: Bool = true, _ onDrop: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropTarget(isEnabled: isEnabled, onDrop: onDrop))
    }
}
