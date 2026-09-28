import AppKit

// Run after actual app startup, before opening the index or touching preferences.
enum IconCheck {
  static func bitmap(_ image: NSImage) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }

  static func difference(_ actual: NSImage, _ expected: NSImage) -> Double {
    let a = bitmap(actual), b = bitmap(expected)
    var total = 0.0
    for y in 0..<256 {
      for x in 0..<256 {
        let c = a.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        let d = b.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        total += abs(c.redComponent - d.redComponent)
          + abs(c.greenComponent - d.greenComponent)
          + abs(c.blueComponent - d.blueComponent)
          + abs(c.alphaComponent - d.alphaComponent)
      }
    }
    return total / (256 * 256 * 4)
  }

  static func run(output: String) {
    var failure: String?
    if let url = Bundle.main.url(forResource: "icon", withExtension: "icns"),
      let expected = NSImage(contentsOf: url) {
      // AppKit can resample/color-convert the assigned image. Compare rendered
      // colors with a small tolerance, rather than encoded image bytes.
      if difference(NSApp.applicationIconImage, expected) > 0.005 {
        failure = "Running app icon differs from the current bundle icon"
      }
    } else {
      failure = "Bundle icon is missing or unreadable"
    }
    do {
      try JSONSerialization.data(withJSONObject: [
        "checks": failure == nil ? ["Running app icon matches current bundle"] : [],
        "error": failure as Any? ?? NSNull(),
      ], options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output))
    } catch {
      fputs("Icon-check report failed: \(error)\n", stderr)
      exit(1)
    }
    exit(failure == nil ? 0 : 1)
  }
}
