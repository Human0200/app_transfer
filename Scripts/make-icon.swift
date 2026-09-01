import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sizes = [16, 32, 128, 256, 512]

func makeIcon(size: Int, scale: Int) -> NSImage {
    let pixels = CGFloat(size * scale)
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()

    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let background = NSBezierPath(roundedRect: bounds, xRadius: pixels * 0.22, yRadius: pixels * 0.22)
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
    background.fill()

    let letter = "R" as NSString
    let font = NSFont.systemFont(ofSize: pixels * 0.63, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.95, green: 0.27, blue: 0.25, alpha: 1)
    ]
    let textSize = letter.size(withAttributes: attributes)
    let textRect = NSRect(
        x: (pixels - textSize.width) / 2,
        y: (pixels - textSize.height) / 2 - pixels * 0.02,
        width: textSize.width,
        height: textSize.height
    )
    letter.draw(in: textRect, withAttributes: attributes)
    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "AppTransferIcon", code: 1)
    }
    try data.write(to: url)
}

for size in sizes {
    try writePNG(makeIcon(size: size, scale: 1), to: outputDirectory.appendingPathComponent("icon_\(size)x\(size).png"))
    try writePNG(makeIcon(size: size, scale: 2), to: outputDirectory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
