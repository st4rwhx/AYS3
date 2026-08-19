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
                .task {
                    // Measure the real VA ceiling once at launch: this is the
                    // gate for whether a game can boot at all (extended-VA
                    // effective?), captured before anything else runs.
                    MemoryReport.shared.logVAProbe()
                    MemoryReport.shared.log("launch")
                }
        }
    }
}
