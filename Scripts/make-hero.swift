#!/usr/bin/env swift

// Draws the picture at the top of the README: a window sliding under the Dock,
// and the same window sitting just above it. Drawn rather than screenshotted so
// that it shows exactly the one thing DockFixer does, with no real desktop, app
// or name in it, and so that it can be redrawn when the icon's colours change.
//
// The background is transparent and each screen brings its own wallpaper, so
// the picture sits on GitHub's light and dark page alike. The only things drawn
// straight onto the page — the arrow and the two captions — are a mid grey that
// reads on both.
//
// Usage: swift Scripts/make-hero.swift <output.png>   (or: make readme-hero)

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-hero.swift <output.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

// Laid out in points and rendered at 2x, so the README can show it at its point
// size and a Retina display still gets every pixel.
let width: CGFloat = 1200
let height: CGFloat = 450
let scale: CGFloat = 2

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil,
                              width: Int(width * scale),
                              height: Int(height * scale),
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("could not create a drawing context\n".utf8))
    exit(1)
}
context.scaleBy(x: scale, y: scale)
context.interpolationQuality = .high

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ rect: CGRect, radius: CGFloat, _ color: CGColor) {
    context.setFillColor(color)
    context.addPath(roundedRect(rect, radius: radius))
    context.fillPath()
}

// Everything below is in Core Graphics' own coordinates: origin at the bottom
// left, y growing upwards. "Top" of a screen is its maxY.

let screenSize = CGSize(width: 520, height: 325)
let menuBarHeight: CGFloat = 15

/// The Dock of a screen whose frame is `screen`: centred at the bottom, the
/// default place, so it is recognised at a glance.
func dockFrame(in screen: CGRect) -> CGRect {
    let size = CGSize(width: 310, height: 46)
    return CGRect(x: screen.midX - size.width / 2, y: screen.minY + 6,
                  width: size.width, height: size.height)
}

func drawWallpaper(_ screen: CGRect) {
    context.saveGState()
    // A soft shadow lifts the screen off a light page; on a dark page it
    // simply disappears, which is fine.
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0, 0, 0, 0.22))
    fill(screen, radius: 14, rgb(60, 90, 170))
    context.restoreGState()

    context.saveGState()
    context.addPath(roundedRect(screen, radius: 14))
    context.clip()
    let gradient = CGGradient(colorsSpace: sRGB,
                              colors: [rgb(63, 110, 214), rgb(122, 98, 214), rgb(226, 140, 132)] as CFArray,
                              locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: screen.minX, y: screen.maxY),
                               end: CGPoint(x: screen.maxX, y: screen.minY),
                               options: [])

    // Menu bar: a pale strip with an apple-sized dot and a few "menus".
    let bar = CGRect(x: screen.minX, y: screen.maxY - menuBarHeight, width: screen.width, height: menuBarHeight)
    context.setFillColor(rgb(255, 255, 255, 0.28))
    context.fill(bar)
    context.setFillColor(rgb(255, 255, 255, 0.9))
    context.fillEllipse(in: CGRect(x: bar.minX + 12, y: bar.midY - 3.5, width: 7, height: 7))
    var x = bar.minX + 28
    for menu: CGFloat in [30, 22, 18, 26] {
        fill(CGRect(x: x, y: bar.midY - 2, width: menu, height: 4), radius: 2, rgb(255, 255, 255, 0.8))
        x += menu + 10
    }
    for (offset, item) in [(CGFloat(14), CGFloat(10)), (34, 10), (54, 34)] {
        fill(CGRect(x: bar.maxX - offset - item, y: bar.midY - 2, width: item, height: 4), radius: 2,
             rgb(255, 255, 255, 0.8))
    }
    context.restoreGState()
}

func drawDock(in screen: CGRect) {
    let dock = dockFrame(in: screen)
    // Translucent, as the real one is, so the window under it in the "before"
    // picture shows through and reads as underneath rather than cut off.
    fill(dock, radius: 13, rgb(255, 255, 255, 0.42))
    context.setStrokeColor(rgb(255, 255, 255, 0.6))
    context.setLineWidth(1)
    context.addPath(roundedRect(dock.insetBy(dx: 0.5, dy: 0.5), radius: 12.5))
    context.strokePath()

    let tiles = [rgb(52, 120, 246), rgb(255, 159, 10), rgb(48, 209, 88), rgb(255, 69, 58),
                 rgb(94, 92, 230), rgb(100, 210, 255), rgb(142, 142, 147)]
    let tile: CGFloat = 32
    let gap: CGFloat = 9
    let run = CGFloat(tiles.count) * tile + CGFloat(tiles.count - 1) * gap
    for (index, color) in tiles.enumerated() {
        let rect = CGRect(x: dock.midX - run / 2 + CGFloat(index) * (tile + gap),
                          y: dock.midY - tile / 2, width: tile, height: tile)
        context.saveGState()
        context.addPath(roundedRect(rect, radius: 8))
        context.clip()
        let shine = CGGradient(colorsSpace: sRGB,
                               colors: [color.copy(alpha: 0.75)!, color] as CFArray,
                               locations: [0, 1])!
        context.drawLinearGradient(shine, start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        context.restoreGState()
    }
}

/// A plain document window: title bar with the three lights, a sidebar, some
/// lines of text, and a status bar along the bottom with a blue button — the
/// part that ends up under the Dock, and the reason anyone minds.
func drawWindow(_ window: CGRect) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -5), blur: 16, color: rgb(0, 0, 0, 0.35))
    fill(window, radius: 10, rgb(255, 255, 255))
    context.restoreGState()

    context.saveGState()
    context.addPath(roundedRect(window, radius: 10))
    context.clip()

    let titleBar = CGRect(x: window.minX, y: window.maxY - 26, width: window.width, height: 26)
    context.setFillColor(rgb(236, 236, 238))
    context.fill(titleBar)
    for (index, color) in [rgb(255, 95, 87), rgb(254, 188, 46), rgb(40, 200, 64)].enumerated() {
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: window.minX + 11 + CGFloat(index) * 18, y: titleBar.midY - 5.5,
                                       width: 11, height: 11))
    }
    fill(CGRect(x: window.midX - 40, y: titleBar.midY - 2.5, width: 80, height: 5), radius: 2.5,
         rgb(160, 160, 166))

    let statusBar = CGRect(x: window.minX, y: window.minY, width: window.width, height: 28)
    let sidebar = CGRect(x: window.minX, y: statusBar.maxY, width: 92, height: titleBar.minY - statusBar.maxY)
    context.setFillColor(rgb(245, 245, 247))
    context.fill(sidebar)
    for row in 0..<5 {
        let y = sidebar.maxY - 20 - CGFloat(row) * 17
        fill(CGRect(x: sidebar.minX + 12, y: y, width: row == 0 ? 52 : 40 + CGFloat(row % 3) * 9, height: 5),
             radius: 2.5, row == 0 ? rgb(52, 120, 246, 0.85) : rgb(190, 190, 196))
    }

    // Text lines, running out of room at whatever height the window has.
    let lineWidths: [CGFloat] = [0.9, 0.82, 0.95, 0.6, 0.88, 0.92, 0.7, 0.85, 0.5, 0.9, 0.8, 0.66]
    let textLeft = sidebar.maxX + 18
    let textWidth = window.maxX - textLeft - 20
    fill(CGRect(x: textLeft, y: sidebar.maxY - 26, width: textWidth * 0.45, height: 9), radius: 3,
         rgb(70, 70, 76))
    var y = sidebar.maxY - 48
    for fraction in lineWidths where y > statusBar.maxY + 12 {
        fill(CGRect(x: textLeft, y: y, width: textWidth * fraction, height: 5), radius: 2.5, rgb(206, 206, 212))
        y -= 15
    }

    context.setFillColor(rgb(246, 246, 248))
    context.fill(statusBar)
    context.setFillColor(rgb(222, 222, 226))
    context.fill(CGRect(x: statusBar.minX, y: statusBar.maxY - 0.5, width: statusBar.width, height: 0.5))
    fill(CGRect(x: statusBar.minX + 12, y: statusBar.midY - 2.5, width: 70, height: 5), radius: 2.5,
         rgb(190, 190, 196))
    fill(CGRect(x: statusBar.maxX - 74, y: statusBar.midY - 8, width: 62, height: 16), radius: 5,
         rgb(52, 120, 246))
    fill(CGRect(x: statusBar.maxX - 61, y: statusBar.midY - 2, width: 36, height: 4), radius: 2,
         rgb(255, 255, 255, 0.9))

    context.restoreGState()
}

/// The window's left and right edges and its top are the same in both
/// pictures; only the bottom differs, so the eye goes straight to it.
func windowFrame(in screen: CGRect, bottom: CGFloat) -> CGRect {
    let top = screen.maxY - menuBarHeight - 20
    return CGRect(x: screen.minX + 75, y: bottom, width: 370, height: top - bottom)
}

let caption = NSColor(srgbRed: 128 / 255, green: 136 / 255, blue: 148 / 255, alpha: 1)

func drawCaption(_ text: String, under screen: CGRect) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: caption,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    string.draw(at: CGPoint(x: screen.midX - size.width / 2, y: screen.minY - 26 - size.height / 2 - 4))
}

NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

let before = CGRect(origin: CGPoint(x: 40, y: 75), size: screenSize)
let after = CGRect(origin: CGPoint(x: 640, y: 75), size: screenSize)

// Before: the window reaches almost to the bottom of the screen, and the Dock,
// drawn over it, covers its status bar.
drawWallpaper(before)
drawWindow(windowFrame(in: before, bottom: before.minY + 10))
drawDock(in: before)
drawCaption("Before", under: before)

// After: the bottom edge sits just above the Dock, the top has not moved.
drawWallpaper(after)
drawWindow(windowFrame(in: after, bottom: dockFrame(in: after).maxY + 5))
drawDock(in: after)
drawCaption("After", under: after)

// The arrow between them.
let arrowY = before.midY
let arrowColor = rgb(128, 136, 148)
context.setStrokeColor(arrowColor)
context.setLineWidth(5)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: before.maxX + 26, y: arrowY))
context.addLine(to: CGPoint(x: after.minX - 28, y: arrowY))
context.strokePath()
context.move(to: CGPoint(x: after.minX - 40, y: arrowY + 13))
context.addLine(to: CGPoint(x: after.minX - 26, y: arrowY))
context.addLine(to: CGPoint(x: after.minX - 40, y: arrowY - 13))
context.strokePath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("could not encode the picture\n".utf8))
    exit(1)
}
// 144 dpi tells viewers that respect it to show the picture at its point size.
CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 144,
                                                kCGImagePropertyDPIHeight: 144] as CFDictionary)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(output.path)\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
