// PadLayoutEditorView.swift — drag-to-move + resize the on-screen controls.
//
// Edits the live PadLayoutStore for the current orientation: drag a control to
// reposition (normalized), and use the sliders to set its VISUAL size and its
// (independent) TOUCH size — the dual-scale editor from the prior project. Done
// persists through the active core's config; Reset restores the defaults.

import SwiftUI

struct PadLayoutEditorView: View {
    var layout: PadLayoutStore = .shared
    @Binding var isPresented: Bool
    @State private var selected: String = "dpad"

    private let groups = PadLayout.groupIDs

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width >= geo.size.height
            let w = geo.size.width, h = geo.size.height
            // Chips are laid out in the same area the live controls occupy:
            // the whole screen in landscape, the bottom deck in portrait. This
            // keeps the editor's normalized positions aligned with gameplay.
            let gameHeight = landscape ? 0 : min(w * 3 / 4, h * 0.55)
            let originY = gameHeight
            let areaW = w
            let areaH = h - gameHeight
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.55).ignoresSafeArea()
                    .onTapGesture { }   // swallow taps on the dim layer

                if !landscape {
                    // Mirror the gameplay split so the deck edge is visible.
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: areaW, height: areaH)
                        .overlay(alignment: .top) {
                            Rectangle().fill(PS3.cyan.opacity(0.4)).frame(height: 1)
                        }
                        .position(x: originY == 0 ? w / 2 : areaW / 2, y: originY + areaH / 2)
                }

                chips(landscape, originY, areaW, areaH)

                topBar(landscape)
                    .frame(maxHeight: .infinity, alignment: .top)

                panel(landscape)
            }
            .coordinateSpace(name: Self.space)
        }
        .preferredColorScheme(.dark)
    }

    private static let space = "padEditArea"

    // MARK: Chips

    @ViewBuilder
    private func chips(_ l: Bool, _ originY: CGFloat, _ areaW: CGFloat, _ areaH: CGFloat) -> some View {
        ForEach(groups, id: \.self) { id in
            let p = layout.position(for: id, landscape: l)
            let size = chipSize(id, p.scale)
            let isSel = id == selected
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSel ? PS3.primary.opacity(0.35) : Color.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSel ? PS3.cyan : .white.opacity(0.3), lineWidth: isSel ? 2 : 1)
                Text(chipLabel(id)).font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white).minimumScaleFactor(0.5).padding(4)
            }
            .frame(width: size.width, height: size.height)
            .position(x: p.x * areaW, y: originY + p.y * areaH)
            .gesture(
                DragGesture(coordinateSpace: .named(Self.space))
                    .onChanged { v in
                        selected = id
                        var np = layout.position(for: id, landscape: l)
                        np.x = min(max(v.location.x / areaW, 0), 1)
                        np.y = min(max((v.location.y - originY) / areaH, 0), 1)
                        layout.setGroupPosition(np, for: id, landscape: l)
                    }
            )
            .onTapGesture { selected = id }
        }
    }

    private func chipSize(_ id: String, _ scale: CGFloat) -> CGSize {
        let base: CGSize
        switch id {
        case "dpad", "action": base = CGSize(width: 116, height: 116)
        case "lstick", "rstick": base = CGSize(width: 104, height: 104)
        case "l1", "l2", "r1", "r2": base = CGSize(width: 86, height: 40)
        case "select", "start": base = CGSize(width: 66, height: 30)
        default: base = CGSize(width: 80, height: 44)
        }
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    private func chipLabel(_ id: String) -> String {
        switch id {
        case "dpad": return "＋"
        case "action": return "○△✕□"
        case "lstick": return "L"
        case "rstick": return "R"
        case "select": return "SEL"
        case "start": return "START"
        default: return id.uppercased()
        }
    }

    // MARK: Top bar

    @ViewBuilder
    private func topBar(_ l: Bool) -> some View {
        HStack {
            editorButton("Reset", "arrow.counterclockwise") {
                layout.reset(isLandscape: l)
            }
            Spacer()
            Text("EDIT CONTROLS").font(.system(size: 12, weight: .bold)).tracking(2)
                .foregroundStyle(PS3.muted)
            Spacer()
            editorButton("Done", "checkmark") {
                layout.save()
                isPresented = false
            }
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private func editorButton(_ label: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(PS3.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Bottom panel (size / touch / visibility)

    @ViewBuilder
    private func panel(_ l: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selected.uppercased())
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text("Visible").font(.system(size: 12)).foregroundStyle(PS3.muted)
                Toggle("Visible", isOn: visibilityBinding(l))
                    .labelsHidden()
                    .tint(PS3.primary)
            }
            sliderRow("Size", icon: "arrow.up.left.and.arrow.down.right", binding: scaleBinding(l))
            sliderRow("Touch", icon: "hand.tap", binding: hitBinding(l))
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(PS3.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PS3.outline))
        .padding(.bottom, 16)
    }

    private func sliderRow(_ label: String, icon: String, binding: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(PS3.muted).frame(width: 20)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(PS3.text).frame(width: 46, alignment: .leading)
            Slider(value: binding, in: 0.5...2.5).tint(PS3.primary)
            Text(String(format: "%.2f×", binding.wrappedValue))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(PS3.muted).frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: Bindings

    private func scaleBinding(_ l: Bool) -> Binding<Double> {
        Binding(
            get: { Double(layout.position(for: selected, landscape: l).scale) },
            set: { layout.updateGroupScale(selected, scale: CGFloat($0), landscape: l) }
        )
    }
    private func hitBinding(_ l: Bool) -> Binding<Double> {
        Binding(
            get: { Double(layout.position(for: selected, landscape: l).hitScale) },
            set: { layout.updateGroupHitScale(selected, hitScale: CGFloat($0), landscape: l) }
        )
    }
    private func visibilityBinding(_ l: Bool) -> Binding<Bool> {
        Binding(
            get: { layout.isControlVisible(selected) },
            set: { layout.setControlVisible(selected, visible: $0) }
        )
    }
}
