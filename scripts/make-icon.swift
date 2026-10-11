#!/usr/bin/env swift
// Draws Orkestr's app icon and writes a PNG at the requested size.
//
// Run through scripts/make-icon.sh, which renders every size macOS wants and
// packs them with iconutil. Kept as source rather than a checked-in binary so
// the mark can be adjusted.
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let size = arguments.count > 1 ? Int(arguments[1]) ?? 1024 : 1024
let output = arguments.count > 2 ? arguments[2] : "icon.png"

let scale = CGFloat(size) / 1024.0
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

context.scaleBy(x: scale, y: scale)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Rounded-square background with the canvas gradient.
let squircle = CGPath(
    roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
    cornerWidth: 200, cornerHeight: 200, transform: nil
)
context.saveGState()
context.addPath(squircle)
context.clip()
if let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0x1C1F28), color(0x0B0C10)] as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: 960), end: CGPoint(x: 0, y: 64), options: []
    )
}
context.restoreGState()

// Hairline edge, as on the cards.
context.addPath(squircle)
context.setStrokeColor(color(0xFFFFFF, 0.10))
context.setLineWidth(4)
context.strokePath()

// The mark: an arc sweeping over three nodes — a workspace and its repos.
let centre = CGPoint(x: 512, y: 440)
let radius: CGFloat = 250

context.setLineCap(.round)
context.setLineWidth(46)
context.setStrokeColor(color(0xF2A33C))
context.addArc(
    center: centre, radius: radius,
    startAngle: .pi * 0.08, endAngle: .pi * 0.92, clockwise: false
)
context.strokePath()

// Three child nodes under the arc — a workspace and its repositories.
let nodeY: CGFloat = 330
let positions: [(CGFloat, UInt32)] = [
    (512 - 196, 0x7C8CF8),
    (512, 0xF2A33C),
    (512 + 196, 0x45C0A8)
]

// Spokes fanning down to each node. Drawn under the arc and kept thin: at
// full weight they pile up into a muddy blob where they meet.
context.setLineWidth(11)
context.setStrokeColor(color(0xF2A33C, 0.38))
let fanOrigin = CGPoint(x: 512, y: centre.y + radius - 74)
for (x, _) in positions {
    context.move(to: fanOrigin)
    context.addLine(to: CGPoint(x: x, y: nodeY + 62))
}
context.strokePath()

for (x, tint) in positions {
    context.setFillColor(color(tint))
    context.fillEllipse(in: CGRect(x: x - 52, y: nodeY - 52, width: 104, height: 104))
}

guard let image = context.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: output))
