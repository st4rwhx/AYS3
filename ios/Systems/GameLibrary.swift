// GameLibrary.swift — the REAL game library (no mock data).
//
// Scans the sandbox Documents/Games directory the importer copies into, and
// publishes what is actually there — nothing until the user imports a game. It
// refreshes whenever an import completes. Metadata is only what we can read for
// real: the file name, a serial parsed from the name, the on-disk size, and (for
// decrypted game folders) the title / cover / background pulled FROM the game
// itself (PARAM.SFO / ICON0.PNG / PIC1.PNG), the way the PS3 XMB does it. We
// never invent ratings, play-time, or descriptions.

import Foundation
import Observation

struct LibraryGame: Identifiable, Sendable {
    let fileName: String        // the entry in Documents/Games (file or folder)
    let path: String
    let isFolder: Bool
    let sizeBytes: Int64
    let serial: String?         // parsed from the name, best-effort
    let title: String           // SFO title for folders, else cleaned file name
    let coverPath: String?      // ICON0.PNG inside a game folder, if present
    let backgroundPath: String? // PIC1.PNG inside a game folder, if present
    var id: String { fileName }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

@Observable
final class GameLibrary: @unchecked Sendable {
    static let shared = GameLibrary()

    private(set) var games: [LibraryGame] = []

    private init() {
        NotificationCenter.default.addObserver(
            forName: FileImportHandler.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
        reload()
    }

    static var gamesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func reload() {
        let fm = FileManager.default
        let dir = Self.gamesDirectory
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        games = entries.filter { !$0.hasPrefix(".") }.map { name in
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let folder = isDir.boolValue
            return Self.describe(name: name, url: url, isFolder: folder)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Metadata (real only)

    private static func describe(name: String, url: URL, isFolder: Bool) -> LibraryGame {
        let serial = parseSerial(name)
        var title = (name as NSString).deletingPathExtension
        var cover: String?
        var background: String?

        // A decrypted PS3 game folder carries its own art + PARAM.SFO. Read them
        // straight off disk — that is exactly what the console does.
        if isFolder {
            let root = gameRoot(url)
            let icon = root.appendingPathComponent("ICON0.PNG")
            if FileManager.default.fileExists(atPath: icon.path) { cover = icon.path }
            let pic1 = root.appendingPathComponent("PIC1.PNG")
            if FileManager.default.fileExists(atPath: pic1.path) { background = pic1.path }
            let sfo = root.appendingPathComponent("PARAM.SFO")
            if let t = SFO.title(atPath: sfo.path), !t.isEmpty { title = t }
        }

        let size = folderOrFileSize(url, isFolder: isFolder)
        return LibraryGame(fileName: name, path: url.path, isFolder: isFolder,
                           sizeBytes: size, serial: serial, title: title,
                           coverPath: cover, backgroundPath: background)
    }

    /// PS3 game folders keep their metadata under PS3_GAME/ (disc) or the root
    /// (installed). Prefer PS3_GAME/ when present.
    private static func gameRoot(_ folder: URL) -> URL {
        let ps3game = folder.appendingPathComponent("PS3_GAME")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: ps3game.path, isDirectory: &isDir), isDir.boolValue {
            return ps3game
        }
        return folder
    }

    /// Best-effort PS3 serial from a name, e.g. "BLES-00932", "BCES01175".
    private static func parseSerial(_ name: String) -> String? {
        let pattern = "[A-Z]{4}[-_]?\\d{5}"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = name.uppercased() as NSString
        guard let m = re.firstMatch(in: name.uppercased(), range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = ns.substring(with: m.range)
        // Normalise to LETTERS-DIGITS.
        let letters = raw.prefix(4)
        let digits = raw.suffix(5)
        return "\(letters)-\(digits)"
    }

    private static func folderOrFileSize(_ url: URL, isFolder: Bool) -> Int64 {
        let fm = FileManager.default
        if !isFolder {
            let a = try? fm.attributesOfItem(atPath: url.path)
            return (a?[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }
}
