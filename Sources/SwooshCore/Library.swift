import Foundation

public struct Game: Identifiable, Equatable, Sendable {
    public let url: URL
    public let name: String
    public let coverURL: URL?
    public var id: String { url.path }
}

public struct LibraryScan {
    public let games: [Game]
    public let issue: String?
}

public enum Library {
    /// Scan bundles without entering their contents or traversing unrelated data directories.
    /// Supported layouts: Switch/Game.app or Switch/Game/Game.app.
    public static func scan(_ folder: URL) -> LibraryScan {
        let fm = FileManager.default
        let folder = folder.resolvingSymlinksInPath().standardizedFileURL
        var games: [Game] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard !seen.contains(resolved.path),
                  let data = try? Data(contentsOf: resolved.appendingPathComponent("Contents/Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let executable = info["CFBundleExecutable"] as? String,
                  !executable.isEmpty, !executable.contains("/"), executable != ".", executable != "..",
                  fm.isExecutableFile(atPath: resolved.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path)
            else { return }
            seen.insert(resolved.path)
            let title = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let parent = resolved.deletingLastPathComponent()
            // A shared library-level cover must not become every top-level app's cover.
            let cover = parent.standardizedFileURL == folder.standardizedFileURL ? nil : ["cover.jpg", "cover.png"].map { parent.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
            games.append(Game(url: resolved, name: title, coverURL: cover))
        }
        do {
            let entries = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for entry in entries {
                if entry.pathExtension.lowercased() == "app" { add(entry); continue }
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                for child in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] where child.pathExtension.lowercased() == "app" {
                    add(child)
                }
            }
            return LibraryScan(games: games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, issue: nil)
        } catch {
            return LibraryScan(games: [], issue: "The game folder could not be read. Check that it exists and is accessible.")
        }
    }
}

public enum Direction { case left, right, up, down }

public enum GridNavigation {
    public static func next(_ index: Int, direction: Direction, count: Int, columns: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let current = min(max(index, 0), count - 1)
        switch direction {
        case .left: return current % columns > 0 ? current - 1 : current
        case .right: return current % columns < columns - 1 && current + 1 < count ? current + 1 : current
        case .up: return current >= columns ? current - columns : current
        case .down: return current + columns < count ? current + columns : current
        }
    }
}
