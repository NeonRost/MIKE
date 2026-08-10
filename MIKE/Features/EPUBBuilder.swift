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
import ImageIO
import ZIPFoundation

/// Writes a set of images as a fixed-layout EPUB 3 — one page per image.
///
/// Fixed layout rather than reflowable on purpose: the images *are* the pages
/// here, so each gets a viewport of its own pixel size and fills it. A
/// reflowable book would leave the reader to decide how a page-sized scan
/// flows into running text, which is not what a scanned page is.
///
/// The images are copied in untouched — no re-encoding, so a JPEG stays the
/// same JPEG — and are streamed one at a time, so page count is not bounded
/// by memory the way a single combined image is.
enum EPUBBuilder {

    static let outputName = "combined.epub"

    /// Everything an EPUB reader needs to find, in the order a reader expects
    /// to find it. `mimetype` has to come first and stored uncompressed —
    /// that is what lets a reader identify the file from its first bytes.
    static func build(files: [URL], into directory: URL, title: String) throws -> URL {
        guard !files.isEmpty else { throw ImageStackerError.noImages }

        // Unreadable files are skipped rather than failing the run, as in the
        // image and PDF paths. Only the dimensions are read here; the pixels
        // are never decoded, because the file is copied in as it is.
        let pages: [Page] = files.enumerated().compactMap { index, url in
            guard let size = pixelSize(of: url),
                  let media = mediaType(for: url) else { return nil }
            return Page(source: url, index: index, size: size, mediaType: media)
        }
        guard !pages.isEmpty else { throw ImageStackerError.noImages }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = ImageConverter.uniqueURL(
            directory: directory,
            stem: "combined",
            extension: "epub"
        )

        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: target, accessMode: .create)
        } catch {
            throw ImageStackerError.cannotWrite
        }

        do {
            // Stored, not deflated, and written before anything else.
            try add("mimetype", "application/epub+zip", to: archive, compress: false)
            try add("META-INF/container.xml", containerXML, to: archive)
            try add("EPUB/package.opf", packageOPF(pages: pages, title: title), to: archive)
            try add("EPUB/nav.xhtml", navXHTML(pages: pages, title: title), to: archive)

            for page in pages {
                try add("EPUB/xhtml/\(page.documentName)", pageXHTML(page), to: archive)
                // Already-compressed pixels: deflating them again buys
                // nothing and costs time on every page.
                try archive.addEntry(
                    with: "EPUB/images/\(page.imageName)",
                    fileURL: page.source,
                    compressionMethod: .none
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw ImageStackerError.cannotWrite
        }

        return target
    }

    // MARK: - Text

    /// A plain text as a reflowable EPUB — the opposite choice from the image
    /// side, and for the same reason: text has no page size of its own, so
    /// letting the reader set the type is the whole point. Blank lines
    /// separate paragraphs, which is how the merged text already reads.
    static func build(text: String, into directory: URL, stem: String, title: String) throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextExportError.empty
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = ImageConverter.uniqueURL(directory: directory, stem: stem, extension: "epub")

        let archive: ZIPFoundation.Archive
        do {
            archive = try ZIPFoundation.Archive(url: target, accessMode: .create)
        } catch {
            throw TextExportError.cannotWrite
        }

        do {
            try add("mimetype", "application/epub+zip", to: archive, compress: false)
            try add("META-INF/container.xml", containerXML, to: archive)
            try add("EPUB/package.opf", textPackageOPF(title: title), to: archive)
            try add("EPUB/nav.xhtml", textNavXHTML(title: title), to: archive)
            try add("EPUB/xhtml/text.xhtml", textXHTML(text: text, title: title), to: archive)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw TextExportError.cannotWrite
        }

        return target
    }

    private static func textPackageOPF(title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="en">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>\(escaped(title))</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="text" href="xhtml/text.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="text"/>
          </spine>
        </package>
        """
    }

    private static func textNavXHTML(title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
          <head>
            <meta charset="utf-8"/>
            <title>\(escaped(title))</title>
          </head>
          <body>
            <nav epub:type="toc" id="toc">
              <h1>\(escaped(title))</h1>
              <ol>
                <li><a href="xhtml/text.xhtml">\(escaped(title))</a></li>
              </ol>
            </nav>
          </body>
        </html>
        """
    }

    private static func textXHTML(text: String, title: String) -> String {
        // A run of blank lines ends a paragraph; single line breaks inside one
        // are kept as <br/>, so a list or an address block does not collapse
        // into a single run-on line.
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { block -> String in
                let lines = block
                    .components(separatedBy: "\n")
                    .map { escaped($0) }
                    .joined(separator: "<br/>\n      ")
                return "    <p>\(lines)</p>"
            }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
          <head>
            <meta charset="utf-8"/>
            <title>\(escaped(title))</title>
          </head>
          <body>
        \(paragraphs)
          </body>
        </html>
        """
    }

    // MARK: - Pages

    private struct Page {
        let source: URL
        let index: Int
        let size: (width: Int, height: Int)
        let mediaType: String

        var id: String { String(format: "page%04d", index + 1) }
        var imageName: String {
            String(format: "img%04d.%@", index + 1, source.pathExtension.lowercased())
        }
        var documentName: String { "\(id).xhtml" }
    }

    /// Dimensions straight from the file's header — no decoding.
    private static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    private static func mediaType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return nil
        }
    }

    // MARK: - Documents

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static func packageOPF(pages: [Page], title: String) -> String {
        let manifest = pages.flatMap { page -> [String] in
            // The first image doubles as the cover, so a library view has a
            // thumbnail instead of a blank placeholder.
            let cover = page.index == 0 ? " properties=\"cover-image\"" : ""
            return [
                "    <item id=\"\(page.id)\" href=\"xhtml/\(page.documentName)\" media-type=\"application/xhtml+xml\"/>",
                "    <item id=\"img-\(page.id)\" href=\"images/\(page.imageName)\" media-type=\"\(page.mediaType)\"\(cover)/>",
            ]
        }.joined(separator: "\n")

        let spine = pages
            .map { "    <itemref idref=\"\($0.id)\"/>" }
            .joined(separator: "\n")

        let modified = ISO8601DateFormatter().string(from: Date())

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="en" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>\(escaped(title))</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
            <meta property="rendition:layout">pre-paginated</meta>
            <meta property="rendition:orientation">auto</meta>
            <meta property="rendition:spread">auto</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \(manifest)
          </manifest>
          <spine>
        \(spine)
          </spine>
        </package>
        """
    }

    private static func navXHTML(pages: [Page], title: String) -> String {
        let items = pages.map { page in
            "        <li><a href=\"xhtml/\(page.documentName)\">\(page.index + 1)</a></li>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
          <head>
            <meta charset="utf-8"/>
            <title>\(escaped(title))</title>
          </head>
          <body>
            <nav epub:type="toc" id="toc">
              <h1>\(escaped(title))</h1>
              <ol>
        \(items)
              </ol>
            </nav>
          </body>
        </html>
        """
    }

    /// The viewport is the image's own pixel size — that is what makes a
    /// fixed-layout reader show the page at its true proportions rather than
    /// fitting it to some assumed page.
    private static func pageXHTML(_ page: Page) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
          <head>
            <meta charset="utf-8"/>
            <title>\(page.index + 1)</title>
            <meta name="viewport" content="width=\(page.size.width), height=\(page.size.height)"/>
            <style>
              html, body { margin: 0; padding: 0; height: 100%; }
              img { width: 100%; height: 100%; display: block; }
            </style>
          </head>
          <body>
            <img src="../images/\(page.imageName)" alt=""/>
          </body>
        </html>
        """
    }

    // MARK: - Writing

    private static func add(
        _ path: String,
        _ contents: String,
        to archive: ZIPFoundation.Archive,
        compress: Bool = true
    ) throws {
        let data = Data(contents.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compress ? .deflate : .none,
            provider: { position, size in
                let start = Int(position)
                return data.subdata(in: start ..< min(start + size, data.count))
            }
        )
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
