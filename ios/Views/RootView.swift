// RootView.swift — first PS3-themed screen (milestone 1).
//
// A deliberately simple SwiftUI library screen in the XMB palette. It also
// exercises the ported systems (pad layout, skins, presets, language, external
// library) so this build doubles as an on-device smoke test that they compile,
// link, and initialize.

import SwiftUI

struct RootView: View {
    private let lang = AppLanguage.system

    // Placeholder library until the core + scraper land.
    private let sampleTitles = [
        "Demon's Souls", "Uncharted 3", "Metal Gear Solid 4",
        "Gran Turismo 6", "The Last of Us", "Ni no Kuni",
    ]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ZStack {
            xmbBackground
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(sampleTitles, id: \.self) { title in
                            gameTile(title)
                        }
                    }
                    .padding(20)
                }
                systemsFooter
            }
        }
    }

    // MARK: Pieces

    private var xmbBackground: some View {
        LinearGradient(
            colors: [Color(hex: 0x0A1428), Color(hex: 0x05070E)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(
            RadialGradient(colors: [Color(hex: 0x1D4E8F).opacity(0.35), .clear],
                           center: .topTrailing, startRadius: 20, endRadius: 520)
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("iPS").font(.system(size: 40, weight: .heavy))
                .foregroundStyle(.white)
            Text("3").font(.system(size: 40, weight: .heavy))
                .foregroundStyle(Color(hex: 0x2A7BFF))
            Spacer()
            Text(lang.localized("Games").uppercased())
                .font(.system(size: 13, weight: .semibold))
                .tracking(2)
                .foregroundStyle(Color(hex: 0x7F97BD))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func gameTile(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(hex: 0x14294F), Color(hex: 0x080F1C)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .aspectRatio(3.0/4.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .overlay(Text("△ ◯ ✕ □").font(.system(size: 18))
                    .foregroundStyle(Color.white.opacity(0.18)))
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: 0xEAF1FF))
                .lineLimit(1)
        }
    }

    // Proves the ported systems link + initialize on-device.
    private var systemsFooter: some View {
        let padGroups = PadLayout.groupIDs.count
        let skin = VPadSkinLibraryStore.shared.selectedDescriptor.displayName
        let presets = PadLayoutPresetStore.shared.presets.count
        let external = ExternalGameLibrary.shared.directories.count
        return Text("systems ✓  pad groups: \(padGroups) · skin: \(skin) · presets: \(presets) · external: \(external)")
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(Color(hex: 0x5D6F8F))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.3))
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: alpha)
    }
}
