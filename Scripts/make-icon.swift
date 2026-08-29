#!/usr/bin/env swift

// 生成 App 图标。
// 用法：swift Scripts/make-icon.swift
// 会把 PNG 写进 App/Assets.xcassets/AppIcon.appiconset/ 并重写 Contents.json。

import AppKit
import Foundation

let sizes: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// macOS 图标不是铺满整张画布的，四周留白约 10%，圆角约为可视区域的 22.5%。
func drawIcon(pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let side = CGFloat(pixels)
    let inset = side * 0.094
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = rect.width * 0.225

    let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.32, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.18, green: 0.34, blue: 0.92, alpha: 1),
    ])
    gradient?.draw(in: body, angle: -90)

    // 顶部高光，让图标不至于太平。
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    let highlight = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.28),
        NSColor(white: 1, alpha: 0.0),
    ])
    highlight?.draw(in: NSRect(x: rect.minX, y: rect.midY,
                               width: rect.width, height: rect.height / 2),
                    angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // 中间的闪电，用 SF Symbol 直接画，省得手搓路径。
    let glyphSide = rect.width * 0.52
    let configuration = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
            NSColor.white.set()
            bounds.fill()
            symbol.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        let target = NSRect(
            x: rect.midX - tinted.size.width / 2,
            y: rect.midY - tinted.size.height / 2,
            width: tinted.size.width,
            height: tinted.size.height
        )
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 0.96)
    }

    return rep
}

var entries: [[String: String]] = []

for (size, scale) in sizes {
    let pixels = size * scale
    guard let rep = drawIcon(pixels: pixels),
          let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("无法生成 \(pixels)px 图标\n".data(using: .utf8)!)
        exit(1)
    }
    let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try data.write(to: outputDirectory.appendingPathComponent(filename))
    entries.append([
        "idiom": "mac",
        "size": "\(size)x\(size)",
        "scale": "\(scale)x",
        "filename": filename,
    ])
    print("生成 \(filename)  (\(pixels)×\(pixels))")
}

let contents: [String: Any] = [
    "images": entries,
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(withJSONObject: contents,
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("已更新 Contents.json")
