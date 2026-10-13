#!/usr/bin/env swift
// Builds one icon size from the brand artwork in Resources/brand/app-icon.png.
//
// Apple's macOS icon grid leaves a margin around the rounded square: the body
// fills roughly 824 of a 1024 canvas. The supplied art is full-bleed, so it is
// scaled down and centred here — otherwise Meshvy would sit visibly larger
// than every other icon in the Dock.
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <source.png> <size> <out.png>\n".utf8))
    exit(2)
}
let sourcePath = arguments[1]
let size = Int(arguments[2]) ?? 1024
let output = arguments[3]

guard let source = NSImage(contentsOfFile: sourcePath),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("could not read \(sourcePath)\n".utf8))
    exit(1)
}

guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

context.interpolationQuality = .high

// 824/1024 of the canvas, centred, matching Apple's grid.
let inset = CGFloat(size) * (1.0 - 824.0 / 1024.0) / 2.0
let body = CGRect(
    x: inset, y: inset,
    width: CGFloat(size) - inset * 2,
    height: CGFloat(size) - inset * 2
)
context.draw(sourceCG, in: body)

guard let image = context.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: output))
