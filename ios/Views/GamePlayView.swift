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
        ZStack {
            // Placeholder "game surface".
            Color.black.ignoresSafeArea()
            VStack(spacing: 8) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                Text("core not linked yet — controller preview")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // The real ported controller.
            VirtualControllerView()

            // Exit / quick-menu.
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

            if editingLayout {
                PadLayoutEditorView(isPresented: $editingLayout)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }
}
