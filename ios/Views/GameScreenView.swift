// GameScreenView.swift — the PS3 hero / detail screen.
//
// A faithful SwiftUI port of the approved XMB mockup: a full-bleed art ground,
// a left game list, media tabs (L1/R1), a boxart / screenshot / info panel, and
// a footer with rating, play-time and a glossy PLAY. Placeholder library until
// the core + scraper land. Best viewed in landscape (the 10-foot layout).

import SwiftUI

struct HeroGame: Identifiable {
    let id = UUID()
    let title: String
    let fileID: String
    let rating: Double
    let playtime: String
    let tint: UInt32
    let year: String
    let publisher: String
    let players: String
    let desc: String
}

enum MediaTab: String, CaseIterable, Identifiable {
    case pad, box, shot, info
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .pad: return "gamecontroller"
        case .box: return "square.grid.2x2"
        case .shot: return "photo"
        case .info: return "doc.text"
        }
    }
}

struct GameScreenView: View {
    private let games: [HeroGame] = [
        HeroGame(title: "Demon's Souls", fileID: "BLES-00932 · CRC 6f2b41ac", rating: 9.1,
                 playtime: "04:12", tint: 0xBE322D, year: "2009", publisher: "SCE Japan Studio",
                 players: "1P", desc: "A cursed kingdom, a fog that swallows heroes whole. Reclaim souls, or become one."),
        HeroGame(title: "Uncharted 3: Drake's Deception", fileID: "BCES-01175 · CRC a1c9e004", rating: 9.4,
                 playtime: "02:41", tint: 0xCD963C, year: "2011", publisher: "Naughty Dog",
                 players: "1P", desc: "Nathan Drake follows Sir Francis Drake across desert and sea toward the fabled Atlantis of the Sands."),
        HeroGame(title: "Metal Gear Solid 4", fileID: "BLES-00246 · CRC 3d70f88b", rating: 9.3,
                 playtime: "06:20", tint: 0x5A785A, year: "2008", publisher: "Konami",
                 players: "1P", desc: "Old Snake returns for one last mission in a world consumed by proxy war."),
        HeroGame(title: "Gran Turismo 6", fileID: "BCES-01893 · CRC 7ac21100", rating: 8.7,
                 playtime: "12:56", tint: 0x3C78DC, year: "2013", publisher: "Polyphony Digital",
                 players: "1-2P", desc: "The real driving simulator — 1200 cars, from kei to Le Mans."),
        HeroGame(title: "The Last of Us", fileID: "BCES-01584 · CRC c0d9b312", rating: 9.6,
                 playtime: "08:03", tint: 0x788C5A, year: "2013", publisher: "Naughty Dog",
                 players: "1P", desc: "Twenty years after the outbreak, a smuggler escorts a girl who might be humanity's last hope."),
    ]

    @State private var selected = 1
    @State private var tab: MediaTab = .box
    @State private var playing = false

    private var game: HeroGame { games[selected] }

    // The layout is authored at a fixed reference size and scaled to fit the
    // device's safe area — so it looks identical (and never clips) on any
    // iPhone, exactly like the 10-foot mockup.
    private let referenceSize = CGSize(width: 900, height: 420)

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / referenceSize.width,
                            geo.size.height / referenceSize.height)
            ZStack {
                PS3.background
                artWash
                leftVignette
                content
                    .frame(width: referenceSize.width, height: referenceSize.height)
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $playing) {
            GamePlayView(title: game.title, isPresented: $playing)
        }
    }

    // MARK: Background

    private var artWash: some View {
        RadialGradient(colors: [Color(hex: game.tint).opacity(0.28), .clear],
                       center: .init(x: 0.72, y: 0.32), startRadius: 20, endRadius: 500)
            .blur(radius: 4)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: selected)
    }

    private var leftVignette: some View {
        LinearGradient(colors: [PS3.void.opacity(0.95), PS3.void.opacity(0.4), .clear],
                       startPoint: .leading, endPoint: .trailing)
            .ignoresSafeArea()
    }

    // MARK: Layout

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar.padding(.horizontal, 20).padding(.top, 12)
            HStack(alignment: .top, spacing: 16) {
                leftRail
                gameList.frame(maxWidth: 320)
                Spacer(minLength: 8)
                mediaPanel.frame(maxWidth: 380)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            Spacer(minLength: 8)
            footer.padding(.horizontal, 20).padding(.bottom, 18)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(PS3.cyan).frame(width: 7, height: 7)
                Text("LIBRARY · PLAYSTATION 3")
                    .font(.system(size: 12, weight: .semibold)).tracking(2)
                    .foregroundStyle(PS3.muted)
            }
            Spacer()
            FileImportButton {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                    Text("IMPORT").font(.system(size: 11, weight: .bold)).tracking(1)
                }
                .foregroundStyle(PS3.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .glassPanel(cornerRadius: 10)
            }
            bumper("L1")
            HStack(spacing: 4) {
                ForEach(MediaTab.allCases) { t in
                    Button { tab = t } label: {
                        Image(systemName: t.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 30)
                            .foregroundStyle(tab == t ? Color.white : PS3.text)
                            .background(tab == t ? PS3.primary : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .glassPanel(cornerRadius: 12)
            bumper("R1")
        }
    }

    private func bumper(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .bold))
            .foregroundStyle(PS3.muted)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(PS3.outline))
    }

    // MARK: Left rail

    private var leftRail: some View {
        VStack(spacing: 12) {
            railButton("line.3.horizontal", "MENU")
            railButton("chevron.left", "◯ BACK")
            railButton("square.grid.2x2", "□ GRID")
            railButton("heart", "△ FAV")
            railButton("gearshape", "OPT")
        }
    }

    private func railButton(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PS3.text)
            Text(label).font(.system(size: 8, weight: .bold)).tracking(0.5)
                .foregroundStyle(PS3.muted)
        }
        .frame(width: 58, height: 46)
        .glassPanel(cornerRadius: 10)
    }

    // MARK: Game list

    private var gameList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("PS").font(.system(size: 26, weight: .heavy)).foregroundStyle(.white)
                Text("3").font(.system(size: 26, weight: .heavy)).foregroundStyle(PS3.primary)
                Spacer()
                Text("\(games.count) GAMES").font(.system(size: 10, weight: .semibold))
                    .tracking(1.5).foregroundStyle(PS3.muted)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)

            ForEach(Array(games.enumerated()), id: \.element.id) { i, g in
                Button { selected = i } label: {
                    Text(g.title)
                        .font(.system(size: 15, weight: i == selected ? .semibold : .regular))
                        .foregroundStyle(i == selected ? .white : PS3.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background {
                            if i == selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LinearGradient(colors: [PS3.primary.opacity(0.9), PS3.primary.opacity(0.28)],
                                                         startPoint: .leading, endPoint: .trailing))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: 16)
    }

    // MARK: Media panel

    @ViewBuilder private var mediaPanel: some View {
        switch tab {
        case .box: boxArt
        case .shot: screenshot
        case .pad: padPreview
        case .info: infoCard
        }
    }

    private var boxArt: some View {
        VStack(spacing: 0) {
            Text("PS3 · BLU-RAY DISC")
                .font(.system(size: 10, weight: .bold)).tracking(0.5)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(LinearGradient(colors: [Color(hex: 0xC4152A), Color(hex: 0x8C0F1F)],
                                           startPoint: .top, endPoint: .bottom))
            ZStack {
                LinearGradient(colors: [Color(hex: game.tint).opacity(0.6), PS3.void],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("△ ◯ ✕ □").font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: 190, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.5)))
        .shadow(color: .black.opacity(0.5), radius: 18, x: -8, y: 12)
        .rotation3DEffect(.degrees(-8), axis: (x: 0, y: 1, z: 0))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 8)
    }

    private var screenshot: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: game.tint), PS3.void],
                           center: .init(x: 0.3, y: 0.25), startRadius: 10, endRadius: 320)
            Text("1280×720 · in-game")
                .font(.system(size: 11, weight: .regular)).tracking(1)
                .foregroundStyle(PS3.cyan)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(10)
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PS3.outlineHi))
        .padding(.top, 8)
    }

    private var padPreview: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x123A6E), PS3.void],
                           center: .center, startRadius: 10, endRadius: 320)
            Text("△ ◯ ✕ □").font(.system(size: 34)).foregroundStyle(.white.opacity(0.4))
            Text("DualShock 3 · touch overlay")
                .font(.system(size: 11)).foregroundStyle(PS3.cyan)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10)
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 8)
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Game Info").font(.system(size: 15, weight: .bold)).foregroundStyle(PS3.text)
                Spacer()
                Text("\(game.publisher) · \(game.players) · \(game.year)")
                    .font(.system(size: 11)).foregroundStyle(PS3.muted)
            }
            Text(game.desc).font(.system(size: 13)).foregroundStyle(Color(hex: 0xD3E2FB))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .glassPanel(cornerRadius: 14)
        .padding(.top, 8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(game.title).font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1).shadow(color: .black.opacity(0.6), radius: 2, x: 1, y: 1)
                Text(game.fileID).font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                pill { HStack(spacing: 5) {
                    Text("★").foregroundStyle(PS3.gold)
                    Text(String(format: "%.1f", game.rating)).font(.system(size: 15, weight: .bold))
                        .foregroundStyle(PS3.gold).monospacedDigit()
                } }
                pill { HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(PS3.muted)
                    Text(game.playtime).font(.system(size: 15, weight: .bold)).monospacedDigit()
                        .foregroundStyle(PS3.text)
                } }
                playButton
            }
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12).padding(.vertical, 9)
            .glassPanel(cornerRadius: 10)
    }

    private var playButton: some View {
        Button {
            // In the merged build, boot a real imported game through the core
            // (falls back to the selected title so the boot path still runs and
            // reports its result). The frontend build just shows the preview.
            #if IPS3_WITH_CORE
            let target = AppState.shared.core?.availableGames().first?.fileName ?? game.title
            AppState.shared.bootGame(name: target)
            #endif
            playing = true
        } label: {
            HStack(spacing: 8) {
                Text("✕").font(.system(size: 15))
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.16), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.55)))
                Text("PLAY").font(.system(size: 16, weight: .heavy)).tracking(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(
                LinearGradient(colors: [Color(hex: 0x59A0FF), PS3.primary, PS3.primaryDim],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.6)))
            .shadow(color: PS3.primary.opacity(0.5), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
    }
}
