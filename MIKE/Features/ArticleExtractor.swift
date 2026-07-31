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
import WebKit

/// Loads a URL in an invisible WKWebView, injects Mozilla's Readability and
/// returns the cleaned-up article text.
///
/// The page is rendered rather than merely fetched, so sites that assemble
/// their content with JavaScript work too.
@MainActor
final class ArticleExtractor: NSObject, ObservableObject, WKNavigationDelegate {

    enum Format: String, CaseIterable, Identifiable {
        case plain
        case markdown

        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .plain: return "Plain Text"
            case .markdown: return "Markdown"
            }
        }

        var fileExtension: String {
            switch self {
            case .plain: return "txt"
            case .markdown: return "md"
            }
        }
    }

    /// What came back from the page.
    struct Article {
        var text: String
        /// Readability's own title, used to name the saved file.
        var title: String?
    }

    enum ExtractionError: LocalizedError {
        case invalidURL
        case loadFailed(String)
        case noArticle
        case scriptsMissing
        case unexpectedResponse
        case scriptFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return String(localized: "That is not a valid http or https URL.")
            // WebKit's own wording, passed through untranslated.
            case .loadFailed(let detail):
                return String(
                    localized: "The page could not be loaded: \(detail)",
                    comment: "Placeholder is WebKit's error message"
                )
            case .noArticle:
                return String(localized: "No article found on this page.")
            case .scriptsMissing:
                return String(localized: "Readability.js is missing from the app bundle.")
            case .unexpectedResponse:
                return String(localized: "The extraction returned something unexpected.")
            // JavaScript's own wording, passed through untranslated.
            case .scriptFailed(let detail):
                return String(
                    localized: "Extraction failed: \(detail)",
                    comment: "Placeholder is the JavaScript error"
                )
            case .timeout:
                return String(localized: "Timed out while loading the page.")
            }
        }
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Article, Error>?
    private var format: Format = .plain
    private var timeoutTask: Task<Void, Never>?

    func extract(from urlString: String, format: Format) async throws -> Article {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw ExtractionError.invalidURL }

        cancel()
        self.format = format

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Nothing is kept between runs: no cookies, no cache, no local storage.
        config.websiteDataStore = .nonPersistent()

        // Large enough that sites serve their desktop layout. Never shown.
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 2000),
            configuration: config
        )
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        self.webView = webView

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            webView.load(URLRequest(url: url))

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled else { return }
                self.finish(.failure(ExtractionError.timeout))
            }
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(throwing: CancellationError())
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await runExtraction() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(ExtractionError.loadFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(ExtractionError.loadFailed(error.localizedDescription)))
    }

    // MARK: - Extraction

    private func runExtraction() async {
        // Give late-arriving, script-rendered content a moment to land.
        try? await Task.sleep(for: .seconds(1.5))

        guard let webView, continuation != nil else { return }

        guard
            let readabilityURL = Bundle.main.url(forResource: "Readability", withExtension: "js"),
            let extractionURL = Bundle.main.url(forResource: "Extraction", withExtension: "js"),
            let readabilityJS = try? String(contentsOf: readabilityURL, encoding: .utf8),
            let extractionJS = try? String(contentsOf: extractionURL, encoding: .utf8)
        else {
            finish(.failure(ExtractionError.scriptsMissing))
            return
        }

        // The source label travels in from here so the produced document
        // follows the app's language rather than carrying a hardcoded word.
        let sourceLabel = String(
            localized: "Source:",
            comment: "Prefix of the source line appended to the extracted article"
        )
        let script = readabilityJS + "\n" + extractionJS + "\n"
            + "__extractArticle(\(quoted(format.rawValue)), \(quoted(sourceLabel)));"

        do {
            let result = try await webView.evaluateJavaScript(script)
            guard
                let jsonString = result as? String,
                let data = jsonString.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                finish(.failure(ExtractionError.unexpectedResponse))
                return
            }

            if let ok = obj["ok"] as? Bool, ok, let text = obj["text"] as? String {
                let title = (obj["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                finish(.success(Article(text: text, title: title?.isEmpty == false ? title : nil)))
            } else {
                // The script reports a machine-readable reason so the message
                // can be translated here rather than inside the JavaScript.
                let reason = obj["reason"] as? String ?? "no-article"
                if reason == "exception" {
                    finish(.failure(ExtractionError.scriptFailed(obj["detail"] as? String ?? "")))
                } else {
                    finish(.failure(ExtractionError.noArticle))
                }
            }
        } catch {
            finish(.failure(ExtractionError.scriptFailed(error.localizedDescription)))
        }
    }

    /// JSON-encodes a string so it can be pasted into the injected script.
    private func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    private func finish(_ result: Result<Article, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView = nil
        guard let cont = continuation else { return }
        continuation = nil
        switch result {
        case .success(let article): cont.resume(returning: article)
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}
