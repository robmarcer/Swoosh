import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SwooshCore

private final class ArtworkProtocol: URLProtocol {
    struct Reply { let data: Data; var status = 200; var type = "application/json" }
    private static let mutex = NSLock()
    private static var replies: [Reply] = []
    private static var count = 0
    static func prepare(_ responses: [Reply]) {
        mutex.lock(); defer { mutex.unlock() }; replies = responses; count = 0
    }
    static var requests: Int { mutex.lock(); defer { mutex.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.mutex.lock()
        Self.count += 1
        let reply = Self.replies.isEmpty ? Reply(data: Data(), status: 503) : Self.replies.removeFirst()
        Self.mutex.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ArtworkTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func page(title: String = "Aurora", host: String = "upload.wikimedia.org", game: Bool = true) -> [String: Any] {
        ["pageid": 123, "ns": 0, "title": title,
         "categories": [["title": game ? "Category:2020 video games" : "Category:Albums"]],
         "thumbnail": ["source": "https://\(host)/wikipedia/en/test.png?utm_source=example"],
         "pageimage": "Aurora cover.png"]
    }
    private func store(_ replies: [ArtworkProtocol.Reply]) -> ArtworkStore {
        ArtworkProtocol.prepare(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        return ArtworkStore(folder: root, session: URLSession(configuration: configuration))
    }
    private func png() throws -> Data {
        let context = CGContext(data: nil, width: 16, height: 24, bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 24))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testExplicitRedirectIsAcceptedAndTrackingParametersRemoved() throws {
        let data = try json(["query": ["redirects": [["from": "Aurora", "to": "The Aurora Quest"]],
                                              "pages": [page(title: "The Aurora Quest")]]])
        let candidate = try ArtworkLookup.candidate(data, requestedTitles: ["Aurora"], name: "Aurora")
        XCTAssertNotNil(candidate)
        XCTAssertNil(candidate?.imageURL.query)
        XCTAssertEqual(candidate?.sourceURL.host, "en.wikipedia.org")
        XCTAssertTrue(candidate?.sourceURL.path.hasPrefix("/wiki/File:") == true)
    }

    func testUnrelatedPagesAlbumsAndLookalikeHostsAreRejected() throws {
        for fixture in [page(title: "Aurora II"), page(game: false), page(host: "upload.wikimedia.org.example.com")] {
            let data = try json(["query": ["pages": [fixture]]])
            XCTAssertNil(try ArtworkLookup.candidate(data, requestedTitles: ["Aurora"], name: "Aurora"))
        }
    }

    func testSearchRequiresExactTitleIgnoringGameDisambiguation() throws {
        let data = try json(["query": ["search": [["title": "Aurora II"], ["title": "Aurora (2020 video game)"], ["title": "Aurora soundtrack"]]]])
        XCTAssertEqual(try ArtworkLookup.searchTitles(data, name: "Aurora"), ["Aurora (2020 video game)"])
    }

    func testDownloadSurvivesOfflineRestartWithSourceAttribution() async throws {
        let response = try json(["query": ["pages": [page()]]])
        let client = store([.init(data: response), .init(data: try png(), type: "image/png")])
        let result = await client.artwork(for: "Aurora")
        XCTAssertNotNil(result)
        XCTAssertEqual(ArtworkProtocol.requests, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result!.imageURL.path))
        let offline = store([])
        let cached = await offline.artwork(for: "Aurora", allowNetwork: false)
        XCTAssertEqual(cached, result)
        XCTAssertEqual(ArtworkProtocol.requests, 0)
    }

    func testDownloadsCanBeDisabledWithoutAnyNetworkRequest() async {
        let client = store([])
        let result = await client.artwork(for: "Aurora", allowNetwork: false)
        XCTAssertNil(result)
        XCTAssertEqual(ArtworkProtocol.requests, 0)
    }

    func testMissingMatchIsCachedWithoutRepeatedNetworkRequests() async throws {
        let client = store([.init(data: try json(["query": ["pages": []]])),
                            .init(data: try json(["query": ["search": []]]))])
        let first = await client.artwork(for: "Aurora")
        let second = await client.artwork(for: "Aurora")
        XCTAssertNil(first); XCTAssertNil(second)
        XCTAssertEqual(ArtworkProtocol.requests, 2)
    }

    func testServerFailureBacksOffAndInvalidImageIsNotSaved() async throws {
        let unavailable = store([.init(data: Data(), status: 503)])
        let first = await unavailable.artwork(for: "Aurora")
        let second = await unavailable.artwork(for: "Aurora")
        XCTAssertNil(first); XCTAssertNil(second)
        XCTAssertEqual(ArtworkProtocol.requests, 1)
        let invalid = store([.init(data: try json(["query": ["pages": [page(title: "Orbit")]]])),
                             .init(data: Data("not an image".utf8), type: "image/png")])
        let result = await invalid.artwork(for: "Orbit")
        XCTAssertNil(result)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).allSatisfy { $0.pathExtension != "png" })
    }
}
