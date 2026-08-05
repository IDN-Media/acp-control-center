#!/usr/bin/env swift
// Render the 👻 emoji into macOS AppIcon PNGs using CoreText/AppKit.
// Renders a single 1024x1024 master, then resizes via `sips` to every
// required AppIcon size (avoids Retina 2x scaling issues with lockFocus).
import AppKit
import Foundation

let emoji = "\u{1F47B}" // 👻

let masterSize = 1024
let masterName = "master-1024.png"

let outDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("ACPControlCenter/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Render master at 1024x1024, ensuring a 1:1 pixel buffer (non-Retina).
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: masterSize,
    pixelsHigh: masterSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = NSSize(width: masterSize, height: masterSize)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let font = NSFont.systemFont(ofSize: CGFloat(masterSize) * 0.85)
let attrs: [NSAttributedString.Key: Any] = [.font: font]
let str = NSAttributedString(string: emoji, attributes: attrs)
let strSize = str.size()
str.draw(at: NSPoint(
    x: (CGFloat(masterSize) - strSize.width) / 2,
    y: (CGFloat(masterSize) - strSize.height) / 2
))
NSGraphicsContext.restoreGraphicsState()

let masterURL = outDir.appendingPathComponent(masterName)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to render master\n", stderr)
    exit(1)
}
try? png.write(to: masterURL)
print("master: 1024x1024 -> \(masterURL.path)")

// Resize to all required sizes with sips.
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in sizes {
    let out = outDir.appendingPathComponent(name)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(size)", "\(size)", masterURL.path, "--out", out.path]
    try? p.run()
    p.waitUntilExit()
    print("  \(name): \(size)x\(size) -> \(out.path)")
}

// Cleanup master (keep the iconset clean).
try? FileManager.default.removeItem(at: masterURL)
print("\nDone.")
