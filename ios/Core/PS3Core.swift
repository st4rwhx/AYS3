// PS3Core.swift — the EmuCore backend that drives the real PS3 core.
//
// Only compiled in the MERGED build (this file lives under ios/Core/, which the
// pure-Swift frontend CMake does not glob). It fulfils the EmuCore contract the
// UI already talks to, forwarding the calls that are wired today to the C bridge
// (ips3_core_*), and returning safe defaults for the surface that is not wired
// yet. As each subsystem lands (input, render surface, config, save-states) its
// stub here is replaced by a real bridge call — the UI never changes.

import Foundation
import Observation

@Observable
final class PS3Core: EmuCore, @unchecked Sendable {

    // MARK: Identity / state
    let console: EmuConsole = .ps3
    private(set) var state: EmuState = .stopped
    var isRunning: Bool { state == .running }

    // Recompiler availability is decided at boot once the JIT session is up; the
    // interpreter fallback (Wall #25 default) always works, so report that until
    // the recompiler path is enabled behind an attached debugger.
    var isJITAvailable: Bool = false
    var isInterpreterFallbackActive: Bool = true

    private var didInit = false
    private var currentGame: String?

    // MARK: Lifecycle
    func boot(game fileName: String) {
        if !didInit { ips3_core_init(); didInit = true }
        let path = Self.gamesDirectory.appendingPathComponent(fileName).path
        MemoryReport.shared.log("pre-boot:\(fileName)")
        let code = ips3_core_boot(path)
        let name = String(cString: ips3_core_boot_result_name(code))
        MemoryReport.shared.log("post-boot:\(name)")
        NSLog("[iPS3 PS3Core] boot(%@) -> %@ (footprint %.1f MB)",
              fileName, name, ips3_core_footprint_mb())
        state = (code == 0) ? .running : .stopped
        currentGame = (code == 0) ? fileName : nil
    }

    func shutdown() { state = .stopped; currentGame = nil }
    func reset() { }
    func setPaused(_ paused: Bool) { if state != .stopped { state = paused ? .paused : .running } }

    // The Metal surface the core renders into — not wired until the render path
    // is bridged; the UI shows its placeholder while this is nil.
    func renderView() -> AnyObject? { nil }

    // MARK: Input — not yet bridged (next slice); accept and drop for now.
    func setButton(_ button: PadButton, pressed: Bool) { }
    func setLeftStick(x: Float, y: Float) { }
    func setRightStick(x: Float, y: Float) { }
    func rumbleTest() { }

    // MARK: Save / save-states — not yet bridged.
    func saveAll() { }
    func saveStateSlots() -> [SaveStateSlot] { [] }
    func saveState(toSlot slot: Int, completion: ((Bool) -> Void)?) { completion?(false) }
    func loadState(fromSlot slot: Int, completion: ((Bool) -> Void)?) { completion?(false) }
    var hasValidSaveStateGame: Bool { currentGame != nil }

    // MARK: Fast-forward
    func setFastForward(_ enabled: Bool) { }
    var fastForwardScalar: Float = 1.0

    // MARK: Config — defaults until the core config is bridged.
    func int(_ section: String, _ key: String, default def: Int) -> Int { def }
    func bool(_ section: String, _ key: String, default def: Bool) -> Bool { def }
    func float(_ section: String, _ key: String, default def: Float) -> Float { def }
    func string(_ section: String, _ key: String, default def: String) -> String { def }
    func setInt(_ section: String, _ key: String, _ value: Int) { }
    func setBool(_ section: String, _ key: String, _ value: Bool) { }
    func setFloat(_ section: String, _ key: String, _ value: Float) { }
    func setString(_ section: String, _ key: String, _ value: String) { }
    func applyGraphicsNow() { }
    func flushConfig() { }

    // MARK: Library
    func availableGames() -> [GameEntry] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: Self.gamesDirectory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map {
            GameEntry(fileName: $0, title: ($0 as NSString).deletingPathExtension,
                      serial: nil, crc: nil, metadata: [:])
        }
    }
    func currentGameName() -> String? { currentGame }
    func documentsDirectory() -> String { Self.documents.path }

    // MARK: OSD / volume
    var performanceOverlayVisible: Bool = false
    var volumePercent: Int = 100

    // MARK: Favorites
    private var favorites: Set<String> = []
    func isFavorite(_ fileName: String) -> Bool { favorites.contains(fileName) }
    func setFavorite(_ fileName: String, _ value: Bool) {
        if value { favorites.insert(fileName) } else { favorites.remove(fileName) }
    }

    // MARK: Paths
    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static var gamesDirectory: URL {
        let d = documents.appendingPathComponent("Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
