import XCTest
@testable import SwooshCore

final class ReleaseLabelTests: XCTestCase {
    private let title = "0100ABCDEF120000"
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var profile: String {
        "# Latest 8.8.8 is a comment, not release evidence.\ntitle_id\t\(title)\nbuild\tv65536\t1.0.1\nbuild\tv131072\t1.0.2\npackage\tv65536\n"
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [VersionProtocol.self]
        return URLSession(configuration: config)
    }

    func testExactRevisionLabelIgnoresCommentsAndDefaultPackage() {
        XCTAssertEqual(ReleaseLabelStore.parse(profile, titleID: title, contentVersion: 131072), "1.0.2")
        XCTAssertEqual(ReleaseLabelStore.parse(profile, titleID: title.lowercased(), contentVersion: 65536), "1.0.1")
        XCTAssertNil(ReleaseLabelStore.parse(profile, titleID: title, contentVersion: 196608))
    }

    func testDifferentTitleOrConflictingBuildRowsStayUnknown() {
        XCTAssertNil(ReleaseLabelStore.parse(profile, titleID: "0100ABCDEF130000", contentVersion: 131072))
        XCTAssertNil(ReleaseLabelStore.parse(profile + "build\tv131072\t9.9.9\n", titleID: title, contentVersion: 131072))
    }

    func testInvalidDisplayVersionIsNotPresentedAsARelease() {
        XCTAssertNil(ReleaseLabelStore.parse(profile.replacingOccurrences(of: "1.0.2", with: "latest"), titleID: title, contentVersion: 131072))
    }

    func testVerifiedMappingSurvivesOfflineRestartWithoutNetworkRequests() async {
        VersionProtocol.prepare(Data(profile.utf8))
        let client = ReleaseLabelStore(folder: root, session: session())
        let online = await client.label(titleID: title, contentVersion: 131072)
        XCTAssertEqual(online?.displayVersion, "1.0.2")
        XCTAssertEqual(online?.sourceURL.host, "github.com")
        XCTAssertEqual(VersionProtocol.requests, 1)
        VersionProtocol.prepare(Data(), status: 503)
        let offline = ReleaseLabelStore(folder: root, session: session())
        let cached = await offline.label(titleID: title, contentVersion: 131072)
        XCTAssertEqual(cached, online)
        XCTAssertEqual(VersionProtocol.requests, 0)
    }

    func testMissingMappingBacksOffButDoesNotHideDifferentRevision() async {
        VersionProtocol.prepare(Data(), status: 404)
        let client = ReleaseLabelStore(folder: root, session: session())
        let first = await client.label(titleID: title, contentVersion: 131072)
        let second = await client.label(titleID: title, contentVersion: 131072)
        XCTAssertNil(first); XCTAssertNil(second)
        XCTAssertEqual(VersionProtocol.requests, 1)
        _ = await client.label(titleID: title, contentVersion: 196608)
        XCTAssertEqual(VersionProtocol.requests, 2)
    }

    func testNetworkFailuresCannotTriggerRepeatedRequests() async {
        VersionProtocol.prepare(Data(), status: 503)
        let client = ReleaseLabelStore(folder: root, session: session())
        _ = await client.label(titleID: title, contentVersion: 131072)
        _ = await client.label(titleID: title, contentVersion: 131072)
        XCTAssertEqual(VersionProtocol.requests, 1)
    }
}
