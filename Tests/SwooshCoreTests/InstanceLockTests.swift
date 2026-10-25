import XCTest
@testable import SwooshCore

final class InstanceLockTests: XCTestCase {
    func testSecondCopyIsBlockedAndCanStartAfterFirstExits() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var first: InstanceLock? = InstanceLock(path: path)
        XCTAssertEqual(first?.status, .acquired)
        XCTAssertEqual(InstanceLock(path: path).status, .alreadyRunning)
        first = nil
        // The stale file remains but the kernel releases the lock when its holder closes.
        let replacement = InstanceLock(path: path)
        XCTAssertEqual(replacement.status, .acquired)
        withExtendedLifetime(replacement) {}
    }

    func testSymlinkCannotBeUsedAsLockFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        if case .unavailable = InstanceLock(path: link.path).status {} else { XCTFail("A symlink lock must be rejected") }
        XCTAssertEqual(try String(contentsOf: target), "untouched")
    }
}
