// Draws the Anchor Watch app icon: a white anchor with a blue eye in the middle of the shaft.
// Regenerate with:  swift tools/make_icon.swift
// Writes AnchorWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024x1024, no transparency).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }

// Work in a top-left origin, like the sketch.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let white = color(0xF5F9FC)
let navy = color(0x071E3A)
let iris = color(0x1E8CFF)
let irisRim = color(0x0A4FA6)

// MARK: Background: deep sea blue, lighter toward the top.
let gradient = CGGradient(colorsSpace: space, colors: [color(0x1B6FB5), color(0x0C3A66), color(0x061B33)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 1024), options: [])

// Soft glow behind the anchor.
let glow = CGGradient(colorsSpace: space, colors: [color(0x58B2FF, 0.28), color(0x58B2FF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0, endCenter: CGPoint(x: 512, y: 500), endRadius: 520, options: [])

// MARK: Anchor
// Drawn as one group so the drop shadow is applied once, with no seams where strokes overlap.
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: color(0x000000, 0.38))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(white)
ctx.setFillColor(white)

func stroke(_ width: CGFloat, _ build: (CGMutablePath) -> Void) {
    let path = CGMutablePath()
    build(path)
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

func fillTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
    ctx.beginPath()
    ctx.move(to: a); ctx.addLine(to: b); ctx.addLine(to: c); ctx.closePath()
    ctx.fillPath()
}

// Ring at the top.
ctx.addEllipse(in: CGRect(x: 512 - 52, y: 160 - 52, width: 104, height: 104))
ctx.setLineWidth(28)
ctx.strokePath()

// Shaft.
stroke(44) { $0.move(to: CGPoint(x: 512, y: 212)); $0.addLine(to: CGPoint(x: 512, y: 850)) }

// Stock, curved like an eyebrow above the eye.
stroke(30) { p in
    p.move(to: CGPoint(x: 316, y: 312))
    p.addQuadCurve(to: CGPoint(x: 708, y: 312), control: CGPoint(x: 512, y: 278))
}

// Crown: the two curved arms.
stroke(44) { p in
    p.move(to: CGPoint(x: 176, y: 612))
    p.addCurve(to: CGPoint(x: 512, y: 852), control1: CGPoint(x: 190, y: 770), control2: CGPoint(x: 372, y: 852))
    p.addCurve(to: CGPoint(x: 848, y: 612), control1: CGPoint(x: 652, y: 852), control2: CGPoint(x: 834, y: 770))
}

// Fluke barbs at the ends of the arms.
fillTriangle(CGPoint(x: 150, y: 512), CGPoint(x: 96, y: 628), CGPoint(x: 252, y: 612))
fillTriangle(CGPoint(x: 874, y: 512), CGPoint(x: 928, y: 628), CGPoint(x: 772, y: 612))

// Pointed tip at the bottom of the crown.
fillTriangle(CGPoint(x: 474, y: 838), CGPoint(x: 550, y: 838), CGPoint(x: 512, y: 950))

ctx.endTransparencyLayer()

// MARK: Eye, drawn over the shaft.
ctx.setShadow(offset: .zero, blur: 0, color: nil)
// Scale the whole eye about its centre; 1.0 is the original size.
let eyeScale: CGFloat = 1.13
ctx.saveGState()
ctx.translateBy(x: 512, y: 520)
ctx.scaleBy(x: eyeScale, y: eyeScale)
ctx.translateBy(x: -512, y: -520)

let eye = CGMutablePath()
eye.move(to: CGPoint(x: 300, y: 520))
eye.addCurve(to: CGPoint(x: 724, y: 520), control1: CGPoint(x: 390, y: 384), control2: CGPoint(x: 634, y: 384))
eye.addCurve(to: CGPoint(x: 300, y: 520), control1: CGPoint(x: 634, y: 656), control2: CGPoint(x: 390, y: 656))
eye.closeSubpath()

// A navy margin around the eye so it cuts cleanly through the shaft.
ctx.addPath(eye)
ctx.setStrokeColor(color(0x0C3A66))
ctx.setLineWidth(46)
ctx.strokePath()

ctx.addPath(eye)
ctx.setFillColor(white)
ctx.fillPath()

// Iris, pupil and highlight, clipped to the eye.
ctx.saveGState()
ctx.addPath(eye)
ctx.clip()
ctx.setFillColor(iris)
ctx.fillEllipse(in: CGRect(x: 512 - 98, y: 520 - 98, width: 196, height: 196))
ctx.setStrokeColor(irisRim)
ctx.setLineWidth(14)
ctx.strokeEllipse(in: CGRect(x: 512 - 91, y: 520 - 91, width: 182, height: 182))
ctx.setFillColor(navy)
ctx.fillEllipse(in: CGRect(x: 512 - 44, y: 520 - 44, width: 88, height: 88))
ctx.setFillColor(white)
ctx.fillEllipse(in: CGRect(x: 540 - 17, y: 490 - 17, width: 34, height: 34))
ctx.restoreGState()

// Thin lid line to give the eye an outline against the white anchor strokes.
ctx.addPath(eye)
ctx.setStrokeColor(navy)
ctx.setLineWidth(7)
ctx.strokePath()

ctx.restoreGState()

// MARK: Write the PNG
let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AnchorWatch/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let url = folder.appendingPathComponent("AppIcon.png")
guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("can't write") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote", url.path)
