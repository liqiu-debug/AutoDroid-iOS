import AppKit

// Use an opaque CoreGraphics bitmap. Three-channel NSBitmapImageRep cannot
// create a drawing context on all macOS versions and previously produced black.
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("AutoJs6/app/src/main/res/mipmap-xxxhdpi/ic_app_launcher_adaptive_foreground.png")
guard let artwork = NSImage(contentsOf: source),
      let original = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Cannot load Android artwork or create icon context")
}
context.setFillColor(CGColor(red: 15.0 / 255, green: 22.0 / 255, blue: 38.0 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high
context.draw(original, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let output = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
