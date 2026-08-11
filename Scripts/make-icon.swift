#!/usr/bin/env swift

// Draws the app icon as a 1024pt PNG. The Makefile scales it into an iconset and
// runs iconutil, so no binary artwork is checked into the repository.
//
// Usage: swift Scripts/make-icon.swift <output.png>

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

guard let context = CGContext(data: nil,
                              width: side,
                              height: side,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("could not create a drawing context\n".utf8))
    exit(1)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Background: a squircle with a deep blue gradient.
let plate = CGRect(x: 68, y: 68, width: CGFloat(side) - 136, height: CGFloat(side) - 136)
context.saveGState()
context.addPath(roundedRect(plate, radius: 208))
context.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [rgb(58, 82, 138), rgb(17, 28, 54)] as CFArray,
                          locations: [0, 1])!
context.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY),
                           options: [])
context.restoreGState()

// Where the window ends up: clear of the Dock, narrowed by the same distance.
let window = CGRect(x: 336, y: 300, width: 520, height: 420)

// Where the window used to be: a dashed outline running under the Dock. Only the
// part that is not hidden behind the window itself is drawn, so the dashes do
// not read as a line across the window.
let ghost = CGRect(x: 168, y: 300, width: 520, height: 420)
context.saveGState()
let outsideWindow = CGMutablePath()
outsideWindow.addRect(CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
outsideWindow.addPath(roundedRect(window.insetBy(dx: -2, dy: -2), radius: 46))
context.addPath(outsideWindow)
context.clip(using: .evenOdd)
context.setStrokeColor(rgb(255, 255, 255, 0.34))
context.setLineWidth(10)
context.setLineDash(phase: 0, lengths: [26, 20])
context.addPath(roundedRect(ghost, radius: 44))
context.strokePath()
context.restoreGState()

// The Dock: a translucent strip on the left with three tiles.
let dock = CGRect(x: 148, y: 268, width: 116, height: 488)
context.setFillColor(rgb(255, 255, 255, 0.20))
context.addPath(roundedRect(dock, radius: 58))
context.fillPath()

for index in 0..<3 {
    let tile = CGRect(x: dock.minX + 22, y: dock.minY + 60 + CGFloat(index) * 128, width: 72, height: 72)
    context.setFillColor(rgb(255, 255, 255, 0.55))
    context.addPath(roundedRect(tile, radius: 22))
    context.fillPath()
}

context.setFillColor(rgb(248, 250, 252))
context.addPath(roundedRect(window, radius: 44))
context.fillPath()

// Title bar with the usual three dots.
context.saveGState()
context.addPath(roundedRect(window, radius: 44))
context.clip()
context.setFillColor(rgb(226, 232, 240))
context.fill(CGRect(x: window.minX, y: window.maxY - 74, width: window.width, height: 74))
let dots = [rgb(237, 106, 94), rgb(245, 191, 79), rgb(97, 196, 84)]
for (index, color) in dots.enumerated() {
    context.setFillColor(color)
    context.fillEllipse(in: CGRect(x: window.minX + 34 + CGFloat(index) * 46,
                                   y: window.maxY - 51,
                                   width: 28,
                                   height: 28))
}
context.restoreGState()

// The nudge itself.
let arrowY = window.minY - 78
context.setStrokeColor(rgb(126, 200, 255))
context.setLineWidth(20)
context.setLineCap(.round)
context.move(to: CGPoint(x: dock.maxX + 24, y: arrowY))
context.addLine(to: CGPoint(x: window.minX + 36, y: arrowY))
context.strokePath()

context.setFillColor(rgb(126, 200, 255))
context.move(to: CGPoint(x: window.minX + 92, y: arrowY))
context.addLine(to: CGPoint(x: window.minX + 30, y: arrowY + 36))
context.addLine(to: CGPoint(x: window.minX + 30, y: arrowY - 36))
context.closePath()
context.fillPath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("could not encode the icon\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(output.path)\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
