// VirtualControllerView.swift — the on-screen touch pad.
//
// Renders the controller from the ported PadLayoutStore: every control sits at a
// normalized position for the current orientation, its VISUAL size driven by the
// group's scale and its TOUCH target by the (independent) hit scale — the dual-
// scale idea from the prior project (touch area can be larger than the art).
//
// The art is the "iPS3 signature" skin (the prior project's signature pad):
// thin lines of blue light with a soft glow and transparent interiors. Touching
// a control ignites it (brightness + glow). Input is forwarded to the active
// EmuCore (a no-op until a core is bound, so the pad is fully testable now).

import SwiftUI

// MARK: - Skin asset loader (bundled PNGs)

enum SigSkin {
    private static var cache: [String: UIImage] = [:]
    static func image(_ name: String) -> UIImage? {
        if let hit = cache[name] { return hit }
        var img = UIImage(named: name)
        if img == nil, let url = Bundle.main.url(forResource: name, withExtension: "png") {
            img = UIImage(contentsOfFile: url.path)
        }
        if let img { cache[name] = img }
        return img
    }
}

private func skinImage(_ name: String, ignited: Bool) -> some View {
    Group {
        if let ui = SigSkin.image(name) {
            Image(uiImage: ui).resizable().scaledToFit()
        } else {
            Color.clear
        }
    }
    .brightness(ignited ? 0.35 : 0)
    .shadow(color: Color(hex: 0x5AA0FF).opacity(ignited ? 0.95 : 0.35),
            radius: ignited ? 14 : 4)
}

// MARK: - Controller

struct VirtualControllerView: View {
    var layout: PadLayoutStore = .shared
    var core: EmuCore? = AppState.shared.core

    // Base render size of the analog stick at scale 1.0 (points).
    private let stickBase: CGFloat = 68

    /// Base render size at scale 1.0 for each control, per orientation — the
    /// exact frame sizes the prior project uses (d-pad and face buttons derive
    /// from the shared metrics; shoulders and system buttons are fixed rects).
    private func baseSize(_ id: String, _ landscape: Bool) -> CGSize {
        switch id {
        case "up", "down", "left", "right":
            let d = PadLayoutMetrics.dpadButtonWidth(isLandscape: landscape)
            return CGSize(width: d, height: d)
        case "triangle", "circle", "square", "cross":
            let a = PadLayoutMetrics.actionButtonSize
            return CGSize(width: a, height: a)
        case "l2", "r2": return landscape ? CGSize(width: 130, height: 44) : CGSize(width: 110, height: 40)
        case "l1", "r1": return landscape ? CGSize(width: 120, height: 32) : CGSize(width: 100, height: 30)
        case "select":   return landscape ? CGSize(width: 40, height: 22) : CGSize(width: 42, height: 22)
        case "start":    return CGSize(width: 48, height: 22)
        default:         return CGSize(width: 60, height: 60)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width >= geo.size.height
            let w = geo.size.width, h = geo.size.height
            ZStack {
                shoulders(landscape, w, h)
                systemButtons(landscape, w, h)
                directions(landscape, w, h)
                faces(landscape, w, h)
                sticks(landscape, w, h)
            }
        }
    }

    @ViewBuilder
    private func shoulders(_ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            imageControl("l1", "sig_l1", .l1, .capsule, group: true, l, w, h)
            imageControl("l2", "sig_l2", .l2, .capsule, group: true, l, w, h)
            imageControl("r1", "sig_r1", .r1, .capsule, group: true, l, w, h)
            imageControl("r2", "sig_r2", .r2, .capsule, group: true, l, w, h)
        }
    }

    @ViewBuilder
    private func systemButtons(_ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            imageControl("select", "sig_select", .select, .capsule, group: true, l, w, h)
            imageControl("start", "sig_start", .start, .capsule, group: true, l, w, h)
        }
    }

    @ViewBuilder
    private func directions(_ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            imageControl("up", "sig_up", .up, .rect, group: false, l, w, h)
            imageControl("down", "sig_down", .down, .rect, group: false, l, w, h)
            imageControl("left", "sig_left", .left, .rect, group: false, l, w, h)
            imageControl("right", "sig_right", .right, .rect, group: false, l, w, h)
        }
    }

    @ViewBuilder
    private func faces(_ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            imageControl("triangle", "sig_triangle", .triangle, .circle, group: false, l, w, h)
            imageControl("circle", "sig_circle", .circle, .circle, group: false, l, w, h)
            imageControl("cross", "sig_cross", .cross, .circle, group: false, l, w, h)
            imageControl("square", "sig_square", .square, .circle, group: false, l, w, h)
        }
    }

    @ViewBuilder
    private func sticks(_ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            stick("lstick", l, w, h) { core?.setLeftStick(x: $0, y: $1) }
            stick("rstick", l, w, h) { core?.setRightStick(x: $0, y: $1) }
        }
    }

    // MARK: Geometry

    private func center(_ id: String, group: Bool, _ l: Bool, _ w: CGFloat, _ h: CGFloat) -> (CGPoint, CGFloat, CGFloat) {
        let p = group ? layout.position(for: id, landscape: l)
                      : layout.perButtonPosition(for: id, landscape: l, areaW: w, areaH: h)
        return (CGPoint(x: p.x * w, y: p.y * h), p.scale, p.hitScale)
    }

    // MARK: Builders

    @ViewBuilder
    private func imageControl(_ id: String, _ asset: String, _ btn: PadButton,
                              _ shape: TouchControl<AnyView>.HitShape,
                              group: Bool, _ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        if layout.isControlVisible(id) {
            let (c, s, hit) = center(id, group: group, l, w, h)
            let base = baseSize(id, l)
            TouchControl(button: btn, core: core,
                         visual: CGSize(width: PadLayoutMetrics.visibleLength(baseLength: base.width, visibleScale: s),
                                        height: PadLayoutMetrics.visibleLength(baseLength: base.height, visibleScale: s)),
                         hitArea: CGSize(width: PadLayoutMetrics.touchLength(baseLength: base.width, hitScale: hit),
                                         height: PadLayoutMetrics.touchLength(baseLength: base.height, hitScale: hit)),
                         shape: shape) { down in
                AnyView(skinImage(asset, ignited: down))
            }.position(c)
        }
    }

    @ViewBuilder
    private func stick(_ id: String, _ l: Bool, _ w: CGFloat, _ h: CGFloat, onChange: @escaping (Float, Float) -> Void) -> some View {
        if layout.isControlVisible(id) {
            let (c, s, hit) = center(id, group: true, l, w, h)
            AnalogStick(base: stickBase * PadLayoutMetrics.clampedScale(s),
                        hit: PadLayoutMetrics.touchLength(baseLength: stickBase, hitScale: hit),
                        onChange: onChange).position(c)
        }
    }
}

// MARK: - Unified touch control (visual size vs hit size)

struct TouchControl<V: View>: View {
    enum HitShape { case circle, capsule, rect }
    let button: PadButton
    var core: EmuCore?
    let visual: CGSize
    let hitArea: CGSize
    let shape: HitShape
    @ViewBuilder let content: (Bool) -> V
    @State private var down = false

    private var anyShape: AnyShape {
        switch shape {
        case .circle: return AnyShape(Circle())
        case .capsule: return AnyShape(Capsule())
        case .rect: return AnyShape(Rectangle())
        }
    }

    var body: some View {
        content(down)
            .frame(width: visual.width, height: visual.height)
            .frame(width: hitArea.width, height: hitArea.height)
            .contentShape(anyShape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !down { down = true; core?.setButton(button, pressed: true) } }
                    .onEnded { _ in down = false; core?.setButton(button, pressed: false) }
            )
    }
}

// MARK: - Analog stick (image base + draggable thumb)

private struct AnalogStick: View {
    let base: CGFloat
    let hit: CGFloat
    let onChange: (Float, Float) -> Void
    @State private var thumb: CGSize = .zero
    @State private var active = false

    private var radius: CGFloat { base * 0.32 }

    var body: some View {
        ZStack {
            skinImage("sig_analog_base", ignited: active).frame(width: base, height: base)
            skinImage("sig_analog_stick", ignited: active)
                .frame(width: base * 0.44, height: base * 0.44)
                .offset(thumb)
        }
        .frame(width: hit, height: hit)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    active = true
                    let dx = v.location.x - hit / 2
                    let dy = v.location.y - hit / 2
                    let dist = max(1, (dx * dx + dy * dy).squareRoot())
                    let clamped = min(dist, radius)
                    let nx = dx / dist * clamped
                    let ny = dy / dist * clamped
                    thumb = CGSize(width: nx, height: ny)
                    onChange(Float(nx / radius), Float(ny / radius))
                }
                .onEnded { _ in active = false; thumb = .zero; onChange(0, 0) }
        )
    }
}
