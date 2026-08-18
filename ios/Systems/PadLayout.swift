// PadLayout.swift — the on-screen controller layout system.
//
// Ported faithfully from the prior project's proven pad system. Console-agnostic: the same
// layout drives PS2 (DualShock 2) and PS3 (DualShock 3) because the button set
// is identical. Two ideas carry the whole system:
//   • normalized positions (0…1) per group, per orientation, so a layout is
//     resolution- and device-independent;
//   • separate VISUAL scale and HIT (touch-target) scale per axis, so a control
//     can be small on screen yet keep a generous touch area (or vice-versa).
//
// Persistence goes through `PadLayoutINIStore`, which the active EmuCore backs —
// so a layout round-trips through whichever core is loaded.

import Foundation
import CoreGraphics

// MARK: - Position model

/// A control group's placement. `x`/`y` are normalized to the play area.
/// Visual size and touch size are independent, per axis.
struct PadGroupPosition: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var scaleX: CGFloat
    var scaleY: CGFloat
    var hitScaleX: CGFloat
    var hitScaleY: CGFloat

    /// Uniform visual scale. Reading returns the X axis; writing sets both axes
    /// (a plain scale edit), matching the prior project's editor behaviour.
    var scale: CGFloat {
        get { scaleX }
        set { scaleX = newValue; scaleY = newValue }
    }
    /// Uniform touch scale. Same get-X / set-both semantics.
    var hitScale: CGFloat {
        get { hitScaleX }
        set { hitScaleX = newValue; hitScaleY = newValue }
    }

    init(x: CGFloat, y: CGFloat,
         scaleX: CGFloat, scaleY: CGFloat,
         hitScaleX: CGFloat, hitScaleY: CGFloat) {
        self.x = x; self.y = y
        self.scaleX = scaleX; self.scaleY = scaleY
        self.hitScaleX = hitScaleX; self.hitScaleY = hitScaleY
    }

    /// Convenience: uniform scale, optional independent hit scale.
    init(x: CGFloat, y: CGFloat, scale: CGFloat, hitScale: CGFloat? = nil) {
        let h = hitScale ?? scale
        self.init(x: x, y: y, scaleX: scale, scaleY: scale, hitScaleX: h, hitScaleY: h)
    }
}

enum PadSizeKind { case visible, hit }
enum PadSizeAxis { case x, y }

// MARK: - Persistence seam

/// Layouts persist as float keys in a config section. Backed by the active
/// EmuCore so a layout survives across launches through the core's config.
protocol PadLayoutINIStore {
    func getFloat(_ section: String, key: String, defaultValue: Float) -> Float
    func setFloat(_ section: String, key: String, value: Float)
}

/// Backs the pad layout with an EmuCore's config store.
final class EmuCorePadLayoutINIStore: PadLayoutINIStore {
    private let core: EmuCore
    init(_ core: EmuCore) { self.core = core }
    func getFloat(_ section: String, key: String, defaultValue: Float) -> Float {
        core.float(section, key, default: defaultValue)
    }
    func setFloat(_ section: String, key: String, value: Float) {
        core.setFloat(section, key, value)
    }
}

// MARK: - Metrics & geometry

enum PadLayoutMetrics {
    static let minimumTouchLength: CGFloat = 55
    static let dpadPortraitSize: CGFloat = 100
    static let dpadLandscapeSize: CGFloat = 110
    /// Base render size of a face (action) button — square, both orientations.
    static let actionButtonSize: CGFloat = 42

    static func dpadButtonWidth(isLandscape: Bool) -> CGFloat {
        (isLandscape ? dpadLandscapeSize : dpadPortraitSize) * 0.42
    }
    static func dpadOffset(isLandscape: Bool) -> CGFloat {
        (isLandscape ? dpadLandscapeSize : dpadPortraitSize) * 0.29
    }
    /// Spread of each face button from the action-group centre.
    static let actionOffset: CGFloat = actionButtonSize * 1.1

    /// Visual length of a control given its base length and visible scale.
    static func visibleLength(baseLength: CGFloat, visibleScale: CGFloat) -> CGFloat {
        baseLength * clampedScale(visibleScale)
    }
    /// Touch length of a control given its base length and hit scale. A minimum
    /// base length keeps small controls comfortably touchable.
    static func touchLength(baseLength: CGFloat, hitScale: CGFloat) -> CGFloat {
        max(baseLength, minimumTouchLength) * clampedScale(hitScale)
    }
    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1.0 }
        return min(max(scale, 0.5), 7.0)
    }
}

/// Offsets of each per-button relative to its group centre (in points, scaled
/// by the group's scale at layout time). Mirrors the prior project's cardinal arrangement.
enum VirtualPadButtonOffset {
    static func offset(for id: String, isLandscape: Bool) -> CGSize {
        let dpadOff = PadLayoutMetrics.dpadOffset(isLandscape: isLandscape)
        let actionOff = PadLayoutMetrics.actionOffset
        switch id {
        case "up":       return CGSize(width: 0, height: -dpadOff)
        case "down":     return CGSize(width: 0, height: dpadOff)
        case "left":     return CGSize(width: -dpadOff, height: 0)
        case "right":    return CGSize(width: dpadOff, height: 0)
        case "triangle": return CGSize(width: 0, height: -actionOff)
        case "cross":    return CGSize(width: 0, height: actionOff)
        case "square":   return CGSize(width: -actionOff, height: 0)
        case "circle":   return CGSize(width: actionOff, height: 0)
        default:         return .zero
        }
    }
}

// MARK: - Groups, buttons, defaults

enum PadLayout {
    /// The ten movable groups.
    static let groupIDs = ["dpad", "action", "l1", "l2", "r1", "r2",
                           "lstick", "rstick", "select", "start"]
    /// The four face buttons (the "action" group).
    static let actionButtonIDs = ["cross", "circle", "square", "triangle"]
    /// Every individually-placeable button.
    static let perButtonIDs = ["triangle", "circle", "square", "cross",
                               "up", "down", "left", "right"]

    /// Which group a per-button belongs to.
    static func groupID(for perButtonID: String) -> String {
        if actionButtonIDs.contains(perButtonID) { return "action" }
        if ["up", "down", "left", "right"].contains(perButtonID) { return "dpad" }
        return perButtonID
    }

    /// Default portrait layout (normalized). Exact values from the prior project.
    static let defaultPortrait: [String: PadGroupPosition] = [
        "l2":     PadGroupPosition(x: 0.16, y: 0.06, scale: 1.0),
        "l1":     PadGroupPosition(x: 0.16, y: 0.14, scale: 1.0),
        "r2":     PadGroupPosition(x: 0.84, y: 0.06, scale: 1.0),
        "r1":     PadGroupPosition(x: 0.84, y: 0.14, scale: 1.0),
        "select": PadGroupPosition(x: 0.43, y: 0.20, scale: 1.0),
        "start":  PadGroupPosition(x: 0.57, y: 0.20, scale: 1.0),
        "dpad":   PadGroupPosition(x: 0.16, y: 0.48, scale: 1.0),
        "action": PadGroupPosition(x: 0.82, y: 0.44, scale: 1.0),
        "lstick": PadGroupPosition(x: 0.28, y: 0.78, scale: 1.0),
        "rstick": PadGroupPosition(x: 0.72, y: 0.78, scale: 1.0),
    ]

    /// Default landscape layout (normalized). Exact values from the prior project.
    static let defaultLandscape: [String: PadGroupPosition] = [
        "dpad":   PadGroupPosition(x: 0.14, y: 0.72, scale: 1.0),
        "action": PadGroupPosition(x: 0.84, y: 0.72, scale: 1.0),
        "l2":     PadGroupPosition(x: 0.14, y: 0.22, scale: 1.0),
        "l1":     PadGroupPosition(x: 0.14, y: 0.34, scale: 1.0),
        "r2":     PadGroupPosition(x: 0.86, y: 0.22, scale: 1.0),
        "r1":     PadGroupPosition(x: 0.86, y: 0.34, scale: 1.0),
        "select": PadGroupPosition(x: 0.43, y: 0.90, scale: 1.0),
        "start":  PadGroupPosition(x: 0.57, y: 0.90, scale: 1.0),
        "lstick": PadGroupPosition(x: 0.26, y: 0.86, scale: 1.0),
        "rstick": PadGroupPosition(x: 0.68, y: 0.86, scale: 1.0),
    ]

    static func defaultPosition(for groupID: String, landscape: Bool) -> PadGroupPosition {
        let table = landscape ? defaultLandscape : defaultPortrait
        return table[groupID] ?? PadGroupPosition(x: 0.5, y: 0.5, scale: 1.0)
    }

    // Config keys a group writes (visual + hit scale, per axis).
    static func sizeKeys(for id: String) -> [String] {
        ["\(id)_scale", "\(id)_hitScale",
         "\(id)_scaleX", "\(id)_scaleY",
         "\(id)_hitScaleX", "\(id)_hitScaleY"]
    }
}
