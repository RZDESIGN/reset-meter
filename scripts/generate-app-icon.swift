#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-app-icon.swift <output.icns>\n", stderr)
    exit(64)
}

let fileManager = FileManager.default
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let iconsetURL = fileManager.temporaryDirectory
    .appending(path: "ResetMeter-\(UUID().uuidString).iconset")

try fileManager.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconsetURL) }

func renderIcon(pixelSize: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)
    guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(
        x: CGFloat(pixelSize) / 1_024,
        y: CGFloat(pixelSize) / 1_024
    )

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1_024, height: 1_024).fill()

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
        xRadius: 210,
        yRadius: 210
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.16, alpha: 1),
        NSColor(calibratedRed: 0.025, green: 0.03, blue: 0.055, alpha: 1),
    ])?.draw(in: tile, angle: -72)

    NSColor.white.withAlphaComponent(0.12).setStroke()
    tile.lineWidth = 8
    tile.stroke()

    let rows: [(CGFloat, CGFloat, NSColor)] = [
        (678, 0.76, NSColor(calibratedRed: 0.22, green: 0.49, blue: 1.00, alpha: 1)),
        (476, 0.48, NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)),
        (274, 0.86, NSColor(calibratedRed: 0.48, green: 0.42, blue: 0.96, alpha: 1)),
    ]

    for (y, progress, color) in rows {
        let dot = NSBezierPath(ovalIn: NSRect(x: 176, y: y, width: 72, height: 72))
        color.setFill()
        dot.fill()

        let trackRect = NSRect(x: 282, y: y + 5, width: 564, height: 62)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 31, yRadius: 31)
        NSColor.white.withAlphaComponent(0.16).setFill()
        track.fill()

        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: trackRect.width * progress,
            height: trackRect.height
        )
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 31, yRadius: 31)
        color.setFill()
        fill.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1_024),
]

for (name, size) in outputs {
    try renderIcon(pixelSize: size).write(to: iconsetURL.appending(path: name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
