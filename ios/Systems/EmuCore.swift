// EmuCore.swift — the emulator abstraction seam.
//
// The UI never talks to a specific emulator. It talks to `EmuCore`. Two
// backends conform to it: one wraps the PS2 core, one wraps the PS3 core.
// The protocol is distilled from the proven Objective-C bridge surface, kept
// PlayStation-native so a single UI drives both consoles unchanged.
//
// Nothing here links or references a core; it is a pure contract. The concrete
// conformances live in their own files and are the only place a core name
// appears.

import Foundation
import CoreGraphics

// MARK: - Console

/// Which machine a core emulates. The UI switches art, box chrome and default
/// config off this; the button layout is identical for both.
enum EmuConsole: String, Codable, Sendable {
    case ps2
    case ps3

    var displayName: String { self == .ps2 ? "PlayStation 2" : "PlayStation 3" }
    var shortName: String { self == .ps2 ? "PS2" : "PS3" }
}

// MARK: - Pad

/// The DualShock button set — identical on PS2 (DS2) and PS3 (DS3). Raw values
/// match the bridge enum so a conformance can forward them without a table.
enum PadButton: Int, CaseIterable, Sendable {
    case up = 0, down, left, right
    case cross, circle, square, triangle
    case l1, r1, l2, r2
    case start, select
    case l3, r3

    /// Stable identifier used by the on-screen layout (matches AYS2 pad IDs).
    var layoutID: String {
        switch self {
        case .up: return "up";          case .down: return "down"
        case .left: return "left";      case .right: return "right"
        case .cross: return "cross";    case .circle: return "circle"
        case .square: return "square";  case .triangle: return "triangle"
        case .l1: return "l1";          case .r1: return "r1"
        case .l2: return "l2";          case .r2: return "r2"
        case .start: return "start";    case .select: return "select"
        case .l3: return "l3";          case .r3: return "r3"
        }
    }
}

// MARK: - VM state

enum EmuState: String, Sendable {
    case stopped, running, paused, saving, suspended
}

// MARK: - Save-state slot

struct SaveStateSlot: Identifiable, Sendable {
    let slot: Int
    let exists: Bool
    let date: Date?
    let hasThumbnail: Bool
    var id: Int { slot }
}

// MARK: - Library entry

struct GameEntry: Identifiable, Sendable {
    let fileName: String            // e.g. "BCES-01175.iso" / "EBOOT-…"
    let title: String
    let serial: String?             // BCES-01175 / SLES-…
    let crc: String?
    let metadata: [String: String]
    var id: String { fileName }
}

// MARK: - The core contract

/// Everything the UI needs from an emulator, PlayStation-native and
/// console-agnostic. Implementations forward to their native bridge.
protocol EmuCore: AnyObject {

    var console: EmuConsole { get }
    var state: EmuState { get }
    var isRunning: Bool { get }

    /// True when runtime code execution is available (recompiler), false when
    /// the core is running in interpreter fallback (still boots, slower).
    var isJITAvailable: Bool { get }
    var isInterpreterFallbackActive: Bool { get }

    // Lifecycle
    func boot(game fileName: String)
    func shutdown()
    func reset()
    func setPaused(_ paused: Bool)

    // The live surface the emulator renders into (Metal-backed).
    func renderView() -> AnyObject?   // UIView at runtime; AnyObject keeps this file UIKit-free

    // Input
    func setButton(_ button: PadButton, pressed: Bool)
    func setLeftStick(x: Float, y: Float)
    func setRightStick(x: Float, y: Float)
    func rumbleTest()

    // Save (in-game memory) + save-states (slots)
    func saveAll()
    func saveStateSlots() -> [SaveStateSlot]
    func saveState(toSlot slot: Int, completion: ((Bool) -> Void)?)
    func loadState(fromSlot slot: Int, completion: ((Bool) -> Void)?)
    var hasValidSaveStateGame: Bool { get }

    // Fast-forward (pass-forward): runtime turbo + configured scalar
    func setFastForward(_ enabled: Bool)
    var fastForwardScalar: Float { get set }

    // Config (global + per-game), the backing for the settings system.
    func int(_ section: String, _ key: String, default def: Int) -> Int
    func bool(_ section: String, _ key: String, default def: Bool) -> Bool
    func float(_ section: String, _ key: String, default def: Float) -> Float
    func string(_ section: String, _ key: String, default def: String) -> String
    func setInt(_ section: String, _ key: String, _ value: Int)
    func setBool(_ section: String, _ key: String, _ value: Bool)
    func setFloat(_ section: String, _ key: String, _ value: Float)
    func setString(_ section: String, _ key: String, _ value: String)
    func applyGraphicsNow()
    func flushConfig()

    // Library
    func availableGames() -> [GameEntry]
    func currentGameName() -> String?
    func documentsDirectory() -> String

    // OSD / volume
    var performanceOverlayVisible: Bool { get set }
    var volumePercent: Int { get set }

    // Favorites
    func isFavorite(_ fileName: String) -> Bool
    func setFavorite(_ fileName: String, _ value: Bool)
}
