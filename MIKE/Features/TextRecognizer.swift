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
import ImageIO
import Vision

enum TextRecognitionError: LocalizedError {
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .noTextFound:
            return String(localized: "No text was found in the image.")
        }
    }
}

/// Reads text out of images with Vision. Pure recognition and text-shaping
/// logic, no UI: always available, no external tool, no Setup entry.
enum TextRecognizer {

    static let acceptedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "bmp", "webp", "heic", "heif",
    ]

    // MARK: - Orientation

    /// Vision needs the pixel orientation explicitly. `ImageConverter.load`
    /// hands back the raw, un-rotated CGImage — fine for format conversion,
    /// but a portrait photo taken with a phone would scramble the
    /// top-to-bottom line ordering `reconstruct` relies on unless the EXIF
    /// orientation is read and passed through here.
    static func orientation(from url: URL) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .up }
        return orientation(from: source)
    }

    static func orientation(from data: Data) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .up }
        return orientation(from: source)
    }

    private static func orientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32,
              let value = CGImagePropertyOrientation(rawValue: raw)
        else { return .up }
        return value
    }

    // MARK: - Recognition

    /// Runs accurate text recognition and reconstructs paragraph and line
    /// structure from the spatial layout of the recognized lines. Must be
    /// called off the main thread — Vision recognition blocks the caller.
    static func recognizeText(in image: CGImage, orientation: CGImagePropertyOrientation) throws -> String {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        try handler.perform([request])

        let lines: [Line] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Vision's boundingBox uses a bottom-left origin; converted here to
            // a top-left top/bottom pair so reading order is a plain ascending
            // sort further down.
            let top = 1 - observation.boundingBox.origin.y - observation.boundingBox.height
            let bottom = 1 - observation.boundingBox.origin.y
            return Line(top: top, bottom: bottom, left: observation.boundingBox.origin.x, text: text)
        }

        guard !lines.isEmpty else { throw TextRecognitionError.noTextFound }
        return reconstruct(lines)
    }

    private struct Line {
        let top: CGFloat
        let bottom: CGFloat
        let left: CGFloat
        let text: String
    }

    /// Sorts recognized lines into a single top-to-bottom reading column and
    /// groups them into paragraphs by vertical gap. Every line stays its own
    /// text line within a paragraph — wrapped lines are not rejoined into
    /// flowing prose, since a screenshot or receipt would otherwise have
    /// unrelated adjacent lines merged into one run-on line.
    ///
    /// This assumes a single reading column. Vision reports no column or
    /// table structure, and guessing at one would risk shuffling text on any
    /// layout more complex than a plain page or screenshot — worse than
    /// leaving it flat.
    private static func reconstruct(_ lines: [Line]) -> String {
        let sorted = lines.sorted {
            abs($0.top - $1.top) > 0.006 ? $0.top < $1.top : $0.left < $1.left
        }

        var paragraphs: [[String]] = []
        var current: [String] = []
        var previousBottom: CGFloat?
        var previousHeight: CGFloat?

        for line in sorted {
            let height = max(line.bottom - line.top, 0.001)
            if let previousBottom, let previousHeight {
                let gap = line.top - previousBottom
                // A gap noticeably bigger than the preceding line's own height
                // reads as a paragraph break rather than ordinary line spacing.
                if gap > previousHeight * 0.6 {
                    paragraphs.append(current)
                    current = []
                }
            }
            current.append(line.text)
            previousBottom = line.bottom
            previousHeight = height
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    // MARK: - Format conversion

    /// Normalizes a recognized bullet marker to `-`. Applied only when saving
    /// as Markdown; the canonical text (Copy, TXT) keeps whatever character
    /// Vision actually recognized. No other Markdown interpretation is
    /// attempted.
    static func makeMarkdown(from text: String) -> String {
        let bulletPattern = try! NSRegularExpression(pattern: "^[•●▪◦‣∙]\\s+|^\\d{1,2}[.)]\\s+")
        return text
            .components(separatedBy: "\n")
            .map { line -> String in
                let range = NSRange(line.startIndex..., in: line)
                guard let match = bulletPattern.firstMatch(in: line, range: range),
                      let matchRange = Range(match.range, in: line)
                else { return line }
                return "- " + line[matchRange.upperBound...]
            }
            .joined(separator: "\n")
    }

    /// Builds RTF data with paragraph spacing between true paragraphs (a blank
    /// line in the canonical text) and a soft line break — not a new paragraph
    /// — for a line break inside one, so the paragraph structure survives
    /// without inventing bold, italic or any other styling Vision never
    /// reported.
    static func makeRTF(from text: String) -> Data? {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 10

        let joined = text
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: "\u{2028}") }
            .joined(separator: "\n")

        let attributed = NSAttributedString(
            string: joined,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .paragraphStyle: paragraphStyle,
            ]
        )
        let range = NSRange(location: 0, length: attributed.length)
        return try? attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}
