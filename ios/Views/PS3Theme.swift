// PS3Theme.swift — the XMB-flavoured design system.
//
// One place for the palette and reusable styling, mirroring how the reference
// frontend keeps a named theme. Deep blue-black ground, electric-blue accent,
// cyan highlight, gold rating — the PlayStation 3 "XMB" world.

import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: alpha)
    }
}

/// Named XMB palette. Kept as a namespace so views read `PS3.primary`, etc.
enum PS3 {
    static let void = Color(hex: 0x050912)
    static let deep = Color(hex: 0x0A1730)
    static let surface = Color(hex: 0x0E1F3D)
    static let primary = Color(hex: 0x2A7BFF)
    static let primaryDim = Color(hex: 0x1E5FD6)
    static let cyan = Color(hex: 0x78E3FF)
    static let gold = Color(hex: 0xFFD15A)
    static let text = Color(hex: 0xEAF1FF)
    static let muted = Color(hex: 0x7F97BD)
    static let muted2 = Color(hex: 0x5D6F8F)
    static let outline = Color.white.opacity(0.10)
    static let outlineHi = Color(hex: 0x96BEFF, alpha: 0.42)

    /// The full-screen XMB ground: blue-black gradient + a soft top-right glow.
    static var background: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0A1428), void],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: 0x1D4E8F).opacity(0.35), .clear],
                           center: .topTrailing, startRadius: 20, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

/// A frosted glass surface used for panels and pills.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(PS3.surface.opacity(0.86), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(PS3.outline, lineWidth: 1)
            )
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}
