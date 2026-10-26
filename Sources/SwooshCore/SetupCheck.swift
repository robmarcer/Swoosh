import Foundation

public struct SetupDiagnostic: Equatable, Sendable {
    public let message: String
    public let blocksLaunch: Bool
}

public enum SetupCheck {
    static func bundleInfo(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), data.count <= 1_000_000 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    public static func inspect(app: URL, libraryRoot: URL) -> [SetupDiagnostic] {
        let fm = FileManager.default
        var result: [SetupDiagnostic] = []
        func error(_ message: String) { result.append(SetupDiagnostic(message: message, blocksLaunch: true)) }
        if let info = bundleInfo(app) {
            if let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != ".." {
                let executable = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
                var directory: ObjCBool = false
                if !fm.fileExists(atPath: executable.path, isDirectory: &directory) || directory.boolValue {
                    error("The app’s executable is missing. Reinstall or rebuild the converted app.")
                } else if !fm.isExecutableFile(atPath: executable.path) {
                    error("The app’s executable has no execute permission. Restore its executable permission or reinstall the app.")
                }
            } else { error("The app has no valid CFBundleExecutable entry. Rebuild its app wrapper.") }
        } else { error("Contents/Info.plist is missing or invalid. Reinstall or rebuild the app bundle.") }

        let parent = app.deletingLastPathComponent().resolvingSymlinksInPath()
        let manifest = parent.appendingPathComponent("SwooshGame.json")
        var verified = false
        if parent != libraryRoot.resolvingSymlinksInPath(), fm.fileExists(atPath: manifest.path) {
            if let data = try? Data(contentsOf: manifest), data.count <= 65536,
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let raw = object["requiredPaths"] {
                    if let paths = raw as? [String], !paths.isEmpty {
                        verified = true
                        for path in paths {
                            guard let target = relativePath(path, beneath: parent) else {
                                error("A requiredPaths entry is invalid or leaves the game folder. Use paths relative to SwooshGame.json.")
                                continue
                            }
                            if !fm.fileExists(atPath: target.path) || !fm.isReadableFile(atPath: target.path) {
                                error("Required data is missing or unreadable: \(path). Restore it in the declared location, then recheck.")
                            }
                        }
                    } else { error("requiredPaths must be a nonempty array of relative paths in SwooshGame.json.") }
                }
            } else { error("SwooshGame.json is invalid or unreadable. Fix its JSON before launching.") }
        }
        if !verified {
            result.append(SetupDiagnostic(message: "App wrapper checked. Runtime data requirements are unverified; add requiredPaths to SwooshGame.json or test the game directly.", blocksLaunch: false))
        }
        return result
    }

    public static func relativePath(_ path: String, beneath root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let target = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { return nil }
        return target
    }
}
