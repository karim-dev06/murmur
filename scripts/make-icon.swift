// Draws Murmur's app icon and writes Resources/AppIcon.icns.
// Run from the project folder:  swift scripts/make-icon.swift [graphite|paper|tangerine]
//   --preview out.png   draws all themes side by side instead
import AppKit

struct Theme {
    let top: NSColor, bottom: NSColor
    let bars: NSColor
    /// The middle bar, like the red light on a recorder. Nil keeps it the same as the others.
    let accent: NSColor?
    let sheen: CGFloat
}

func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let themes: [String: Theme] = [
    "graphite": Theme(top: rgb(0x3A3B40), bottom: rgb(0x16171A), bars: rgb(0xF4F2EE), accent: rgb(0xFF5A36), sheen: 0.10),
    "paper": Theme(top: rgb(0xFBF8F2), bottom: rgb(0xE9E2D6), bars: rgb(0x1E1E1E), accent: rgb(0xE8492A), sheen: 0.0),
    "tangerine": Theme(top: rgb(0xFF8A3D), bottom: rgb(0xE8451C), bars: rgb(0xFFFFFF), accent: nil, sheen: 0.18),
]
let order = ["graphite", "paper", "tangerine"]
var theme = themes["tangerine"]!

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: an 824 pt rounded square centred on a 1024 canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [theme.top, theme.bottom])!.draw(in: body, angle: -90)
    if theme.sheen > 0 {
        // Soft light from the top, like glass.
        NSGradient(colors: [NSColor.white.withAlphaComponent(theme.sheen), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()

    // A voice waveform: seven rounded bars, tallest in the middle.
    let heights: [CGFloat] = [0.20, 0.40, 0.66, 0.92, 0.66, 0.40, 0.20]
    let barWidth = 58 * s
    let gap = 34 * s
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let maxHeight = 520 * s
    var x = body.midX - total / 2
    for (i, h) in heights.enumerated() {
        let height = max(barWidth, maxHeight * h)
        let bar = NSRect(x: x, y: body.midY - height / 2, width: barWidth, height: height)
        (i == heights.count / 2 ? theme.accent ?? theme.bars : theme.bars).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
    let tile: CGFloat = 512
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(tile) * order.count, pixelsHigh: Int(tile), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    rgb(0xDADADA).setFill()
    NSRect(x: 0, y: 0, width: tile * CGFloat(order.count), height: tile).fill()
    for (n, name) in order.enumerated() {
        theme = themes[name]!
        let image = NSImage(size: NSSize(width: tile, height: tile))
        image.addRepresentation(drawIcon(size: tile))
        image.draw(in: NSRect(x: tile * CGFloat(n), y: 0, width: tile, height: tile))
    }
    NSGraphicsContext.restoreGraphicsState()
    try sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
    print("Wrote \(args[i + 1])")
    exit(0)
}
if let name = args.dropFirst().first, let chosen = themes[name] { theme = chosen }

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
