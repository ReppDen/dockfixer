#!/usr/bin/env swift

// Draws the before/after pictures of the README, one per thing DockFixer does:
// a window under the Dock and the same window just clear of it (with the Dock
// at the bottom for the top of the page, and on the left), a window following
// a Dock that got smaller, and a window filling the space of a Dock that went
// to another display. The last two can be drawn with the Dock on the left or
// at the bottom.
//
// Drawn rather than screenshotted so that each shows exactly the one thing
// DockFixer does, with no real desktop, app or name in it, and so that it can
// be redrawn when the icon's colours change.
//
// The background is transparent and each screen brings its own wallpaper, so
// the picture sits on GitHub's light and dark page alike. The only things drawn
// straight onto the page — the arrow and the two captions — are a mid grey that
// reads on both.
//
// Usage: swift Scripts/make-hero.swift <output.png> [scene]   (or: make readme-hero)
// Scenes: bottom, left, stick, fill, stick-bottom, fill-bottom.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Scene: String {
    case bottom, left, stick, fill
    case stickBottom = "stick-bottom"
    case fillBottom = "fill-bottom"
}

guard (2...3).contains(CommandLine.arguments.count),
      let scene = Scene(rawValue: CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "bottom")
else {
    FileHandle.standardError.write(Data("usage: make-hero.swift <output.png> [bottom|left|stick|fill|stick-bottom|fill-bottom]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

enum DockSide {
    case bottom, left
}

let side: DockSide = [.bottom, .stickBottom, .fillBottom].contains(scene) ? .bottom : .left

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

/// How far a window that DockFixer put next to the Dock ends up from it. The
/// usable area starts right where the Dock ends, so a corrected window sits
/// flush against it; one point is enough to keep the two shapes apart.
let flush: CGFloat = 1

/// The Dock as it is drawn: how many apps it holds and how big their tiles are.
struct DockLook {
    var tiles: Int
    var tile: CGFloat
}

/// A left Dock is shorter than a bottom one is wide, because the screen is
/// shorter than it is wide; its tiles are a little smaller to fit.
let usualDock = side == .bottom ? DockLook(tiles: 7, tile: 32) : DockLook(tiles: 7, tile: 30)

/// The Dock in the "stick" pictures, before and after it got smaller. It holds
/// fewer apps, so that the bigger one still fits the screen and the change is
/// big enough for an arrow to span it.
let bigDock = side == .bottom ? DockLook(tiles: 5, tile: 60) : DockLook(tiles: 5, tile: 52)
let smallDock = side == .bottom ? DockLook(tiles: 5, tile: 32) : DockLook(tiles: 5, tile: 24)

func tileGap(_ look: DockLook) -> CGFloat {
    side == .bottom ? (look.tile * 9 / 32).rounded() : 6
}

/// The Dock of a screen whose frame is `screen`: centred along its edge, as the
/// real one is, so it is recognised at a glance. On the left it is centred on
/// the part of the screen below the menu bar.
func dockFrame(in screen: CGRect, _ look: DockLook = usualDock) -> CGRect {
    let run = CGFloat(look.tiles) * look.tile + CGFloat(look.tiles - 1) * tileGap(look)
    switch side {
    case .bottom:
        let size = CGSize(width: run + 32, height: look.tile + 14)
        return CGRect(x: screen.midX - size.width / 2, y: screen.minY + 6,
                      width: size.width, height: size.height)
    case .left:
        let size = CGSize(width: look.tile + 16, height: run + 16)
        let middle = (screen.minY + screen.maxY - menuBarHeight) / 2
        return CGRect(x: screen.minX + 6, y: middle - size.height / 2,
                      width: size.width, height: size.height)
    }
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

func drawDock(in screen: CGRect, _ look: DockLook = usualDock) {
    let dock = dockFrame(in: screen, look)
    // Translucent, as the real one is, so the window under it in the "before"
    // picture shows through and reads as underneath rather than cut off. Dark
    // rather than white, so that over a white window it still reads as a
    // separate shape.
    fill(dock, radius: 13, rgb(28, 28, 44, 0.5))
    context.setStrokeColor(rgb(255, 255, 255, 0.55))
    context.setLineWidth(1)
    context.addPath(roundedRect(dock.insetBy(dx: 0.5, dy: 0.5), radius: 12.5))
    context.strokePath()

    let colors = [rgb(52, 120, 246), rgb(255, 159, 10), rgb(48, 209, 88), rgb(255, 69, 58),
                  rgb(255, 214, 10), rgb(100, 210, 255), rgb(84, 84, 92)]
    let tile = look.tile
    let gap = tileGap(look)
    let run = CGFloat(look.tiles) * tile + CGFloat(look.tiles - 1) * gap
    for (index, color) in colors.prefix(look.tiles).enumerated() {
        let step = CGFloat(index) * (tile + gap)
        // The first app is at the left end of a bottom Dock and at the top end
        // of a left one, as on a real Mac.
        let rect = side == .bottom
            ? CGRect(x: dock.midX - run / 2 + step, y: dock.midY - tile / 2, width: tile, height: tile)
            : CGRect(x: dock.midX - tile / 2, y: dock.midY + run / 2 - step - tile, width: tile, height: tile)
        context.saveGState()
        context.addPath(roundedRect(rect, radius: tile / 4))
        context.clip()
        let shine = CGGradient(colorsSpace: sRGB,
                               colors: [color.copy(alpha: 0.75)!, color] as CFArray,
                               locations: [0, 1])!
        context.drawLinearGradient(shine, start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        context.restoreGState()
    }
}

/// Where a Dock used to be: a dashed outline, so the "before" picture shows
/// what the window was resting against and why it stops where it does.
func drawFormerDock(_ dock: CGRect) {
    context.saveGState()
    fill(dock, radius: 13, rgb(255, 255, 255, 0.12))
    context.setStrokeColor(rgb(255, 255, 255, 0.85))
    context.setLineWidth(1.5)
    context.setLineDash(phase: 0, lengths: [6, 4])
    context.addPath(roundedRect(dock.insetBy(dx: 0.75, dy: 0.75), radius: 12.25))
    context.strokePath()
    context.restoreGState()
}

/// The white arrows drawn on a "before" screen, saying what is about to
/// happen. A dark shadow keeps them readable on every part of the wallpaper.
let hintColor = rgb(255, 255, 255)

func drawArrow(from start: CGPoint, to end: CGPoint, bothEnds: Bool = false, color: CGColor = hintColor) {
    let angle = atan2(end.y - start.y, end.x - start.x)
    // A short arrow gets smaller heads, or two of them meet in a blob.
    let head = min(7, hypot(end.x - start.x, end.y - start.y) / (bothEnds ? 3 : 2))
    func drawHead(at tip: CGPoint, pointing angle: CGFloat) {
        context.move(to: CGPoint(x: tip.x - head * cos(angle - .pi / 4), y: tip.y - head * sin(angle - .pi / 4)))
        context.addLine(to: tip)
        context.addLine(to: CGPoint(x: tip.x - head * cos(angle + .pi / 4), y: tip.y - head * sin(angle + .pi / 4)))
    }
    context.saveGState()
    if color == hintColor {
        context.setShadow(offset: .zero, blur: 4, color: rgb(0, 0, 0, 0.45))
    }
    context.setStrokeColor(color)
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.move(to: start)
    context.addLine(to: end)
    drawHead(at: end, pointing: angle)
    if bothEnds {
        drawHead(at: start, pointing: angle + .pi)
    }
    context.strokePath()
    context.endTransparencyLayer()
    context.restoreGState()
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

/// With the Dock at the bottom, the window's left and right edges and its top
/// are the same in both pictures; only the bottom differs, so the eye goes
/// straight to it. The window reaches the bottom of the screen, so DockFixer
/// has to shorten it as well as lift it.
func windowFrame(in screen: CGRect, bottom: CGFloat) -> CGRect {
    let top = screen.maxY - menuBarHeight - 20
    return CGRect(x: screen.minX + 75, y: bottom, width: 370, height: top - bottom)
}

/// With the Dock on the left, the window is narrower than the screen, so
/// DockFixer slides it out without changing its size: only its left edge
/// differs between the pictures. The Dock covers the sidebar, which is what
/// anyone would miss. The window stops short of the bottom of the screen to
/// leave room for the arrow under it.
func windowFrame(in screen: CGRect, left: CGFloat) -> CGRect {
    let top = screen.maxY - menuBarHeight - 20
    let bottom = screen.minY + 44
    return CGRect(x: left, y: bottom, width: 370, height: top - bottom)
}

/// A window filling all the room the Dock leaves it, up to the menu bar and out
/// to the other edges of the screen. It touches the Dock's edge and the edge
/// across from it, so when the Dock gets smaller or leaves, DockFixer stretches
/// it into the space rather than sliding it; `dockEdge` is where it starts on
/// the Dock's side. With the Dock on the left, `roomBelow` keeps the window off
/// the bottom of the screen, to leave room for an arrow under it; the other
/// axis is not the one being stretched, so this changes nothing about what
/// DockFixer does with it.
func maximizedWindow(in screen: CGRect, dockEdge: CGFloat, roomBelow: CGFloat = 0) -> CGRect {
    let top = screen.maxY - menuBarHeight
    switch side {
    case .bottom:
        return CGRect(x: screen.minX + 75, y: dockEdge, width: 370, height: top - dockEdge)
    case .left:
        let bottom = screen.minY + roomBelow
        return CGRect(x: dockEdge, y: bottom, width: screen.maxX - dockEdge, height: top - bottom)
    }
}

/// Room under the window in the "stick" picture with the Dock on the left, the
/// same as in the "move" one.
let stickRoomBelow: CGFloat = side == .left ? 44 : 0

/// The edge of the Dock that faces the windows.
func innerEdge(of dock: CGRect) -> CGFloat {
    side == .bottom ? dock.maxY : dock.maxX
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

drawWallpaper(before)
drawWallpaper(after)
switch scene {
case .bottom:
    // Before: the Dock, drawn over the window, covers its status bar. After:
    // the bottom edge sits on the Dock, the top has not moved.
    drawWindow(windowFrame(in: before, bottom: before.minY + 10))
    drawDock(in: before)
    drawWindow(windowFrame(in: after, bottom: dockFrame(in: after).maxY + flush))
    drawDock(in: after)

case .left:
    // Before: the Dock covers the window's sidebar, and an arrow under the
    // window shows where it is about to go. After: it sits against the Dock.
    let window = windowFrame(in: before, left: before.minX + 14)
    drawWindow(window)
    drawDock(in: before)
    let arrowY = (before.minY + window.minY) / 2
    drawArrow(from: CGPoint(x: window.minX + 60, y: arrowY), to: CGPoint(x: window.minX + 130, y: arrowY))
    drawWindow(windowFrame(in: after, left: dockFrame(in: after).maxX + flush))
    drawDock(in: after)

case .stick, .stickBottom:
    // Before: the Dock has just got smaller. Its former size is dashed, with an
    // arrow across the difference, and the window still ends where the bigger
    // Dock began; a second arrow at the window's edge says it will stretch.
    // After: the window reaches the smaller Dock, its far edges unmoved.
    let former = dockFrame(in: before, bigDock)
    let dock = dockFrame(in: before, smallDock)
    drawFormerDock(former)
    let window = maximizedWindow(in: before, dockEdge: innerEdge(of: former) + flush, roomBelow: stickRoomBelow)
    drawWindow(window)
    drawDock(in: before, smallDock)
    switch side {
    case .bottom:
        let x = dock.maxX + (former.maxX - dock.maxX) / 2
        drawArrow(from: CGPoint(x: x, y: dock.maxY + 2), to: CGPoint(x: x, y: former.maxY - 2), bothEnds: true)
        let y = window.minY + 70
        drawArrow(from: CGPoint(x: window.maxX + 22, y: y - 45), to: CGPoint(x: window.maxX + 22, y: y + 45),
                  bothEnds: true)
    case .left:
        let y = dock.minY - 22
        drawArrow(from: CGPoint(x: dock.maxX + 2, y: y), to: CGPoint(x: former.maxX - 2, y: y), bothEnds: true)
        let arrowY = (before.minY + window.minY) / 2
        drawArrow(from: CGPoint(x: window.minX + 16, y: arrowY), to: CGPoint(x: window.minX + 96, y: arrowY),
                  bothEnds: true)
    }
    drawWindow(maximizedWindow(in: after, dockEdge: innerEdge(of: dockFrame(in: after, smallDock)) + flush,
                               roomBelow: stickRoomBelow))
    drawDock(in: after, smallDock)

case .fill, .fillBottom:
    // Before: the Dock has gone to another display, and the window still ends
    // where it began; an arrow across the empty space shows where it will
    // stretch. After: the window reaches the edge of the screen.
    let former = dockFrame(in: before)
    drawFormerDock(former)
    let window = maximizedWindow(in: before, dockEdge: innerEdge(of: former) + flush)
    drawWindow(window)
    switch side {
    case .bottom:
        drawArrow(from: CGPoint(x: window.midX, y: window.minY - 6), to: CGPoint(x: window.midX, y: before.minY + 8))
    case .left:
        drawArrow(from: CGPoint(x: window.minX - 6, y: window.midY), to: CGPoint(x: before.minX + 8, y: window.midY))
    }
    let screenEdge = side == .bottom ? after.minY : after.minX
    drawWindow(maximizedWindow(in: after, dockEdge: screenEdge))
}
drawCaption("Before", under: before)
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
