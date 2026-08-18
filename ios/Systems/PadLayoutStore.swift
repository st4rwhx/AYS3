// PadLayoutStore.swift — the live, editable controller layout.
//
// Ported faithfully from AYS2. Holds the current layout (group + per-button
// positions, per-orientation, per-axis visual/hit scale, visibility), edits it,
// and round-trips it through config. AYS2 persisted through the PS2 bridge; here
// it persists through whichever EmuCore is active — bind it with `rebind(to:)`
// once a core is loaded. Until then an in-memory store keeps edits working.

import Foundation
import Observation
import CoreGraphics

/// Dictionary-backed fallback so `PadLayoutStore.shared` works before a core is
/// bound (and in previews/tests).
final class InMemoryPadLayoutINIStore: PadLayoutINIStore {
    private var values: [String: Float] = [:]
    func getFloat(_ section: String, key: String, defaultValue: Float) -> Float {
        values["\(section)/\(key)"] ?? defaultValue
    }
    func setFloat(_ section: String, key: String, value: Float) {
        values["\(section)/\(key)"] = value
    }
}

@Observable
final class PadLayoutStore: @unchecked Sendable {
    static let shared = PadLayoutStore()

    private var iniStore: PadLayoutINIStore

    var portrait: [String: PadGroupPosition] = [:]
    var landscape: [String: PadGroupPosition] = [:]
    // Per-button overrides — only populated when the user moves an individual button.
    var perButtonPortrait: [String: PadGroupPosition] = [:]
    var perButtonLandscape: [String: PadGroupPosition] = [:]
    // Group-level visibility. Key present + false = hidden; absent = visible.
    var controlVisibility: [String: Bool] = [:]

    private static let secPortrait = "iPS3/PadLayout/Portrait"
    private static let secLandscape = "iPS3/PadLayout/Landscape"
    private static let secPerBtnPortrait = "iPS3/PadLayout/PerButtonPortrait"
    private static let secPerBtnLandscape = "iPS3/PadLayout/PerButtonLandscape"
    private static let secVisibility = "iPS3/PadLayout/ControlVisibility"

    init(iniStore: PadLayoutINIStore = InMemoryPadLayoutINIStore(), loadFromStore: Bool = true) {
        self.iniStore = iniStore
        portrait = PadLayout.defaultPortrait
        landscape = PadLayout.defaultLandscape
        if loadFromStore { load() }
    }

    /// Bind persistence to a loaded core's config and reload from it.
    func rebind(to core: EmuCore) {
        iniStore = EmuCorePadLayoutINIStore(core)
        portrait = PadLayout.defaultPortrait
        landscape = PadLayout.defaultLandscape
        perButtonPortrait = [:]; perButtonLandscape = [:]; controlVisibility = [:]
        load()
    }

    // MARK: - Lookups

    func position(for id: String, landscape isLandscape: Bool) -> PadGroupPosition {
        let dict = isLandscape ? landscape : portrait
        let defaults = isLandscape ? PadLayout.defaultLandscape : PadLayout.defaultPortrait
        return dict[id] ?? defaults[id] ?? PadGroupPosition(x: 0.5, y: 0.5, scale: 1.0)
    }

    func perButtonPosition(for id: String, landscape: Bool, areaW: CGFloat, areaH: CGFloat) -> PadGroupPosition {
        let dict = landscape ? perButtonLandscape : perButtonPortrait
        if let pos = dict[id] { return pos }
        let groupID = PadLayout.groupID(for: id)
        let groupPos = position(for: groupID, landscape: landscape)
        return defaultPerButtonPosition(for: id, groupPos: groupPos, isLandscape: landscape, areaW: areaW, areaH: areaH)
    }

    private func defaultPerButtonPosition(for id: String, groupPos: PadGroupPosition, isLandscape: Bool, areaW: CGFloat, areaH: CGFloat) -> PadGroupPosition {
        let offset = VirtualPadButtonOffset.offset(for: id, isLandscape: isLandscape)
        return PadGroupPosition(
            x: groupPos.x + offset.width * groupPos.scaleX / max(areaW, 1),
            y: groupPos.y + offset.height * groupPos.scaleY / max(areaH, 1),
            scaleX: groupPos.scaleX, scaleY: groupPos.scaleY,
            hitScaleX: groupPos.hitScaleX, hitScaleY: groupPos.hitScaleY
        )
    }

    func groupID(for perButtonID: String) -> String { PadLayout.groupID(for: perButtonID) }

    // MARK: - Edits (scale / hit-scale, linked or per-axis)

    func updateGroupScale(_ id: String, scale: CGFloat, landscape l: Bool) {
        var p = position(for: id, landscape: l); p.scale = PadLayoutMetrics.clampedScale(scale)
        setGroupPosition(p, for: id, landscape: l)
    }
    func updateGroupHitScale(_ id: String, hitScale: CGFloat, landscape l: Bool) {
        var p = position(for: id, landscape: l); p.hitScale = PadLayoutMetrics.clampedScale(hitScale)
        setGroupPosition(p, for: id, landscape: l)
    }
    func updatePerButtonScale(_ id: String, scale: CGFloat, landscape l: Bool, areaW: CGFloat, areaH: CGFloat) {
        var p = perButtonPosition(for: id, landscape: l, areaW: areaW, areaH: areaH)
        p.scale = PadLayoutMetrics.clampedScale(scale); setPerButtonPosition(p, for: id, landscape: l)
    }
    func updatePerButtonHitScale(_ id: String, hitScale: CGFloat, landscape l: Bool, areaW: CGFloat, areaH: CGFloat) {
        var p = perButtonPosition(for: id, landscape: l, areaW: areaW, areaH: areaH)
        p.hitScale = PadLayoutMetrics.clampedScale(hitScale); setPerButtonPosition(p, for: id, landscape: l)
    }
    func updateGroupSize(_ id: String, kind: PadSizeKind, axis: PadSizeAxis, scale: CGFloat, landscape l: Bool) {
        var p = position(for: id, landscape: l); Self.applyAxisScale(&p, kind: kind, axis: axis, scale: scale)
        setGroupPosition(p, for: id, landscape: l)
    }
    func updatePerButtonSize(_ id: String, kind: PadSizeKind, axis: PadSizeAxis, scale: CGFloat, landscape l: Bool, areaW: CGFloat, areaH: CGFloat) {
        var p = perButtonPosition(for: id, landscape: l, areaW: areaW, areaH: areaH)
        Self.applyAxisScale(&p, kind: kind, axis: axis, scale: scale); setPerButtonPosition(p, for: id, landscape: l)
    }
    private static func applyAxisScale(_ p: inout PadGroupPosition, kind: PadSizeKind, axis: PadSizeAxis, scale: CGFloat) {
        let c = PadLayoutMetrics.clampedScale(scale)
        switch (kind, axis) {
        case (.visible, .x): p.scaleX = c
        case (.visible, .y): p.scaleY = c
        case (.hit, .x):     p.hitScaleX = c
        case (.hit, .y):     p.hitScaleY = c
        }
    }
    /// Collapse Y onto X (width-wins) for both visual and hit scale.
    func relinkAxes(_ id: String, perButton: Bool, landscape l: Bool, areaW: CGFloat, areaH: CGFloat) {
        if perButton {
            var p = perButtonPosition(for: id, landscape: l, areaW: areaW, areaH: areaH)
            p.scaleY = p.scaleX; p.hitScaleY = p.hitScaleX; setPerButtonPosition(p, for: id, landscape: l)
        } else {
            var p = position(for: id, landscape: l)
            p.scaleY = p.scaleX; p.hitScaleY = p.hitScaleX; setGroupPosition(p, for: id, landscape: l)
        }
    }

    func setGroupPosition(_ position: PadGroupPosition, for id: String, landscape l: Bool) {
        if l { landscape[id] = position } else { portrait[id] = position }
    }
    func setPerButtonPosition(_ position: PadGroupPosition, for id: String, landscape l: Bool) {
        if l { perButtonLandscape[id] = position } else { perButtonPortrait[id] = position }
    }

    // MARK: - Visibility

    func isControlVisible(_ id: String) -> Bool {
        if let explicit = controlVisibility[id] { return explicit }
        return controlVisibility[groupID(for: id)] ?? true
    }
    func setControlVisible(_ id: String, visible: Bool) {
        if visible {
            let group = groupID(for: id)
            if id == group { controlVisibility.removeValue(forKey: id) }
            else if let gv = controlVisibility[group], !gv { controlVisibility[id] = true }
            else { controlVisibility.removeValue(forKey: id) }
        } else {
            controlVisibility[id] = false
        }
    }
    func resetControlVisibility() { controlVisibility.removeAll() }

    // MARK: - Resets

    func resetPortrait() { portrait = PadLayout.defaultPortrait }
    func resetLandscape() { landscape = PadLayout.defaultLandscape }
    func reset(isLandscape: Bool) { isLandscape ? resetLandscape() : resetPortrait() }
    func resetPerButtonActionButtons(isLandscape l: Bool) {
        for id in PadLayout.actionButtonIDs {
            if l { perButtonLandscape.removeValue(forKey: id) } else { perButtonPortrait.removeValue(forKey: id) }
        }
    }
    func resetPerButtonDPad(isLandscape l: Bool) {
        for id in ["up", "down", "left", "right"] {
            if l { perButtonLandscape.removeValue(forKey: id) } else { perButtonPortrait.removeValue(forKey: id) }
        }
    }
    func resetAll() {
        portrait = PadLayout.defaultPortrait; landscape = PadLayout.defaultLandscape
        perButtonPortrait.removeAll(); perButtonLandscape.removeAll()
        // controlVisibility intentionally preserved; use resetControlVisibility().
    }

    func snapshot() -> PadLayoutSnapshot {
        PadLayoutSnapshot(portrait: portrait, landscape: landscape,
                          perButtonPortrait: perButtonPortrait, perButtonLandscape: perButtonLandscape,
                          controlVisibility: controlVisibility)
    }
    func apply(snapshot s: PadLayoutSnapshot) {
        portrait = s.portrait; landscape = s.landscape
        perButtonPortrait = s.perButtonPortrait; perButtonLandscape = s.perButtonLandscape
        controlVisibility = s.controlVisibility
    }

    // MARK: - Config persistence

    private func writeSizeKeys(_ pos: PadGroupPosition, section: String, id: String) {
        iniStore.setFloat(section, key: "\(id)_scale", value: Float(pos.scaleX))
        iniStore.setFloat(section, key: "\(id)_hitScale", value: Float(pos.hitScaleX))
        iniStore.setFloat(section, key: "\(id)_scaleX", value: Float(pos.scaleX))
        iniStore.setFloat(section, key: "\(id)_scaleY", value: Float(pos.scaleY))
        iniStore.setFloat(section, key: "\(id)_hitScaleX", value: Float(pos.hitScaleX))
        iniStore.setFloat(section, key: "\(id)_hitScaleY", value: Float(pos.hitScaleY))
    }
    private func writeSizeKeysSentinel(section: String, id: String) {
        for s in ["scale", "hitScale", "scaleX", "scaleY", "hitScaleX", "hitScaleY"] {
            iniStore.setFloat(section, key: "\(id)_\(s)", value: -1.0)
        }
    }

    func save() {
        for id in PadLayout.groupIDs {
            if let pos = portrait[id] {
                iniStore.setFloat(Self.secPortrait, key: "\(id)_x", value: Float(pos.x))
                iniStore.setFloat(Self.secPortrait, key: "\(id)_y", value: Float(pos.y))
                writeSizeKeys(pos, section: Self.secPortrait, id: id)
            }
            if let pos = landscape[id] {
                iniStore.setFloat(Self.secLandscape, key: "\(id)_x", value: Float(pos.x))
                iniStore.setFloat(Self.secLandscape, key: "\(id)_y", value: Float(pos.y))
                writeSizeKeys(pos, section: Self.secLandscape, id: id)
            }
        }
        for id in PadLayout.perButtonIDs {
            if let pos = perButtonPortrait[id] {
                iniStore.setFloat(Self.secPerBtnPortrait, key: "\(id)_x", value: Float(pos.x))
                iniStore.setFloat(Self.secPerBtnPortrait, key: "\(id)_y", value: Float(pos.y))
                writeSizeKeys(pos, section: Self.secPerBtnPortrait, id: id)
            } else {
                iniStore.setFloat(Self.secPerBtnPortrait, key: "\(id)_x", value: -1.0)
                iniStore.setFloat(Self.secPerBtnPortrait, key: "\(id)_y", value: -1.0)
                writeSizeKeysSentinel(section: Self.secPerBtnPortrait, id: id)
            }
            if let pos = perButtonLandscape[id] {
                iniStore.setFloat(Self.secPerBtnLandscape, key: "\(id)_x", value: Float(pos.x))
                iniStore.setFloat(Self.secPerBtnLandscape, key: "\(id)_y", value: Float(pos.y))
                writeSizeKeys(pos, section: Self.secPerBtnLandscape, id: id)
            } else {
                iniStore.setFloat(Self.secPerBtnLandscape, key: "\(id)_x", value: -1.0)
                iniStore.setFloat(Self.secPerBtnLandscape, key: "\(id)_y", value: -1.0)
                writeSizeKeysSentinel(section: Self.secPerBtnLandscape, id: id)
            }
        }
        for id in PadLayout.groupIDs {
            iniStore.setFloat(Self.secVisibility, key: id, value: isControlVisible(id) ? 1.0 : 0.0)
        }
        for id in PadLayout.actionButtonIDs {
            if let explicit = controlVisibility[id] {
                iniStore.setFloat(Self.secVisibility, key: id, value: explicit ? 1.0 : 0.0)
            } else {
                iniStore.setFloat(Self.secVisibility, key: id, value: -1.0)
            }
        }
    }

    /// scaleX = *_scaleX ?? *_scale ?? 1 ; hitScaleX = *_hitScaleX ?? *_hitScale ?? scaleX (etc.)
    private func readSizeAxes(section: String, id: String) -> (scaleX: CGFloat, scaleY: CGFloat, hitScaleX: CGFloat, hitScaleY: CGFloat) {
        let legacyScale = iniStore.getFloat(section, key: "\(id)_scale", defaultValue: -1)
        let legacyHit = iniStore.getFloat(section, key: "\(id)_hitScale", defaultValue: -1)
        let sx = iniStore.getFloat(section, key: "\(id)_scaleX", defaultValue: -1)
        let sy = iniStore.getFloat(section, key: "\(id)_scaleY", defaultValue: -1)
        let hx = iniStore.getFloat(section, key: "\(id)_hitScaleX", defaultValue: -1)
        let hy = iniStore.getFloat(section, key: "\(id)_hitScaleY", defaultValue: -1)
        let baseScale = PadLayoutMetrics.clampedScale(CGFloat(legacyScale > 0 ? legacyScale : 1.0))
        let scaleX = PadLayoutMetrics.clampedScale(sx > 0 ? CGFloat(sx) : baseScale)
        let scaleY = PadLayoutMetrics.clampedScale(sy > 0 ? CGFloat(sy) : baseScale)
        let legacyHitScale = legacyHit > 0 ? PadLayoutMetrics.clampedScale(CGFloat(legacyHit)) : nil
        let hitScaleX = PadLayoutMetrics.clampedScale(hx > 0 ? CGFloat(hx) : (legacyHitScale ?? scaleX))
        let hitScaleY = PadLayoutMetrics.clampedScale(hy > 0 ? CGFloat(hy) : (legacyHitScale ?? scaleY))
        return (scaleX, scaleY, hitScaleX, hitScaleY)
    }

    func load() {
        for id in PadLayout.groupIDs {
            let px = iniStore.getFloat(Self.secPortrait, key: "\(id)_x", defaultValue: -1)
            if px >= 0 {
                let py = iniStore.getFloat(Self.secPortrait, key: "\(id)_y", defaultValue: 0.5)
                let a = readSizeAxes(section: Self.secPortrait, id: id)
                portrait[id] = PadGroupPosition(x: CGFloat(px), y: CGFloat(py), scaleX: a.scaleX, scaleY: a.scaleY, hitScaleX: a.hitScaleX, hitScaleY: a.hitScaleY)
            }
            let lx = iniStore.getFloat(Self.secLandscape, key: "\(id)_x", defaultValue: -1)
            if lx >= 0 {
                let ly = iniStore.getFloat(Self.secLandscape, key: "\(id)_y", defaultValue: 0.5)
                let a = readSizeAxes(section: Self.secLandscape, id: id)
                landscape[id] = PadGroupPosition(x: CGFloat(lx), y: CGFloat(ly), scaleX: a.scaleX, scaleY: a.scaleY, hitScaleX: a.hitScaleX, hitScaleY: a.hitScaleY)
            }
        }
        for id in PadLayout.perButtonIDs {
            let px = iniStore.getFloat(Self.secPerBtnPortrait, key: "\(id)_x", defaultValue: -1)
            let py = iniStore.getFloat(Self.secPerBtnPortrait, key: "\(id)_y", defaultValue: -1)
            if px >= 0 && py >= 0 {
                let a = readSizeAxes(section: Self.secPerBtnPortrait, id: id)
                perButtonPortrait[id] = PadGroupPosition(x: CGFloat(px), y: CGFloat(py), scaleX: a.scaleX, scaleY: a.scaleY, hitScaleX: a.hitScaleX, hitScaleY: a.hitScaleY)
            }
            let lx = iniStore.getFloat(Self.secPerBtnLandscape, key: "\(id)_x", defaultValue: -1)
            let ly = iniStore.getFloat(Self.secPerBtnLandscape, key: "\(id)_y", defaultValue: -1)
            if lx >= 0 && ly >= 0 {
                let a = readSizeAxes(section: Self.secPerBtnLandscape, id: id)
                perButtonLandscape[id] = PadGroupPosition(x: CGFloat(lx), y: CGFloat(ly), scaleX: a.scaleX, scaleY: a.scaleY, hitScaleX: a.hitScaleX, hitScaleY: a.hitScaleY)
            }
        }
        for id in PadLayout.groupIDs {
            let v = iniStore.getFloat(Self.secVisibility, key: id, defaultValue: -1)
            if v >= 0 { controlVisibility[id] = (v > 0.5) }
        }
        for id in PadLayout.actionButtonIDs {
            let v = iniStore.getFloat(Self.secVisibility, key: id, defaultValue: -1)
            if v >= 0 { controlVisibility[id] = (v > 0.5) }
        }
    }
}
