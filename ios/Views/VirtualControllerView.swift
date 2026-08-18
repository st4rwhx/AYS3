// VirtualControllerView.swift — the on-screen touch pad.
//
// Renders the controller from the ported PadLayoutStore: every control sits at a
// normalized position for the current orientation, its VISUAL size driven by the
// group's scale and its TOUCH target by the (independent) hit scale — the dual-
// scale idea from the prior project (touch area can be larger than the art).
// Input is forwarded to the active EmuCore (a no-op until a core is bound, so the
// pad is fully testable now).

import SwiftUI

struct VirtualControllerView: View {
    var layout: PadLayoutStore = .shared
    var core: EmuCore? = AppState.shared.core

    // Base sizes at scale 1.0 (points).
    private let faceBase: CGFloat = 58
    private let dirBase: CGFloat = 52
    private let shoulderBase = CGSize(width: 88, height: 40)
    private let sysBase = CGSize(width: 62, height: 28)
    private let stickBase: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width >= geo.size.height
            let w = geo.size.width, h = geo.size.height
            ZStack {
                dpadCross(landscape, w, h)
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
            shoulder("l1", "L1", .l1, l, w, h)
            shoulder("l2", "L2", .l2, l, w, h)
            shoulder("r1", "R1", .r1, l, w, h)
            shoulder("r2", "R2", .r2, l, w, h)
        }
    }

    @ViewBuilder
    private func systemButtons(_ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            systemPill("select", "SELECT", .select, l, w, h)
            systemPill("start", "START", .start, l, w, h)
        }
    }

    @ViewBuilder
    private func directions(_ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            dirButton("up", "chevron.up", .up, l, w, h)
            dirButton("down", "chevron.down", .down, l, w, h)
            dirButton("left", "chevron.left", .left, l, w, h)
            dirButton("right", "chevron.right", .right, l, w, h)
        }
    }

    @ViewBuilder
    private func faces(_ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            faceButton("triangle", "△", .triangle, l, w, h)
            faceButton("circle", "◯", .circle, l, w, h)
            faceButton("cross", "✕", .cross, l, w, h)
            faceButton("square", "□", .square, l, w, h)
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

    private func groupCenter(_ id: String, _ l: Bool, _ w: CGFloat, _ h: CGFloat) -> (CGPoint, CGFloat, CGFloat) {
        let p = layout.position(for: id, landscape: l)
        return (CGPoint(x: p.x * w, y: p.y * h), p.scale, p.hitScale)
    }
    private func buttonCenter(_ id: String, _ l: Bool, _ w: CGFloat, _ h: CGFloat) -> (CGPoint, CGFloat, CGFloat) {
        let p = layout.perButtonPosition(for: id, landscape: l, areaW: w, areaH: h)
        return (CGPoint(x: p.x * w, y: p.y * h), p.scale, p.hitScale)
    }

    // MARK: Controls

    @ViewBuilder
    private func shoulder(_ id: String, _ label: String, _ btn: PadButton, _ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        if layout.isControlVisible(id) {
            let (c, s, hit) = groupCenter(id, l, w, h)
            TouchControl(button: btn, core: core,
                         visual: CGSize(width: shoulderBase.width * s, height: shoulderBase.height * s),
                         hitArea: CGSize(width: shoulderBase.width * hit, height: shoulderBase.height * hit),
                         shape: .capsule) { down in
                ZStack {
                    Capsule().fill(down ? PS3.primary.opacity(0.9) : Color.white.opacity(0.14))
                    Capsule().strokeBorder(.white.opacity(0.25))
                    Text(label).font(.system(size: 14, weight: .bold)).foregroundStyle(down ? .white : PS3.text)
                }
            }.position(c)
        }
    }

    @ViewBuilder
    private func systemPill(_ id: String, _ label: String, _ btn: PadButton, _ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        if layout.isControlVisible(id) {
            let (c, s, hit) = groupCenter(id, l, w, h)
            TouchControl(button: btn, core: core,
                         visual: CGSize(width: sysBase.width * s, height: sysBase.height * s),
                         hitArea: CGSize(width: sysBase.width * hit, height: sysBase.height * hit),
                         shape: .capsule) { down in
                ZStack {
                    Capsule().fill(down ? PS3.primary.opacity(0.8) : Color.white.opacity(0.12))
                    Text(label).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(down ? .white : PS3.muted)
                }
            }.position(c)
        }
    }

    @ViewBuilder
    private func faceButton(_ id: String, _ glyph: String, _ btn: PadButton, _ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        if layout.isControlVisible(id) {
            let (c, s, hit) = buttonCenter(id, l, w, h)
            TouchControl(button: btn, core: core,
                         visual: CGSize(width: faceBase * s, height: faceBase * s),
                         hitArea: CGSize(width: faceBase * hit, height: faceBase * hit),
                         shape: .circle) { down in
                ZStack {
                    Circle().fill(down ? PS3.primary.opacity(0.85) : Color.white.opacity(0.10))
                    Circle().strokeBorder(.white.opacity(0.28))
                    Text(glyph).font(.system(size: 22 * s, weight: .regular)).foregroundStyle(down ? .white : PS3.text)
                }
            }.position(c)
        }
    }

    @ViewBuilder
    private func dirButton(_ id: String, _ symbol: String, _ btn: PadButton, _ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        if layout.isControlVisible(id) {
            let (c, s, hit) = buttonCenter(id, l, w, h)
            TouchControl(button: btn, core: core,
                         visual: CGSize(width: dirBase * s, height: dirBase * s),
                         hitArea: CGSize(width: dirBase * hit, height: dirBase * hit),
                         shape: .rect) { down in
                Image(systemName: symbol).font(.system(size: 20 * s, weight: .bold))
                    .foregroundStyle(down ? PS3.cyan : PS3.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.position(c)
        }
    }

    @ViewBuilder
    private func dpadCross(_ l: Bool, _ w: CGFloat, _ h: CGFloat) -> some View {
        if layout.isControlVisible("dpad") {
            let (c, s, _) = groupCenter("dpad", l, w, h)
            ZStack {
                Capsule().fill(.white.opacity(0.07)).frame(width: 34 * s, height: 104 * s)
                Capsule().fill(.white.opacity(0.07)).frame(width: 104 * s, height: 34 * s)
                Capsule().strokeBorder(.white.opacity(0.14)).frame(width: 34 * s, height: 104 * s)
                Capsule().strokeBorder(.white.opacity(0.14)).frame(width: 104 * s, height: 34 * s)
            }
            .position(c)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func stick(_ id: String, _ l: Bool, _ w: CGFloat, _ h: CGFloat, onChange: @escaping (Float, Float) -> Void) -> some View {
        if layout.isControlVisible(id) {
            let (c, s, hit) = groupCenter(id, l, w, h)
            AnalogStick(base: stickBase * s, hit: stickBase * hit, onChange: onChange).position(c)
        }
    }
}

// MARK: - Unified touch control (visual size vs hit size)

private struct TouchControl<V: View>: View {
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

// MARK: - Analog stick (draggable thumb)

private struct AnalogStick: View {
    let base: CGFloat
    let hit: CGFloat
    let onChange: (Float, Float) -> Void
    @State private var thumb: CGSize = .zero

    private var radius: CGFloat { base * 0.34 }

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.06))
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                .frame(width: base, height: base)
            Circle().fill(
                LinearGradient(colors: [Color.white.opacity(0.85), PS3.primary.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(.white.opacity(0.5)))
                .frame(width: base * 0.5, height: base * 0.5)
                .offset(thumb)
                .shadow(color: PS3.primary.opacity(0.4), radius: 6)
        }
        .frame(width: hit, height: hit)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.location.x - hit / 2
                    let dy = v.location.y - hit / 2
                    let dist = max(1, (dx * dx + dy * dy).squareRoot())
                    let clamped = min(dist, radius)
                    let nx = dx / dist * clamped
                    let ny = dy / dist * clamped
                    thumb = CGSize(width: nx, height: ny)
                    onChange(Float(nx / radius), Float(ny / radius))
                }
                .onEnded { _ in thumb = .zero; onChange(0, 0) }
        )
    }
}
