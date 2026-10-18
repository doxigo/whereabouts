import AppKit

// Rasterizes an SVG with AppKit's own SVG support, so the icon needs no extra tools.
//   render <in.svg> <out.png> <width> [height]
let args = CommandLine.arguments
guard args.count >= 4, let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])),
      let width = Int(args[3]) else {
    FileHandle.standardError.write("usage: render <in.svg> <out.png> <width> [height]\n".data(using: .utf8)!)
    exit(1)
}
// Height defaults to the SVG's own aspect ratio.
let height = args.count > 4 ? Int(args[4])! : Int((Double(width) * image.size.height / image.size.width).rounded())
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
