#!/usr/bin/env swift
// SPDX-License-Identifier: Apache-2.0
//
// Renders the app's icon (docs/plans/app.md, APP-8): the mark of docs/design/brand/
// leyline-mark.svg in `accent` on `ground`, inside the macOS icon shape, at every size iconutil
// takes, then AppIcon.icns. CoreGraphics and ImageIO only, so it runs on any Mac with the Swift
// toolchain and needs no Xcode asset catalog. scripts/bundle-app.sh runs it.
//
//   swift scripts/render-icon.swift <dir>   writes <dir>/AppIcon.iconset and <dir>/AppIcon.icns
//
// The colours are Theme.swift's `accent` (#E8814A) and `ground` (#0B0D0F). The shape follows
// Apple's macOS icon grid at 1024 px: an 824 px tile (a 100 px transparent margin on each side,
// 9.8 % of the canvas) with corners of 22.37 % of the tile, 184 px. Apple's tile is a continuous
// curve and this one uses circular corners, which differ by about a pixel at 1024. The mark
// takes half the tile, 412 px at 1024, with the SVG's proportions: the ring's line 1.2 and the
// dot's radius 1.5 in a 13-unit box, the ring's outer edge on the box.

import CoreGraphics
import Foundation
import ImageIO

let accent: (CGFloat, CGFloat, CGFloat) = (0xE8 / 255.0, 0x81 / 255.0, 0x4A / 255.0)
let ground: (CGFloat, CGFloat, CGFloat) = (0x0B / 255.0, 0x0D / 255.0, 0x0F / 255.0)

let tileFraction: CGFloat = 824.0 / 1024.0
let cornerFraction: CGFloat = 0.2237
let markFraction: CGFloat = 0.5
let markBox: CGFloat = 13
let markLine: CGFloat = 1.2
let markDot: CGFloat = 1.5

func render(pixels: Int) -> CGImage {
    let side = CGFloat(pixels)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("render-icon: no bitmap context at \(pixels) px") }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let tile = side * tileFraction
    let inset = (side - tile) / 2
    let tileRect = CGRect(x: inset, y: inset, width: tile, height: tile)
    let corner = tile * cornerFraction
    ctx.addPath(
        CGPath(roundedRect: tileRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setFillColor(red: ground.0, green: ground.1, blue: ground.2, alpha: 1)
    ctx.fillPath()

    let box = tile * markFraction
    let unit = box / markBox
    let line = markLine * unit
    let ringRadius = (box - line) / 2
    let centre = CGPoint(x: side / 2, y: side / 2)
    ctx.setStrokeColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 1)
    ctx.setFillColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 1)
    ctx.setLineWidth(line)
    ctx.strokeEllipse(
        in: CGRect(
            x: centre.x - ringRadius, y: centre.y - ringRadius, width: ringRadius * 2,
            height: ringRadius * 2))
    let dot = markDot * unit
    ctx.fillEllipse(
        in: CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2))

    guard let image = ctx.makeImage() else { fatalError("render-icon: no image at \(pixels) px") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("render-icon: cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("render-icon: cannot write \(url.path)")
    }
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/render-icon.swift <dir>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[1], isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil's names: each point size at 1x and 2x, 16 to 512 pt, so 16 to 1024 px.
var images: [Int: CGImage] = [:]
for px in [16, 32, 64, 128, 256, 512, 1024] { images[px] = render(pixels: px) }
for pt in [16, 32, 128, 256, 512] {
    writePNG(images[pt]!, to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    writePNG(images[pt * 2]!, to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}

let icns = out.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("render-icon: iconutil failed\n".utf8))
    exit(1)
}
print(icns.path)
