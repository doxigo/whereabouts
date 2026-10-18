import AppKit

// Draws the README's menu-bar strip with the app's own StampGlyph, the way the
// status item draws itself: colored glyph (the default) plus the place label.
//   swiftc -parse-as-library menubar.swift ../Sources/Whereabouts/StampGlyph.swift -o menubar
//   ./menubar <out.png> light|dark
@main
enum MenuBarStrip {
    static func main() throws {
        let args = CommandLine.arguments
        let dark = args[2] == "dark"
        let items: [(StampGlyph.Mark, NSColor, String)] = [
            (.admitted, .systemGreen, "PT · Sun 18 Oct 21:47"),
            (.leak, .systemOrange, "PT · Sun 18 Oct 21:47"),
            (.blocked, .systemRed, "Blocked"),
        ]
        let scale: CGFloat = 2, height: CGFloat = 30, pad: CGFloat = 14, gap: CGFloat = 34
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let ink = dark ? NSColor.white : NSColor(white: 0.1, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let widths = items.map { 21 + 5 + ($0.2 as NSString).size(withAttributes: attrs).width }
        let width = pad * 2 + widths.reduce(0, +) + gap * CGFloat(items.count - 1)

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: 9, yRadius: 9).fill()
        var x = pad
        for (i, (mark, color, title)) in items.enumerated() {
            StampGlyph.image(mark, color: color).draw(in: NSRect(x: x, y: (height - 16) / 2, width: 21, height: 16))
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: x + 26, y: (height - size.height) / 2), withAttributes: attrs)
            x += widths[i] + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
    }
}
