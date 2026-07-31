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

enum TikTokResolverError: LocalizedError {
    case http(Int)
    case network(String)
    case notProcessable
    case noLinkFound

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return String(localized: "ssstik HTTP \(code)", comment: "ssstik is a service name")
        // Passed through untranslated: this is the system's networking message.
        case .network(let detail): return detail
        case .notProcessable:
            return String(localized: "ssstik could not process this link.")
        case .noLinkFound:
            return String(localized: "No direct link found in the response.")
        }
    }
}

/// Resolves a TikTok page URL to the direct CDN link, by way of ssstik.io.
///
/// The request shape — including the German locale parameter — is carried over
/// unchanged from the original, where it was established to work.
enum TikTokResolver {

    private static let endpoint = URL(string: "https://ssstik.io/abc?url=dl")!
    private static let referer = "https://ssstik.io/de"

    private static let directLinkPattern =
        #"href="(https://tikcdn\.io/ssstik/\d+\?st=[^"&]+&amp;e=\d+|https://tikcdn\.io/ssstik/\d+\?st=[^"&]+&e=\d+)""#

    static func resolve(_ tiktokURL: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(HTTPDefaults.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("de,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://ssstik.io", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("true", forHTTPHeaderField: "HX-Request")
        request.setValue(referer, forHTTPHeaderField: "HX-Current-URL")
        request.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formBody([
            "id": tiktokURL,
            "locale": "de",
            "tt": "",
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TikTokResolverError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TikTokResolverError.http(http.statusCode)
        }

        let body = String(decoding: data, as: UTF8.self)

        guard let link = firstMatch(in: body) else {
            if body.contains("errorContainer"), !body.contains("tikcdn") {
                throw TikTokResolverError.notProcessable
            }
            throw TikTokResolverError.noLinkFound
        }
        return link.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstMatch(in body: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: directLinkPattern) else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: body)
        else { return nil }
        return String(body[captured])
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}
