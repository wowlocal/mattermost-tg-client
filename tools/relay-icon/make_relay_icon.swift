// Generates Relay's placeholder app icon artwork locally (no downloads):
//   <out>/R.svg        — the letter "R" as an SVG path (white), for the Icon Composer bundle
//   <out>/AppIcon.png  — a 1024x1024 flattened PNG (coloured square + white "R"), for PNG-based uses
// Usage: xcrun swift make_icon.swift <out-dir>
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let canvas: CGFloat = 1024.0
let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 640.0, nil)
var unichar: UniChar = UniChar(UnicodeScalar("R").value)
var glyph: CGGlyph = 0
CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1)
guard let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil) else {
    fatalError("no glyph path")
}
let bounds = glyphPath.boundingBoxOfPath

// Center the glyph; flip from CoreText (y up) to SVG (y down).
let dx = (canvas - bounds.width) / 2.0 - bounds.minX
let dy = (canvas - bounds.height) / 2.0 - bounds.minY
var toSvg = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: dx, ty: canvas - dy)
guard let svgPath = glyphPath.copy(using: &toSvg) else {
    fatalError("transform failed")
}

func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }
var d = ""
svgPath.applyWithBlock { elementPointer in
    let e = elementPointer.pointee
    let p = e.points
    switch e.type {
    case .moveToPoint: d += "M\(fmt(p[0].x)),\(fmt(p[0].y)) "
    case .addLineToPoint: d += "L\(fmt(p[0].x)),\(fmt(p[0].y)) "
    case .addQuadCurveToPoint: d += "Q\(fmt(p[0].x)),\(fmt(p[0].y)) \(fmt(p[1].x)),\(fmt(p[1].y)) "
    case .addCurveToPoint: d += "C\(fmt(p[0].x)),\(fmt(p[0].y)) \(fmt(p[1].x)),\(fmt(p[1].y)) \(fmt(p[2].x)),\(fmt(p[2].y)) "
    case .closeSubpath: d += "Z "
    @unknown default: break
    }
}

let svg = """
<?xml version="1.0" encoding="UTF-8"?>
<svg width="1024px" height="1024px" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg">
    <title>R</title>
    <g id="R" stroke="none" fill="none" fill-rule="nonzero">
        <path fill="#FFFFFF" d="\(d.trimmingCharacters(in: .whitespaces))"></path>
    </g>
</svg>

"""
try svg.write(to: outDir.appendingPathComponent("R.svg"), atomically: true, encoding: .utf8)

// Flattened PNG: teal-to-indigo gradient square with the white "R".
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let gradient = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(srgbRed: 0.16, green: 0.62, blue: 0.62, alpha: 1.0),
    CGColor(srgbRed: 0.20, green: 0.33, blue: 0.70, alpha: 1.0),
] as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas), end: CGPoint(x: canvas, y: 0), options: [])
var toPng = CGAffineTransform(translationX: dx, y: dy)
let pngPath = glyphPath.copy(using: &toPng)!
ctx.addPath(pngPath)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
let image = ctx.makeImage()!
let pngURL = outDir.appendingPathComponent("AppIcon.png")
let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outDir.path)/R.svg and AppIcon.png")
