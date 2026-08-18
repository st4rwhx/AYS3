// PadLayoutModels.swift — snapshots, presets, per-game identity, import/export.
//
// Ported from AYS2. Pure value types + JSON codec: no core, no UIKit. The live
// editable store and the skin library (which reference these) are separate
// files. Static defaults/geometry come from `PadLayout` (PadLayout.swift).

import Foundation
import CoreGraphics

// MARK: - Snapshot

/// A complete controller layout: group positions per orientation, optional
/// per-button overrides, and per-control visibility. This is what a preset
/// stores and what the on-screen pad renders from.
struct PadLayoutSnapshot: Codable, Equatable {
    var portrait: [String: PadGroupPosition]
    var landscape: [String: PadGroupPosition]
    var perButtonPortrait: [String: PadGroupPosition]
    var perButtonLandscape: [String: PadGroupPosition]
    var controlVisibility: [String: Bool]

    static let builtInDefault = PadLayoutSnapshot(
        portrait: PadLayout.defaultPortrait,
        landscape: PadLayout.defaultLandscape,
        perButtonPortrait: [:],
        perButtonLandscape: [:],
        controlVisibility: [:]
    )

    func position(for id: String, landscape isLandscape: Bool) -> PadGroupPosition {
        let dict = isLandscape ? landscape : portrait
        let defaults = isLandscape ? PadLayout.defaultLandscape : PadLayout.defaultPortrait
        return dict[id] ?? defaults[id] ?? PadGroupPosition(x: 0.5, y: 0.5, scale: 1.0)
    }

    /// A per-button's position: explicit override if present, otherwise derived
    /// from its group's position + the button's cardinal offset (scaled).
    func perButtonPosition(for id: String, landscape isLandscape: Bool,
                           areaW: CGFloat, areaH: CGFloat) -> PadGroupPosition {
        let dict = isLandscape ? perButtonLandscape : perButtonPortrait
        if let pos = dict[id] { return pos }

        let groupID = PadLayout.groupID(for: id)
        let groupPos = position(for: groupID, landscape: isLandscape)
        let offset = VirtualPadButtonOffset.offset(for: id, isLandscape: isLandscape)
        let scaledOffsetX = offset.width * groupPos.scaleX
        let scaledOffsetY = offset.height * groupPos.scaleY
        return PadGroupPosition(
            x: groupPos.x + scaledOffsetX / max(areaW, 1),
            y: groupPos.y + scaledOffsetY / max(areaH, 1),
            scaleX: groupPos.scaleX, scaleY: groupPos.scaleY,
            hitScaleX: groupPos.hitScaleX, hitScaleY: groupPos.hitScaleY
        )
    }

    func isControlVisible(_ id: String) -> Bool {
        if let explicit = controlVisibility[id] { return explicit }
        let group = PadLayout.groupID(for: id)
        return controlVisibility[group] ?? true
    }
}

// MARK: - Preset

enum PadLayoutPresetSource: String, Codable, Equatable {
    case user, builtIn, futureImportedSkin
}

struct PadLayoutPreset: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var createdAt: Date
    var updatedAt: Date
    var source: PadLayoutPresetSource
    var linkedSkinID: String?
    var snapshot: PadLayoutSnapshot
}

// MARK: - Per-game identity (serial|crc), normalized

struct PadLayoutGameIdentity: Codable, Equatable, Hashable, Identifiable {
    let serial: String
    let crc: String
    var id: String { "\(serial)|\(crc)" }

    init?(serial: String?, crc: String?) {
        let s = Self.normalizedSerial(serial)
        let c = Self.normalizedCRC(crc)
        guard !s.isEmpty, !c.isEmpty else { return nil }
        self.serial = s; self.crc = c
    }

    init(serial: String, crc: String) {
        self.serial = Self.normalizedSerial(serial)
        self.crc = Self.normalizedCRC(crc)
    }

    static func normalizedSerial(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    static func normalizedCRC(_ value: String?) -> String {
        var raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if raw.hasPrefix("CRC-") { raw.removeFirst(4) }
        raw = raw.replacingOccurrences(of: "0X", with: "")
        raw = String(raw.filter { ("0"..."9").contains($0) || ("A"..."F").contains($0) })
        guard !raw.isEmpty, (UInt64(raw, radix: 16) ?? 0) != 0 else { return "" }
        return raw
    }
}

/// What a game overrides: its own layout preset and/or skin.
struct VPadGameAssignment: Codable, Equatable {
    var layoutPresetID: String?
    var skinID: String?
    init(layoutPresetID: String? = nil, skinID: String? = nil) {
        self.layoutPresetID = layoutPresetID; self.skinID = skinID
    }
    var isEmpty: Bool { layoutPresetID == nil && skinID == nil }
}

// MARK: - Import / export (JSON, versioned, sanitized)

struct PadLayoutImportResult {
    var displayName: String?
    var snapshot: PadLayoutSnapshot
}

enum PadLayoutImportExport {
    static let schemaVersion = 1

    static func exportData(for preset: PadLayoutPreset) throws -> Data {
        try exportData(displayName: preset.displayName, snapshot: preset.snapshot)
    }

    static func exportData(displayName: String, snapshot: PadLayoutSnapshot) throws -> Data {
        let payload = PadLayoutExportPayload(displayName: displayName, snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    static func decodeImport(from data: Data, fallbackName: String?) throws -> PadLayoutImportResult {
        let payload = try JSONDecoder().decode(PadLayoutExportPayload.self, from: data)
        return PadLayoutImportResult(
            displayName: sanitizedDisplayName(payload.displayName ?? payload.name,
                                              fallback: sourceName(from: fallbackName)),
            snapshot: clampedSnapshot(payload.snapshot)
        )
    }

    static func decodeSnapshot(from data: Data) throws -> PadLayoutSnapshot {
        try decodeImport(from: data, fallbackName: nil).snapshot
    }

    static func exportedFileName(for displayName: String) -> String {
        "\(sanitizedFileStem(displayName, fallback: "Layout")).layout.json"
    }

    static func clampedSnapshot(_ snapshot: PadLayoutSnapshot) -> PadLayoutSnapshot {
        PadLayoutSnapshot(
            portrait: clampPositions(snapshot.portrait),
            landscape: clampPositions(snapshot.landscape),
            perButtonPortrait: clampPositions(snapshot.perButtonPortrait),
            perButtonLandscape: clampPositions(snapshot.perButtonLandscape),
            controlVisibility: snapshot.controlVisibility
        )
    }

    private static func clampPositions(_ positions: [String: PadGroupPosition]) -> [String: PadGroupPosition] {
        positions.mapValues {
            PadGroupPosition(
                x: clampedUnit($0.x), y: clampedUnit($0.y),
                scaleX: PadLayoutMetrics.clampedScale($0.scaleX),
                scaleY: PadLayoutMetrics.clampedScale($0.scaleY),
                hitScaleX: PadLayoutMetrics.clampedScale($0.hitScaleX),
                hitScaleY: PadLayoutMetrics.clampedScale($0.hitScaleY)
            )
        }
    }

    private static func clampedUnit(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    private static func sanitizedDisplayName(_ name: String?, fallback: String?) -> String? {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let fb = (fallback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return fb.isEmpty ? nil : fb
    }

    private static func sourceName(from fileName: String?) -> String? {
        guard let fileName else { return nil }
        var stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        if stem.lowercased().hasSuffix(".layout") { stem = String(stem.dropLast(".layout".count)) }
        return stem.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedFileStem(_ name: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }
}

private struct PadLayoutExportPayload: Codable {
    var schemaVersion: Int?
    var displayName: String?
    var name: String?
    var portrait: [String: PadGroupPosition]
    var landscape: [String: PadGroupPosition]
    var perButtonPortrait: [String: PadGroupPosition]
    var perButtonLandscape: [String: PadGroupPosition]
    var controlVisibility: [String: Bool]

    var snapshot: PadLayoutSnapshot {
        PadLayoutSnapshot(portrait: portrait, landscape: landscape,
                          perButtonPortrait: perButtonPortrait,
                          perButtonLandscape: perButtonLandscape,
                          controlVisibility: controlVisibility)
    }

    init(displayName: String, snapshot: PadLayoutSnapshot) {
        self.schemaVersion = PadLayoutImportExport.schemaVersion
        self.displayName = displayName
        self.name = displayName
        self.portrait = snapshot.portrait
        self.landscape = snapshot.landscape
        self.perButtonPortrait = snapshot.perButtonPortrait
        self.perButtonLandscape = snapshot.perButtonLandscape
        self.controlVisibility = snapshot.controlVisibility
    }
}
