import XCTest
@testable import SwooshCore

final class VersionProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var bytes = Data()
    private static var code = 200
    private static var count = 0
    static func prepare(_ data: Data, status: Int = 200) { lock.lock(); defer { lock.unlock() }; bytes = data; code = status; count = 0 }
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let data = Self.bytes; let status = Self.code; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class GameVersionTests: XCTestCase {
    private let title = "0100ABCDEF120000"
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func profile(_ id: String? = nil) -> String {
        "# Profile comments describe update 9.9.9, not the installed package.\ntitle_id\t\(id ?? title)\nbuild\tv0\t1.0.0\nbuild\tv65536\t1.0.1\npackage\tv65536\n"
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [VersionProtocol.self]
        return URLSession(configuration: config)
    }
    private func catalogue() -> Data { Data("{\"\(title)\":{\"65536\":\"2025-01-01\",\"131072\":\"2025-02-01\"}}".utf8) }

    func testInstalledVersionUsesPackageBuildAndIgnoresComments() {
        let result = InstalledGameVersion.profile(profile())
        XCTAssertEqual(result?.titleID, title)
        XCTAssertEqual(result?.contentVersion, 65536)
        XCTAssertEqual(result?.displayVersion, "1.0.1")
    }

    func testConflictingOrMissingPackageEvidenceStaysUnknown() {
        XCTAssertNil(InstalledGameVersion.profile(profile() + "package\tv0\n"))
        XCTAssertNil(InstalledGameVersion.profile(profile().replacingOccurrences(of: "package\tv65536", with: "package\tv999999")))
        XCTAssertNil(InstalledGameVersion.profile(profile("not-a-title-id")))
    }

    func testSharedRootMetadataCannotDescribeEveryApp() throws {
        let app = root.appendingPathComponent("Aurora.app")
        let folder = root.appendingPathComponent("GameData/profile/" + title)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(profile().utf8).write(to: folder.appendingPathComponent("game.tsv"))
        XCTAssertNil(InstalledGameVersion.read(beside: app, libraryRoot: root))
        let data = try JSONEncoder().encode(InstalledGameVersion(titleID: title, contentVersion: 65536, displayVersion: "1.0.1"))
        try data.write(to: root.appendingPathComponent("SwooshGame.json"))
        XCTAssertNil(InstalledGameVersion.read(beside: app, libraryRoot: root))
    }

    func testProfileDiscoveryAndExplicitManifestOverride() throws {
        let app = root.appendingPathComponent("Aurora/Aurora.app")
        let folder = root.appendingPathComponent("Aurora/GameData/profile/" + title)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(profile().utf8).write(to: folder.appendingPathComponent("game.tsv"))
        XCTAssertEqual(InstalledGameVersion.read(beside: app, libraryRoot: root)?.contentVersion, 65536)
        let override = InstalledGameVersion(titleID: title, contentVersion: 131072, displayVersion: "1.0.2")
        try JSONEncoder().encode(override).write(to: root.appendingPathComponent("Aurora/SwooshGame.json"))
        XCTAssertEqual(InstalledGameVersion.read(beside: app, libraryRoot: root), override)
    }

    func testMultipleGameProfilesDoNotPickAnArbitraryVersion() throws {
        let app = root.appendingPathComponent("Aurora/Aurora.app")
        for id in [title, "0100ABCDEF130000"] {
            let folder = root.appendingPathComponent("Aurora/GameData/profile/" + id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(profile(id).utf8).write(to: folder.appendingPathComponent("game.tsv"))
        }
        XCTAssertNil(InstalledGameVersion.read(beside: app, libraryRoot: root))
    }

    func testCatalogueUsesNumericContentVersionsAndCaseInsensitiveIDs() throws {
        let data = Data("{\"\(title.lowercased())\":{\"9\":\"old\",\"1000000\":null,\"bad\":\"ignored\"},\"invalid\":{\"3\":\"x\"}}".utf8)
        let releases = try GameReleaseStore.parse(data)
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[title]?.contentVersion, 1_000_000)
        XCTAssertNil(releases[title]?.releaseDate)
    }

    func testComparisonDoesNotInventMarketingVersionOrTreatNewerLocalAsOutdated() {
        let installed = InstalledGameVersion(titleID: title, contentVersion: 65536, displayVersion: "9.9.9")
        XCTAssertEqual(VersionComparison.compare(installed, release: GameRelease(contentVersion: 131072, releaseDate: nil)), .updateAvailable)
        XCTAssertEqual(VersionComparison.compare(installed, release: GameRelease(contentVersion: 65536, releaseDate: nil)), .latestKnown)
        XCTAssertEqual(VersionComparison.compare(installed, release: GameRelease(contentVersion: 0, releaseDate: nil)), .newerThanCatalogue)
        XCTAssertEqual(VersionComparison.compare(installed, release: nil), .unknown)
    }

    func testSnapshotSurvivesOfflineRestartAndAvoidsRepeatedChecks() async throws {
        let cache = root.appendingPathComponent("catalogue.json")
        VersionProtocol.prepare(catalogue())
        let store = GameReleaseStore(cache: cache, session: session())
        let first = await store.releases()
        let second = await store.releases()
        XCTAssertEqual(first?.releases[title]?.contentVersion, 131072)
        XCTAssertEqual(second?.checkedAt, first?.checkedAt)
        XCTAssertEqual(VersionProtocol.requests, 1)
        VersionProtocol.prepare(Data(), status: 503)
        let restarted = GameReleaseStore(cache: cache, session: session())
        let offline = await restarted.releases()
        XCTAssertEqual(offline?.releases[title]?.contentVersion, 131072)
        XCTAssertEqual(VersionProtocol.requests, 0)
    }

    func testStaleSnapshotRemainsAvailableWhenRefreshFails() async throws {
        let cache = root.appendingPathComponent("catalogue.json")
        let stale = ReleaseSnapshot(releases: try GameReleaseStore.parse(catalogue()), checkedAt: Date().addingTimeInterval(-90000))
        try JSONEncoder().encode(stale).write(to: cache)
        VersionProtocol.prepare(Data(), status: 503)
        let store = GameReleaseStore(cache: cache, session: session())
        let result = await store.releases()
        XCTAssertEqual(result?.isStale, true)
        XCTAssertEqual(result?.releases[title]?.contentVersion, 131072)
        XCTAssertEqual(VersionProtocol.requests, 1)
    }

    func testFailedChecksBackOffRatherThanHammeringSource() async {
        VersionProtocol.prepare(Data(), status: 503)
        let store = GameReleaseStore(cache: root.appendingPathComponent("catalogue.json"), session: session())
        let first = await store.releases(force: true)
        let second = await store.releases(force: true)
        XCTAssertNil(first); XCTAssertNil(second)
        XCTAssertEqual(VersionProtocol.requests, 1)
    }
}
