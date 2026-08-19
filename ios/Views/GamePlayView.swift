// GamePlayView.swift — in-game screen (placeholder surface + touch controller).
//
// Until the core is linked there is no Metal surface to show, so this presents a
// dark stand-in with the game title and overlays the real VirtualControllerView.
// It exists to make the ported pad system visible and testable on-device now.

import SwiftUI

struct GamePlayView: View {
    let title: String
    @Binding var isPresented: Bool
    @State private var editingLayout = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width >= geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()

                if landscape {
                    // Landscape: controls overlay the full-screen game surface,
                    // so their normalized positions map to the whole screen.
                    gameSurface
                    VirtualControllerView(isLandscape: true)
                } else {
                    // Portrait: game viewport on top, controller deck below.
                    // The controls' normalized positions map into the deck only.
                    let gameHeight = min(geo.size.width * 3 / 4, geo.size.height * 0.55)
                    VStack(spacing: 0) {
                        gameSurface
                            .frame(height: gameHeight)
                            .clipped()
                        ZStack {
                            Color.black
                            VirtualControllerView(isLandscape: false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                menuBar

                if editingLayout {
                    PadLayoutEditorView(isPresented: $editingLayout)
                }
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }

    // Placeholder "game surface" until the core is linked.
    private var gameSurface: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                Text("core not linked yet — controller preview")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    // Exit / quick-menu, pinned to the top edge.
    private var menuBar: some View {
        VStack {
            HStack {
                Button { isPresented = false } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Menu").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(PS3.text)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.4), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { editingLayout = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Layout").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(PS3.text)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.4), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(16)
    }
}
