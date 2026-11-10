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

/// Runs blocking work off the main thread and hands the result back to the
/// caller's own context.
///
/// Nearly everything MIKE does blocks — an external process, ImageIO, a file
/// walk — and every section used to spell out the same bridge by hand: a
/// checked continuation, a hop onto a global queue, a `do`/`catch` turning the
/// outcome into a `Result`. This is that bridge, once.
///
/// A dispatch queue rather than a detached `Task` on purpose: the work here
/// blocks its thread for as long as it runs, and the cooperative thread pool
/// is not for that.
enum Background {

    /// For work that cannot fail, or reports failure through its own value.
    static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// For throwing work. The error comes back as a value, so the caller can
    /// switch over success and failure without a `do`/`catch` around an
    /// `await`.
    static func attempt<T>(_ work: @escaping () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result { try work() })
            }
        }
    }
}
