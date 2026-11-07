import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = Controller()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            do { try SettingsSnapshot.renderSettings(to: args[i + 1]) } catch { print(error.localizedDescription) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-hud"), i + 1 < args.count {
            let base = args[i + 1]
            let hud = HUD()
            let words = "So the plan for Friday is simple. First we ship the new onboarding to TestFlight, then we collect feedback from ten users, and on Monday we decide whether the paywall goes before or after the first lesson"
            try? hud.snapshot(.listening, liveText: "", to: base + "-1-start.png")
            try? hud.snapshot(.listening, liveText: "So the plan for Friday is simple. First we ship", to: base + "-2-short.png")
            try? hud.snapshot(.handsFree, liveText: words, to: base + "-3-long.png")
            try? hud.snapshot(.working, liveText: words, to: base + "-4-writing.png")
            exit(0)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        controller.onChange = { [weak self] in self?.updateIcon() }
        controller.start()
        updateIcon()
        if !AXIsProcessTrusted() || !Permissions.globeKeyDoesNothing { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    private func updateIcon() {
        let symbol: String
        switch controller.phase {
        case .recording: symbol = "waveform.circle.fill"
        case .working: symbol = "ellipsis.circle"
        case .idle: symbol = controller.hotkeysActive ? "waveform" : "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: controller.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let pasteLast = ActionItem("Type last dictation again") { [weak self] in self?.controller.pasteLast() }
        pasteLast.keyEquivalent = "v"
        pasteLast.keyEquivalentModifierMask = [.command, .option]
        pasteLast.isEnabled = !controller.history.entries.isEmpty
        menu.addItem(pasteLast)

        if controller.lastFailedSamples != nil {
            menu.addItem(ActionItem("Retry last recording") { [weak self] in self?.controller.retryLast() })
        }

        let entries = controller.history.entries
        if !entries.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent · click to copy", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in entries.prefix(8) { menu.addItem(historyItem(entry)) }
            if entries.count > 8 {
                let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for entry in entries.dropFirst(8).prefix(60) { sub.addItem(historyItem(entry)) }
                more.submenu = sub
                menu.addItem(more)
            }
            menu.addItem(ActionItem("Clear history") { [weak self] in self?.controller.history.clear() })
        }

        menu.addItem(.separator())
        let settings = ActionItem("Settings…") { [weak self] in self?.showSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = ActionItem("Quit Murmur") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func historyItem(_ entry: Entry) -> NSMenuItem {
        let oneLine = entry.text.replacingOccurrences(of: "\n", with: " ")
        let title = oneLine.count > 60 ? oneLine.prefix(57) + "…" : oneLine
        let item = ActionItem(String(title)) { [weak self] in self?.controller.copy(entry) }
        item.toolTip = entry.text
        return item
    }

    // MARK: - Settings window

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Murmur"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
