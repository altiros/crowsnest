#!/usr/bin/env swift
// Renders the Crowsnest app icon (lookout basket on a mast, scanning arcs).
// Usage: swift scripts/make-icon.swift <output-dir>   (make icon → Resources/)
// Produces <output-dir>/Assets.xcassets (AppIcon for iOS + macOS) and <output-dir>/AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the artwork into a 1024×1024 unit square (origin bottom-left).
func drawArtwork(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Night-sky background.
    let sky = CGGradient(colorsSpace: space, colors: [rgb(0x0A1A33), rgb(0x123B6E), rgb(0x1B5A9A)] as CFArray,
                         locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

    // Glow behind the lookout.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0x5AC8FA, 0.35), rgb(0x5AC8FA, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 400, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 400, y: 640), endRadius: 520, options: [])

    // Sea.
    func wave(y: CGFloat, amp: CGFloat, color: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: y))
        var x: CGFloat = 0
        while x < 1024 {
            p.addQuadCurve(to: CGPoint(x: x + 128, y: y), control: CGPoint(x: x + 64, y: y + amp))
            x += 128
        }
        p.addLine(to: CGPoint(x: 1024, y: 0))
        p.addLine(to: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    let mastX: CGFloat = 420
    let white = rgb(0xF2F6FC)

    // Rigging (mast top to bow and stern).
    ctx.setStrokeColor(rgb(0xF2F6FC, 0.4))
    ctx.setLineWidth(10)
    ctx.setLineCap(.round)
    for end in [CGPoint(x: 175, y: 300), CGPoint(x: 700, y: 300)] {
        ctx.move(to: CGPoint(x: mastX, y: 590))
        ctx.addLine(to: end)
    }
    ctx.strokePath()

    // Mast.
    ctx.setFillColor(white)
    ctx.fill(CGRect(x: mastX - 20, y: 260, width: 40, height: 620))
    ctx.addEllipse(in: CGRect(x: mastX - 26, y: 864, width: 52, height: 52))
    ctx.fillPath()

    // Hull.
    let hull = CGMutablePath()
    hull.move(to: CGPoint(x: 140, y: 310))
    hull.addLine(to: CGPoint(x: 760, y: 310))
    hull.addQuadCurve(to: CGPoint(x: 640, y: 170), control: CGPoint(x: 730, y: 190))
    hull.addLine(to: CGPoint(x: 230, y: 170))
    hull.addQuadCurve(to: CGPoint(x: 140, y: 310), control: CGPoint(x: 170, y: 190))
    hull.closeSubpath()
    ctx.addPath(hull)
    ctx.setFillColor(white)
    ctx.fillPath()
    ctx.setFillColor(rgb(0xFF9F2E))
    ctx.fill(CGRect(x: 150, y: 270, width: 600, height: 18))

    // Sea in front of the hull.
    wave(y: 200, amp: 34, color: rgb(0x0E3A66))
    wave(y: 140, amp: -30, color: rgb(0x0A2A4D))

    // Pennant (blowing left).
    let flag = CGMutablePath()
    flag.move(to: CGPoint(x: mastX - 20, y: 860))
    flag.addLine(to: CGPoint(x: mastX - 210, y: 815))
    flag.addLine(to: CGPoint(x: mastX - 20, y: 770))
    flag.closeSubpath()
    ctx.addPath(flag)
    ctx.setFillColor(rgb(0xFF9F2E))
    ctx.fillPath()

    // Scanning arcs from the lookout to the right.
    let center = CGPoint(x: mastX + 40, y: 665)
    for (i, radius) in [CGFloat(180), 280, 380].enumerated() {
        ctx.setStrokeColor(rgb(0x6FD3FF, [1.0, 0.72, 0.45][i]))
        ctx.setLineWidth(36)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: -.pi * 0.16, endAngle: .pi * 0.16, clockwise: false)
        ctx.strokePath()
    }

    // Crow's nest: barrel with bulging sides.
    let barrel = CGMutablePath()
    barrel.move(to: CGPoint(x: mastX - 110, y: 730))
    barrel.addLine(to: CGPoint(x: mastX + 110, y: 730))
    barrel.addQuadCurve(to: CGPoint(x: mastX + 85, y: 590), control: CGPoint(x: mastX + 135, y: 650))
    barrel.addLine(to: CGPoint(x: mastX - 85, y: 590))
    barrel.addQuadCurve(to: CGPoint(x: mastX - 110, y: 730), control: CGPoint(x: mastX - 135, y: 650))
    barrel.closeSubpath()
    ctx.addPath(barrel)
    ctx.setFillColor(white)
    ctx.fillPath()
    let rim = CGPath(roundedRect: CGRect(x: mastX - 135, y: 718, width: 270, height: 36),
                     cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.addPath(rim)
    ctx.fillPath()
    // Hoops.
    ctx.setFillColor(rgb(0x123B6E))
    ctx.fill(CGRect(x: mastX - 118, y: 676, width: 236, height: 12))
    ctx.fill(CGRect(x: mastX - 108, y: 624, width: 216, height: 12))
}

func render(size: Int, macStyle: Bool) -> Data {
    // iOS icons must not have an alpha channel; macOS icons need transparency around the shape.
    let info = macStyle ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    if macStyle {
        // macOS grid: 824×824 rounded rect centred in 1024, with a soft drop shadow.
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x0A1A33))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.translateBy(x: 100, y: 100)
        ctx.scaleBy(x: 824.0 / 1024, y: 824.0 / 1024)
    }
    drawArtwork(ctx)
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// Asset catalog (shared by the iPad and macOS Xcode targets).
let appIconSet = outDir.appending(path: "Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: outDir.appending(path: "Assets.xcassets/Contents.json"))
var images: [String] = []
try render(size: 1024, macStyle: false).write(to: appIconSet.appending(path: "ios-1024.png"))
images.append(#"{"filename":"ios-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}"#)

// macOS sizes, also collected into an .iconset for iconutil (SwiftPM bundle script).
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for point in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let png = render(size: point * factor, macStyle: true)
        let suffix = factor == 2 ? "@2x" : ""
        let name = "mac-\(point)\(suffix).png"
        try png.write(to: appIconSet.appending(path: name))
        try png.write(to: iconset.appending(path: "icon_\(point)x\(point)\(suffix).png"))
        images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(factor)x","size":"\#(point)x\#(point)"}"#)
    }
}
try Data(("{\"images\":[" + images.joined(separator: ",") + "],\"info\":{\"author\":\"xcode\",\"version\":1}}").utf8)
    .write(to: appIconSet.appending(path: "Contents.json"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appending(path: "AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Icons in \(outDir.path)")
