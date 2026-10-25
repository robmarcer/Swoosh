import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct Artwork: Equatable, Sendable {
    public let imageURL: URL
    public let sourceURL: URL
}

struct ArtworkCandidate: Equatable, Sendable {
    let imageURL: URL
    let sourceURL: URL
}

enum ArtworkLookup {
    static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func baseTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\((?:\d{4}\s+)?video game\)$"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func searchTitles(_ data: Data, name: String) throws -> [String] {
        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if document?["error"] != nil { throw URLError(.badServerResponse) }
        let query = document?["query"] as? [String: Any]
        let entries = query?["search"] as? [[String: Any]] ?? []
        return entries.compactMap { $0["title"] as? String }.filter {
            normalized(baseTitle($0)) == normalized(name)
        }
    }

    static func candidate(_ data: Data, requestedTitles: [String], name: String) throws -> ArtworkCandidate? {
        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let document else { throw URLError(.cannotParseResponse) }
        if document["error"] != nil { throw URLError(.badServerResponse) }
        let query = document["query"] as? [String: Any] ?? [:]
        var accepted = Set(requestedTitles.map(normalized))
        let redirects = (query["normalized"] as? [[String: Any]] ?? []) + (query["redirects"] as? [[String: Any]] ?? [])
        for _ in 0..<5 {
            for redirect in redirects {
                if let from = redirect["from"] as? String, let to = redirect["to"] as? String, accepted.contains(normalized(from)) {
                    accepted.insert(normalized(to))
                }
            }
        }
        let pages = (query["pages"] as? [[String: Any]] ?? []).sorted {
            let a = ($0["title"] as? String ?? "").contains("video game")
            let b = ($1["title"] as? String ?? "").contains("video game")
            return a && !b
        }
        for page in pages {
            guard page["missing"] == nil, page["ns"] as? Int == 0,
                  let title = page["title"] as? String, accepted.contains(normalized(title)),
                  let categories = page["categories"] as? [[String: Any]],
                  categories.contains(where: { ($0["title"] as? String ?? "").lowercased().contains("video game") }),
                  let image = page["thumbnail"] as? [String: Any],
                  let rawURL = image["source"] as? String,
                  var imageURL = URLComponents(string: rawURL),
                  imageURL.scheme == "https", imageURL.host == "upload.wikimedia.org",
                  let filename = page["pageimage"] as? String
            else { continue }
            imageURL.query = nil; imageURL.fragment = nil
            var source = URLComponents()
            source.scheme = "https"; source.host = "en.wikipedia.org"
            source.path = "/wiki/File:" + filename.replacingOccurrences(of: " ", with: "_")
            guard let download = imageURL.url, let attribution = source.url else { continue }
            return ArtworkCandidate(imageURL: download, sourceURL: attribution)
        }
        return nil
    }
}

public actor ArtworkStore {
    private struct Record: Codable {
        let sourceURL: URL?
        let retryAfter: Date
    }
    private let folder: URL
    private let session: URLSession

    public init(folder: URL? = nil, session: URLSession? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Swoosh/Artwork", isDirectory: true)
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: configuration)
        }
    }

    public func artwork(for name: String, allowNetwork: Bool = true) async -> Artwork? {
        guard !name.isEmpty, name.count <= 200, !name.contains("|") else { return nil }
        let key = SHA256.hash(data: Data(ArtworkLookup.normalized(name).utf8)).map { String(format: "%02x", $0) }.joined()
        let image = folder.appendingPathComponent(key + ".png")
        let metadata = folder.appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: metadata), let record = try? JSONDecoder().decode(Record.self, from: data) {
            if let source = record.sourceURL, source.scheme == "https", source.host == "en.wikipedia.org",
               let bytes = try? Data(contentsOf: image), Self.validImage(bytes) {
                return Artwork(imageURL: image, sourceURL: source)
            }
            if record.sourceURL == nil && record.retryAfter > Date() { return nil }
        }
        guard allowNetwork else { return nil }
        do {
            try Task.checkCancellation()
            let directTitles = [name + " (video game)", name]
            var result = try await lookup(titles: directTitles, name: name)
            if result == nil {
                let search = try await api(["list": "search", "srsearch": name + " video game", "srnamespace": "0", "srlimit": "5"])
                let titles = try ArtworkLookup.searchTitles(search, name: name)
                if !titles.isEmpty { result = try await lookup(titles: titles, name: name) }
            }
            guard let result else {
                try save(Record(sourceURL: nil, retryAfter: Date().addingTimeInterval(7 * 86400)), at: metadata)
                return nil
            }
            let bytes = try await download(result.imageURL, image: true)
            guard Self.validImage(bytes), let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw URLError(.cannotDecodeContentData) }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, decoded, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (png as Data).write(to: image, options: .atomic)
            try save(Record(sourceURL: result.sourceURL, retryAfter: .distantFuture), at: metadata)
            return Artwork(imageURL: image, sourceURL: result.sourceURL)
        } catch {
            if !Task.isCancelled {
                try? save(Record(sourceURL: nil, retryAfter: Date().addingTimeInterval(15 * 60)), at: metadata)
            }
            return nil
        }
    }

    private func lookup(titles: [String], name: String) async throws -> ArtworkCandidate? {
        let data = try await api(["titles": titles.joined(separator: "|"), "prop": "pageimages|categories", "redirects": "1", "piprop": "thumbnail|name", "pithumbsize": "640", "pilicense": "any", "cllimit": "max"])
        return try ArtworkLookup.candidate(data, requestedTitles: titles, name: name)
    }

    private func api(_ parameters: [String: String]) async throws -> Data {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        let arguments = parameters.merging(["action": "query", "format": "json", "formatversion": "2", "maxlag": "5"]) { _, new in new }
        components.queryItems = arguments.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await download(components.url!, image: false)
    }

    private func download(_ url: URL, image: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Swoosh/0.2 (native macOS game artwork client)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https",
              response.url?.host == (image ? "upload.wikimedia.org" : "en.wikipedia.org"),
              data.count <= (image ? 8_000_000 : 2_000_000),
              !image || (response.mimeType?.hasPrefix("image/") == true)
        else { throw URLError(.badServerResponse) }
        return data
    }

    private func save(_ record: Record, at url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    private static func validImage(_ data: Data) -> Bool {
        guard data.count <= 8_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 4096 && height <= 4096
    }
}
