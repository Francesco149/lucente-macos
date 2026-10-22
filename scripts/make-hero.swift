#!/usr/bin/env swift
// Composes docs/images/hero.png from the app icon and window captures in docs/images.
// Re-run after retaking screenshots:  swift scripts/make-hero.swift
//
// Captures are taken with `screencapture -x -l<window id>` (keeps the window shadow and alpha).
// Everything is drawn at 1:1 so the screenshots stay pixel-sharp.

import AppKit

let images = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(components: "docs", "images")

func load(_ name: String) -> NSImage {
    guard let image = NSImage(contentsOf: images.appending(component: name)) else {
        fatalError("missing docs/images/\(name)")
    }
    return image
}

func pixelSize(_ image: NSImage) -> CGSize {
    let rep = image.representations.first!
    return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
}

let canvas = CGSize(width: 1700, height: 940)
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let cg = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

// Night-sky base with coloured light spilling in, like the lights it drives.
let base = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.07, green: 0.05, blue: 0.16, alpha: 1),
    CGColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1),
] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(base, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])

func glow(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) {
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: r, green: g, blue: b, alpha: a), CGColor(red: r, green: g, blue: b, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                          endCenter: CGPoint(x: x, y: y), endRadius: radius, options: [])
}
glow(160, 820, 520, 1.0, 0.18, 0.75, 0.38)
glow(1600, 760, 560, 0.10, 0.85, 0.90, 0.26)
glow(900, -60, 620, 1.0, 0.45, 0.10, 0.30)
glow(560, 420, 380, 0.45, 0.10, 1.0, 0.18)

// Left column: icon, name, tagline, highlights.
let icon = load("icon.png")
icon.draw(in: CGRect(x: 60, y: 560, width: 220, height: 220))

func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, width: CGFloat = 420) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = size * 0.18
    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(white: 1, alpha: alpha),
        .paragraphStyle: style,
    ])
    let bounds = attributed.boundingRect(with: CGSize(width: width, height: 1000), options: [.usesLineFragmentOrigin])
    attributed.draw(with: CGRect(x: point.x, y: point.y - bounds.height, width: width, height: bounds.height),
                     options: [.usesLineFragmentOrigin])
}
text("Lucente", at: CGPoint(x: 80, y: 555), size: 92, weight: .bold, alpha: 1)
text("Cheap Bluetooth LED strips and bars, finally with a real Mac app.", at: CGPoint(x: 82, y: 430), size: 30, weight: .medium, alpha: 0.82, width: 400)
text("Menu bar · Groups · Scenes\nShortcuts & Siri · Live state\nSwiftUI + CoreBluetooth", at: CGPoint(x: 82, y: 270), size: 23, weight: .regular, alpha: 0.55, width: 400)

// Right: the main window at 1:1, with the menu bar panel overlapping its corner.
let window = load("window-color.png")
let windowSize = pixelSize(window)
window.draw(in: CGRect(x: 470, y: canvas.height - 60 - windowSize.height, width: windowSize.width, height: windowSize.height))
let panel = load("menubar.png")
let panelSize = pixelSize(panel)
panel.draw(in: CGRect(x: canvas.width - panelSize.width - 40, y: 30, width: panelSize.width, height: panelSize.height))

NSGraphicsContext.current = nil
try! bitmap.representation(using: .png, properties: [:])!.write(to: images.appending(component: "hero.png"))
print("wrote docs/images/hero.png (\(Int(canvas.width))×\(Int(canvas.height)))")
