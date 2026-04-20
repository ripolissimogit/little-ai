import AppKit

let size: CGFloat = 1024
let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()

// Black rounded background (macOS app icon radius ≈ 22% of side).
let cornerRadius = size * 0.223
NSColor.black.setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
             xRadius: cornerRadius, yRadius: cornerRadius).fill()

// White hand symbol, rendered ~70% of the canvas for good prominence.
let symbolName = "hand.point.up.left.fill"
let pointSize: CGFloat = size * 0.62
let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    .applying(.init(hierarchicalColor: .white))

guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
      let symbol = base.withSymbolConfiguration(config) else {
    FileHandle.standardError.write(Data("failed to load symbol\n".utf8))
    exit(1)
}

let symbolSize = symbol.size
let origin = NSPoint(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2)
symbol.draw(in: NSRect(origin: origin, size: symbolSize))

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode png\n".utf8))
    exit(1)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try png.write(to: out)
print("wrote \(out.path) (\(png.count) bytes)")
