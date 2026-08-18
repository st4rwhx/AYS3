// ExternalGameLibrary.swift — security-scoped external game folders/files.
//
// Ported from the prior project. Lets the user point the library at folders or single game
// files outside the app container (Files app locations), persisted as
// security-scoped bookmarks. Self-contained — no core dependency. Supported
// extensions cover both PS2 and PS3 disc/package formats; PS3 games are often
// folders, which the directory path already handles.

import Foundation
import Observation

struct ExternalGameDirectory: Identifiable, Hashable {
    let id: String
    let displayName: String
    let path: String
    let isDirectory: Bool
}

@Observable
final class ExternalGameLibrary: @unchecked Sendable {
    static let shared = ExternalGameLibrary()
    static let didChangeNotification = Notification.Name("iPS3ExternalGameLibraryDidChange")
    static let defaultsKey = "iPS3ExternalGameDirectories"

    private(set) var directories: [ExternalGameDirectory] = []
    // Union of PS2 + PS3 file formats. PS3 disc/JB games are folders (handled
    // by the directory path); PKG and ISO cover packaged/disc images.
    private static let gameExtensions = Set([
        "iso", "chd", "img", "bin", "cue", "mdf", "cso", "zso", "gz", "elf", "pkg"
    ])

    private init() { reload() }

    func reload() {
        let records = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [[String: Any]] ?? []
        directories = records.compactMap { record in
            guard let id = record["id"] as? String,
                  let displayName = record["displayName"] as? String,
                  let path = record["path"] as? String else { return nil }
            let isDirectory = (record["isDirectory"] as? Bool) ?? ((record["kind"] as? String) != "file")
            return ExternalGameDirectory(id: id, displayName: displayName, path: path, isDirectory: isDirectory)
        }
    }

    @discardableResult
    func addDirectory(_ url: URL) -> String { addLocation(url) }

    @discardableResult
    func addLocation(_ url: URL) -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let standardizedURL = url.standardizedFileURL
        let resourceValues = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey])
        let isGameFile = Self.isSupportedGameFileURL(standardizedURL)
        let isDirectory = resourceValues?.isDirectory ?? !isGameFile
        let cloudProvider = Self.isLikelyCloudProvider(standardizedURL)
        let scanDisabled = isDirectory && cloudProvider
        guard isDirectory || isGameFile else {
            NSLog("[iPS3 External Games] rejected unsupported location path=%@", standardizedURL.path)
            return "External location could not be added. Select a folder or a supported game image."
        }
        if cloudProvider {
            NSLog("[iPS3 External Games] rejected cloud provider direct access path=%@", standardizedURL.path)
            return "Google Drive cannot be used as direct external storage.\n\nCloud files are not guaranteed to be downloaded as stable, seekable files. Use Import Games to copy the game in first."
        }

        do {
            let bookmarkData = try standardizedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var records = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [[String: Any]] ?? []
            let path = standardizedURL.path
            let displayName = standardizedURL.lastPathComponent.isEmpty ? path : standardizedURL.lastPathComponent
            let record: [String: Any] = [
                "id": UUID().uuidString,
                "displayName": displayName,
                "path": path,
                "bookmarkData": bookmarkData,
                "isDirectory": isDirectory,
                "kind": isDirectory ? "folder" : "file",
                "scanDisabled": scanDisabled,
            ]
            records.removeAll { existing in
                guard let existingPath = existing["path"] as? String else { return false }
                return URL(fileURLWithPath: existingPath).standardizedFileURL.path == path
            }
            records.append(record)
            UserDefaults.standard.set(records, forKey: Self.defaultsKey)
            reload()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            if scanDisabled {
                return "External folder saved: \(displayName)\nCloud folders like Google Drive cannot be scanned safely. Select the game file itself to add it as a playable external game."
            }
            return isDirectory ? "External game folder added: \(displayName)\nTap Refresh to scan this folder." : "External game added: \(displayName)"
        } catch {
            NSLog("[iPS3 External Games] bookmark failed path=%@ error=%@", standardizedURL.path, error.localizedDescription)
            return "External location could not be added: \(error.localizedDescription)"
        }
    }

    func removeDirectory(id: String) {
        var records = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [[String: Any]] ?? []
        records.removeAll { ($0["id"] as? String) == id }
        UserDefaults.standard.set(records, forKey: Self.defaultsKey)
        reload()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    static func shouldRefreshGameListAfterAdding(_ url: URL) -> Bool {
        isSupportedGameFileURL(url.standardizedFileURL)
    }

    static func isSupportedGameFileURL(_ url: URL) -> Bool {
        if hasSupportedGameExtension(url.path) || hasSupportedGameExtension(url.lastPathComponent) { return true }
        let values = try? url.resourceValues(forKeys: [.nameKey, .localizedNameKey])
        if let name = values?.name, hasSupportedGameExtension(name) { return true }
        if let localizedName = values?.localizedName, hasSupportedGameExtension(localizedName) { return true }
        return false
    }

    private static func hasSupportedGameExtension(_ name: String) -> Bool {
        gameExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func isLikelyCloudProvider(_ url: URL) -> Bool {
        let path = url.path.lowercased(); let name = url.lastPathComponent.lowercased()
        return path.contains("google") || name.contains("google")
    }
}
