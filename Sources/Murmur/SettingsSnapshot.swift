import AppKit
import SwiftUI

@MainActor
enum SettingsSnapshot {
    /// Debug: `Murmur --render-settings out.png` draws the settings window to an image and quits.
    static func renderSettings(to path: String) throws {
        let view = NSHostingView(rootView: SettingsView())
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 660)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        if let scroll = view.firstScrollView { scroll.documentView?.scroll(NSPoint(x: 0, y: scroll.documentView!.bounds.height)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MurmurError("Could not draw") }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

}

private extension NSView {
    var firstScrollView: NSScrollView? {
        if let scroll = self as? NSScrollView { return scroll }
        for sub in subviews { if let found = sub.firstScrollView { return found } }
        return nil
    }
}
