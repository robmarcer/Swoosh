import Foundation
import SwooshCore

/// Bookmark the chosen parent so a renamed folder remains discoverable after restarting.
struct SaveLocationPreference: Codable {
    let bookmark: Data
    let selectedPath: String
    let appendSubfolder: Bool
    static let key = "saveLocation"

    init(selected: URL) throws {
        bookmark = try selected.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        selectedPath = selected.path
        appendSubfolder = selected.lastPathComponent != "Swoosh Saves"
    }
    func resolve() -> URL {
        var stale = false
        let selected = (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)) ?? URL(fileURLWithPath: selectedPath)
        return appendSubfolder ? selected.appendingPathComponent("Swoosh Saves", isDirectory: true) : selected
    }
    static func load(_ defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
