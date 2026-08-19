// FileImportHandler.swift — signer-robust copy-in import for games and firmware.
//
// Ported from the prior project's import path and hardened for sideloaded,
// re-signed installs. The rule: never depend on a security-scoped bookmark, an
// app-group container, or a bundle-id-derived path to reach an imported file.
// Any of those break when the app is re-signed with a different provisioning
// identifier — a common failure mode that leaves other sideloaded emulators
// unable to even select their firmware file after a re-sign.
//
// Instead we COPY the chosen file into our own sandbox Documents exactly once,
// then own it outright. After that the file is reachable no matter how — or by
// whom — the app was signed: the Documents directory resolves from the running
// process's sandbox, which involves no entitlement, app-group, or provisioning
// identifier at all.

import Foundation
import Observation

@Observable
final class FileImportHandler: @unchecked Sendable {
    static let shared = FileImportHandler()
    static let didChangeNotification = Notification.Name("iPS3ImportedLibraryDidChange")

    /// What a chosen file is, which decides where it lands.
    enum Kind {
        case game
        case firmware
        var subdirectory: String { self == .firmware ? "Firmware" : "Games" }
    }

    struct Result: Identifiable, Sendable {
        let id = UUID()
        let sourceName: String
        let success: Bool
        let message: String
        let destinationPath: String?
    }

    // Live status the UI can observe while a (possibly large) copy runs.
    private(set) var isImporting = false
    private(set) var currentFile: String = ""
    private(set) var lastResults: [Result] = []

    // Game images we accept (PS2 + PS3). Firmware is the .PUP update package.
    private static let gameExtensions: Set<String> = [
        "iso", "chd", "img", "bin", "cue", "mdf", "cso", "zso", "gz", "elf", "pkg",
    ]
    private static let firmwareExtensions: Set<String> = ["pup"]

    private init() {}

    // MARK: - Destinations (sandbox-owned, signer-independent)

    /// The app's own Documents directory. Resolved from the running process's
    /// sandbox, so it is correct for ANY signer — no entitlement, app-group, or
    /// provisioning identifier is involved. This is the whole point of the
    /// copy-in design.
    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func destinationDirectory(for kind: Kind) -> URL {
        let dir = documentsURL.appendingPathComponent(kind.subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Classification

    static func kind(for url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if firmwareExtensions.contains(ext) { return .firmware }
        if gameExtensions.contains(ext) { return .game }
        // PS3 firmware is conventionally named PS3UPDAT.PUP; accept by name too
        // in case the extension arrives in a different case or is stripped.
        if url.lastPathComponent.uppercased().hasPrefix("PS3UPDAT") { return .firmware }
        return nil
    }

    // MARK: - Import

    /// Copy each chosen file into our sandbox. The copy runs off the main thread;
    /// status and per-file results are published back on the main actor.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> [Result] {
        await MainActor.run {
            self.isImporting = true
            self.lastResults = []
        }
        var results: [Result] = []
        for url in urls {
            let r = await copyOne(url)
            results.append(r)
            await MainActor.run { self.lastResults.append(r) }
        }
        await MainActor.run {
            self.isImporting = false
            self.currentFile = ""
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
        return results
    }

    private func copyOne(_ url: URL) async -> Result {
        let name = url.lastPathComponent
        await MainActor.run { self.currentFile = name }

        guard let kind = Self.kind(for: url) else {
            return Result(sourceName: name, success: false,
                          message: "Unsupported file type. Choose a game image or a .PUP firmware update.",
                          destinationPath: nil)
        }

        // A picked URL from Files is security-scoped: we must open access before
        // reading and close it after. We do NOT persist this scope — we copy the
        // bytes out while it is open, then never need the original again.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let destDir = destinationDirectory(for: kind)
        let dest = uniqueDestination(in: destDir, for: name)

        do {
            try copyCoordinated(from: url, to: dest)
        } catch {
            NSLog("[iPS3 Import] copy failed %@ -> %@ : %@", name, dest.path, error.localizedDescription)
            return Result(sourceName: name, success: false,
                          message: "Could not copy \(name): \(error.localizedDescription)",
                          destinationPath: nil)
        }

        let label = kind == .firmware ? "Firmware installed" : "Game imported"
        return Result(sourceName: name, success: true,
                      message: "\(label): \(dest.lastPathComponent)",
                      destinationPath: dest.path)
    }

    /// Copy through NSFileCoordinator so an un-materialised cloud placeholder
    /// (iCloud/Drive) is pulled down first, and so we read a consistent snapshot
    /// of the source. Directory sources (PS3 folder games) copy recursively.
    private func copyCoordinated(from src: URL, to dest: URL) throws {
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: src, options: [], error: &coordError) { readable in
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: readable, to: dest)
                } catch {
                    thrown = error
                }
            }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
    }

    /// Never overwrite an existing import silently; suffix duplicates instead so
    /// re-importing the same firmware/game does not clobber a working copy.
    private func uniqueDestination(in dir: URL, for name: String) -> URL {
        let first = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: first.path) { return first }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
