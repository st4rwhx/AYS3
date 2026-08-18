// AppState.swift — top-level screen state + game lifecycle.
//
// Ported from the prior project. Owns which screen is shown (library vs playing), the running
// game, and system-chrome flags, and drives boot / return / reset through the
// active EmuCore. The core's bridge posts the shutdown / auto-boot notifications
// this observes. JIT enablement (for the recompiler path) is an injectable hook
// so this file stays core- and debugger-agnostic.

import Foundation
import Observation

@Observable
final class AppState: @unchecked Sendable {
    static let shared = AppState()
    static let systemChromeNeedsUpdateNotification = Notification.Name("iPS3SystemChromeNeedsUpdate")

    // Notifications the active core's bridge posts.
    static let vmDidShutdownNotification = Notification.Name("iPS3VMDidShutdown")
    static let autoBootDidStartNotification = Notification.Name("iPS3AutoBootDidStart")
    static let returnToMenuNotification = Notification.Name("iPS3ReturnToMenu")
    static let enterGameScreenNotification = Notification.Name("iPS3EnterGameScreen")

    enum Screen { case menu, playing }

    /// The loaded core (PS2 or PS3). Set when a console's core is brought up.
    @ObservationIgnored var core: EmuCore?
    /// Optional hook to request JIT (recompiler) before a boot — wired by the app
    /// to launch the external debugger. No-op when unset (interpreter still boots).
    @ObservationIgnored var requestJIT: ((_ reason: String) -> Void)?

    var currentScreen: Screen = .menu
    var selectedTab: Int = 0
    var runningGameName: String? = nil
    var hideStatusBar: Bool = false {
        didSet { if oldValue != hideStatusBar { postChromeUpdate() } }
    }
    var hideHomeIndicator: Bool = false {
        didSet { if oldValue != hideHomeIndicator { postChromeUpdate() } }
    }

    @ObservationIgnored private var pendingBootAction: (() -> Void)?
    @ObservationIgnored private var shutdownObserver: NSObjectProtocol?
    @ObservationIgnored private var autoBootObserver: NSObjectProtocol?

    private init() {
        shutdownObserver = NotificationCenter.default.addObserver(
            forName: Self.vmDidShutdownNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.runningGameName = nil
            if let action = self?.pendingBootAction {
                self?.pendingBootAction = nil
                action()
            } else {
                self?.currentScreen = .menu
            }
        }
        autoBootObserver = NotificationCenter.default.addObserver(
            forName: Self.autoBootDidStartNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.runningGameName = "AutoBoot"
            self?.currentScreen = .playing
        }
    }

    private func postChromeUpdate() {
        NotificationCenter.default.post(name: Self.systemChromeNeedsUpdateNotification, object: nil)
    }

    func bootGame(name: String) {
        requestJIT?("game boot")
        core?.boot(game: name)
        runningGameName = name
        currentScreen = .playing
    }

    func returnToMenu() {
        if core?.isRunning == true { core?.setPaused(true) }
        currentScreen = .menu
        NotificationCenter.default.post(name: Self.returnToMenuNotification, object: nil)
    }

    func returnToGame() {
        guard runningGameName != nil else { return }
        NotificationCenter.default.post(name: Self.enterGameScreenNotification, object: nil)
        currentScreen = .playing
        core?.setPaused(false)
    }

    func shutdownAndBoot(name: String) {
        pendingBootAction = { [weak self] in self?.bootGame(name: name) }
        core?.shutdown()
    }

    func resetCurrentVM() {
        guard let runningGameName else { return }
        shutdownAndBoot(name: runningGameName)
    }
}
