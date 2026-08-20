// GameScreenView.swift — the PS3 hero / library screen, driven by REAL data.
//
// The library is empty until the user imports a game; each row is an actual file
// in Documents/Games. Metadata shown is only what we can read for real — the
// title (PARAM.SFO for decrypted folders, else the file name), a parsed serial,
// the on-disk size, and the game's own cover/background (ICON0.PNG / PIC1.PNG)
// when present. No invented ratings, play-time, or descriptions.

import SwiftUI
import UIKit

enum MediaTab: String, CaseIterable, Identifiable {
    case info, box, shot, pad
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .info: return "doc.text"
        case .box: return "square.grid.2x2"
        case .shot: return "photo"
        case .pad: return "gamecontroller"
        }
    }
}

struct GameScreenView: View {
    private var library = GameLibrary.shared

    @State private var selected = 0
    @State private var tab: MediaTab = .info
    @State private var playing = false

    private var games: [LibraryGame] { library.games }
    private var game: LibraryGame? {
        games.indices.contains(selected) ? games[selected] : nil
    }

    private let referenceSize = CGSize(width: 900, height: 420)

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / referenceSize.width,
                            geo.size.height / referenceSize.height)
            ZStack {
                PS3.background
                if let bg = game?.backgroundPath, let img = UIImage(contentsOfFile: bg) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .ignoresSafeArea().opacity(0.25).blur(radius: 6)
                }
                leftVignette
                Group {
                    if games.isEmpty {
                        emptyState
                    } else {
                        content
                            .frame(width: referenceSize.width, height: referenceSize.height)
                            .scaleEffect(scale)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $playing) {
            if let g = game { GamePlayView(title: g.title, isPresented: $playing) }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            topBar.padding(.horizontal, 24).padding(.top, 16)
            Spacer()
            Image(systemName: "tray").font(.system(size: 44, weight: .thin)).foregroundStyle(PS3.muted)
            Text("Your library is empty")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            Text("Tap IMPORT to add a PS3 game (ISO / PKG / decrypted folder)\nor the firmware (PS3UPDAT.PUP).")
                .font(.system(size: 13)).foregroundStyle(PS3.muted)
                .multilineTextAlignment(.center)
            FileImportButton {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("IMPORT").font(.system(size: 14, weight: .heavy)).tracking(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 11)
                .background(PS3.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer()
        }
    }

    // MARK: Background chrome

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
        }
    }

    // MARK: Left rail

    private var leftRail: some View {
        VStack(spacing: 12) {
            railButton("line.3.horizontal", "MENU")
            railButton("arrow.clockwise", "REFRESH") { library.reload() }
            railButton("gearshape", "OPT")
        }
    }

    private func railButton(_ symbol: String, _ label: String, _ action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PS3.text)
                Text(label).font(.system(size: 8, weight: .bold)).tracking(0.5)
                    .foregroundStyle(PS3.muted)
            }
            .frame(width: 58, height: 46)
            .glassPanel(cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: Game list

    private var gameList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("PS").font(.system(size: 26, weight: .heavy)).foregroundStyle(.white)
                Text("3").font(.system(size: 26, weight: .heavy)).foregroundStyle(PS3.primary)
                Spacer()
                Text("\(games.count) GAME\(games.count == 1 ? "" : "S")")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(PS3.muted)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { i, g in
                        Button { selected = i } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.title)
                                    .font(.system(size: 15, weight: i == selected ? .semibold : .regular))
                                    .foregroundStyle(i == selected ? .white : PS3.muted)
                                    .lineLimit(1)
                                if let s = g.serial {
                                    Text(s).font(.system(size: 10, weight: .regular, design: .monospaced))
                                        .foregroundStyle(PS3.muted.opacity(0.8))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
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
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .glassPanel(cornerRadius: 16)
    }

    // MARK: Media panel

    @ViewBuilder private var mediaPanel: some View {
        switch tab {
        case .info: infoCard
        case .box: boxArt
        case .shot: screenshot
        case .pad: padPreview
        }
    }

    private var boxArt: some View {
        Group {
            if let c = game?.coverPath, let img = UIImage(contentsOfFile: c) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 16, x: -6, y: 10)
            } else {
                placeholder("No cover art", "photo.on.rectangle.angled",
                            "Cover comes from the game's ICON0.PNG (decrypted folders).")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 8)
    }

    private var screenshot: some View {
        Group {
            if let bg = game?.backgroundPath, let img = UIImage(contentsOfFile: bg) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(height: 240).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                placeholder("No screenshot", "photo",
                            "Background comes from the game's PIC1.PNG when available.")
                    .frame(height: 240)
            }
        }
        .padding(.top, 8)
    }

    private var padPreview: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x123A6E), PS3.void], center: .center, startRadius: 10, endRadius: 320)
            VStack(spacing: 8) {
                Text("△ ◯ ✕ □").font(.system(size: 34)).foregroundStyle(.white.opacity(0.4))
                Text("DualShock 3 · on-screen overlay")
                    .font(.system(size: 11)).foregroundStyle(PS3.cyan)
            }
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 8)
    }

    private func placeholder(_ title: String, _ symbol: String, _ note: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .thin)).foregroundStyle(PS3.muted)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(PS3.text)
            Text(note).font(.system(size: 11)).foregroundStyle(PS3.muted)
                .multilineTextAlignment(.center).padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .glassPanel(cornerRadius: 14)
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Game Info").font(.system(size: 15, weight: .bold)).foregroundStyle(PS3.text)
            if let g = game {
                infoRow("File", g.fileName)
                infoRow("Serial", g.serial ?? "—")
                infoRow("Type", g.isFolder ? "Folder" : "Image")
                infoRow("Size", g.sizeText)
            }
            Text("Cover, background and title are read from the game itself (PARAM.SFO / ICON0.PNG / PIC1.PNG) — nothing is fetched online.")
                .font(.system(size: 11)).foregroundStyle(PS3.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
        .padding(14).glassPanel(cornerRadius: 14).padding(.top, 8)
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 12, weight: .semibold)).foregroundStyle(PS3.muted).frame(width: 60, alignment: .leading)
            Text(v).font(.system(size: 12, weight: .regular, design: .monospaced)).foregroundStyle(Color(hex: 0xD3E2FB))
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(game?.title ?? "—").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1).shadow(color: .black.opacity(0.6), radius: 2, x: 1, y: 1)
                Text([game?.serial, game?.sizeText].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer(minLength: 12)
            playButton.disabled(game == nil).opacity(game == nil ? 0.4 : 1)
        }
    }

    private var playButton: some View {
        Button {
            guard let g = game else { return }
            #if IPS3_WITH_CORE
            AppState.shared.bootGame(name: g.fileName)
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
