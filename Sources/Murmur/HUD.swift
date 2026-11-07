import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Mode: Equatable { case listening, handsFree, working, message(String) }

    @Published var mode: Mode = .listening
    @Published var levels = [Float](repeating: 0, count: 18)
    @Published var keyName = "fn"
    @Published var liveText = ""

    /// The end of what was said so far, so the newest words are always on screen.
    var liveTail: String {
        let text = liveText.trimmingCharacters(in: .whitespaces)
        guard text.count > 150 else { return text }
        let tail = text.suffix(150)
        let cut = tail.firstIndex(of: " ").map { tail[tail.index(after: $0)...] } ?? tail
        return "…" + cut
    }

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// The small pill at the bottom of the screen. It never takes focus away from the app you type in.
@MainActor
final class HUD {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 560, height: 150)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ mode: HUDModel.Mode) {
        hideWork?.cancel()
        if mode == .listening || mode == .handsFree {
            model.levels = [Float](repeating: 0, count: model.levels.count)
            model.keyName = Pref.triggerName
        }
        model.mode = mode
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
        }
        panel.orderFrontRegardless()
    }

    func flash(_ message: String, seconds: Double = 2.2) {
        show(.message(message))
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    /// Debug: draws the pill in a given state to a PNG.
    func snapshot(_ mode: HUDModel.Mode, liveText: String, to path: String) throws {
        model.mode = mode
        model.liveText = liveText
        model.levels = (0 ..< model.levels.count).map { Float(abs(sin(Double($0) * 0.7))) * 0.06 }
        guard let view = panel.contentView else { return }
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MurmurError("Could not draw") }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    private var showsWords: Bool {
        guard !model.liveText.isEmpty else { return false }
        switch model.mode {
        case .listening, .handsFree, .working: return true
        case .message: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsWords {
                Text(model.liveTail)
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .frame(width: 440, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(model.mode == .working ? 0.55 : 1)
            }
            statusRow
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, showsWords ? 10 : 0)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.84)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: showsWords)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .listening, .handsFree:
                Circle().fill(.red).frame(width: 8, height: 8)
                LevelBars(levels: model.levels)
                if model.mode == .handsFree {
                    Text("Hands-free · \(model.keyName) to finish")
                }
            case .working:
                ProgressView().controlSize(.small)
                Text("Writing…")
            case .message(let text):
                Text(text).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .frame(minHeight: 36)
    }
}

private struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 3 + CGFloat(min(1, levels[i] * 14)) * 17)
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: levels)
    }
}
