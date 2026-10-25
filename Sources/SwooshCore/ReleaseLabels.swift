import Foundation

public struct ReleaseLabel: Equatable, Sendable {
    public let displayVersion: String
    public let sourceURL: URL
}

public actor ReleaseLabelStore {
    private struct Record: Codable {
        let titleID: String
        let contentVersion: UInt32
        let displayVersion: String?
        let checkedAt: Date
    }
    private let folder: URL
    private let session: URLSession
    private var nextAttempts: [String: Date] = [:]

    public init(folder: URL? = nil, session: URLSession? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Swoosh/Versions/Labels")
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: config)
        }
    }

    private static func validLabel(_ text: String) -> Bool {
        text.count <= 64 && text.range(of: #"^[vV]?[0-9]+(?:\.[0-9A-Za-z]+){1,3}(?:[-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
    }

    /// Only an explicit build row for the exact title ID and content revision supplies a label.
    /// Package defaults, comments, and other revisions cannot name the requested release.
    public static func parse(_ text: String, titleID: String, contentVersion: UInt32) -> String? {
        guard InstalledGameVersion.validTitleID(titleID) else { return nil }
        let rows = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }
        let identities = rows.filter { $0.first == "title_id" }
        guard identities.count == 1, identities[0].count == 2, identities[0][1].uppercased() == titleID.uppercased() else { return nil }
        let builds = rows.filter { $0.count >= 3 && $0.first == "build" && $0[1] == "v\(contentVersion)" }
        guard builds.count == 1 else { return nil }
        let label = builds[0][2].trimmingCharacters(in: .whitespacesAndNewlines)
        return validLabel(label) ? label : nil
    }

    public func label(titleID: String, contentVersion: UInt32) async -> ReleaseLabel? {
        guard InstalledGameVersion.validTitleID(titleID) else { return nil }
        let id = titleID.uppercased()
        let source = URL(string: "https://github.com/seedds/nxnative/blob/main/dm/games/\(id)/game.tsv")!
        let cache = folder.appendingPathComponent("\(id)-\(contentVersion).json")
        if let bytes = try? Data(contentsOf: cache), let record = try? JSONDecoder().decode(Record.self, from: bytes),
           record.titleID == id, record.contentVersion == contentVersion {
            if let version = record.displayVersion, Self.validLabel(version) { return ReleaseLabel(displayVersion: version, sourceURL: source) }
            if Date().timeIntervalSince(record.checkedAt) < 86400 { return nil }
        }
        guard Date() >= (nextAttempts[cache.lastPathComponent] ?? .distantPast) else { return nil }
        nextAttempts[cache.lastPathComponent] = Date().addingTimeInterval(60)
        do {
            var request = URLRequest(url: URL(string: "https://raw.githubusercontent.com/seedds/nxnative/main/dm/games/\(id)/game.tsv")!)
            request.setValue("Swoosh/0.3.1 (game version label client)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.url?.scheme == "https", response.url?.host == "raw.githubusercontent.com",
                  data.count <= 1_000_000 else { return nil }
            let version: String?
            if response.statusCode == 200, let text = String(data: data, encoding: .utf8) {
                version = Self.parse(text, titleID: id, contentVersion: contentVersion)
            } else if response.statusCode == 404 { version = nil }
            else { return nil }
            try Task.checkCancellation()
            let record = Record(titleID: id, contentVersion: contentVersion, displayVersion: version, checkedAt: Date())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: cache, options: .atomic)
            return version.map { ReleaseLabel(displayVersion: $0, sourceURL: source) }
        } catch { return nil }
    }
}
