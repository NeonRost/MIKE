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
import CoreText
import Foundation

enum TextExportError: LocalizedError {
    case empty
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .empty:
            return String(localized: "There is no text to save.")
        case .cannotWrite:
            return String(localized: "The document could not be written.")
        }
    }
}

/// Turns a plain text into a paginated PDF.
///
/// Unlike the image side, this one has to decide where pages end: Core Text
/// lays the text out and reports how much of it fit, and the remainder starts
/// the next page. That is also the loop's only safe termination condition —
/// a page that fits nothing at all breaks out rather than spinning forever.
enum TextDocumentWriter {

    /// A4 in points, the size the rest of the world prints on.
    private static let pageSize = CGSize(width: 595, height: 842)
    /// Roughly 2 cm on every side.
    private static let margin: CGFloat = 56

    static func pdf(text: String, into directory: URL, stem: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextExportError.empty }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = ImageConverter.uniqueURL(directory: directory, stem: stem, extension: "pdf")

        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(target as CFURL, mediaBox: &box, nil) else {
            throw TextExportError.cannotWrite
        }

        let attributed = NSAttributedString(string: text, attributes: bodyAttributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = box.insetBy(dx: margin, dy: margin)
        let path = CGPath(rect: textRect, transform: nil)

        var start = 0
        while start < attributed.length {
            context.beginPage(mediaBox: &box)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: start, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let consumed = CTFrameGetVisibleStringRange(frame).length
            context.endPage()

            // Nothing fit — a further page would fit nothing either.
            guard consumed > 0 else { break }
            start += consumed
        }

        context.closePDF()
        return target
    }

    private static var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 6
        return [
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: paragraph,
        ]
    }
}
