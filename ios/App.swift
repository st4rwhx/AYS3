// App.swift — iPS3 SwiftUI entry point.
//
// Milestone 1: a standalone SwiftUI shell that compiles the ported systems and
// renders the first PS3 screen. No emulator core is linked yet — this validates
// the Swift toolchain and the systems layer end to end, on-device.

import SwiftUI

@main
struct iPS3App: App {
    @State private var language = AppLanguage.system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.layoutDirection, language.layoutDirection)
                .preferredColorScheme(.dark)
        }
    }
}
