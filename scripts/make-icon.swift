// Renders the Image Canvas app icon: a De Stijl (Mondrian) grid of panes.
//
//   swift scripts/make-icon.swift Resources/AppIcon.png
//
// Then scripts/make-icon.sh turns the PNG into Resources/AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")

// Apple's macOS icon grid: an 824pt body centred in a 1024pt canvas, corner radius ~185.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let red = color(0xD62718), blue = color(0x1D3E9A), yellow = color(0xF6C21C)
let white = color(0xF3F0E7), black = color(0x111111)

// The composition, in fractions of the body, top-left origin. Lines are drawn on the
// boundaries between cells, so these coordinates are line centres.
let lineWidth: CGFloat = 30
let vMain: CGFloat = 0.63     // the long vertical
let hLeft: CGFloat = 0.58     // horizontal across the left column
let vLeftLow: CGFloat = 0.25  // vertical splitting the bottom-left
let hRightA: CGFloat = 0.32   // horizontals in the right column
let hRightB: CGFloat = 0.80

struct Cell { let rect: CGRect; let fill: CGColor }
let cells: [Cell] = [
    Cell(rect: CGRect(x: 0, y: 0, width: vMain, height: hLeft), fill: red),
    Cell(rect: CGRect(x: 0, y: hLeft, width: vLeftLow, height: 1 - hLeft), fill: blue),
    Cell(rect: CGRect(x: vLeftLow, y: hLeft, width: vMain - vLeftLow, height: 1 - hLeft), fill: white),
    Cell(rect: CGRect(x: vMain, y: 0, width: 1 - vMain, height: hRightA), fill: white),
    Cell(rect: CGRect(x: vMain, y: hRightA, width: 1 - vMain, height: hRightB - hRightA), fill: white),
    Cell(rect: CGRect(x: vMain, y: hRightB, width: 1 - vMain, height: 1 - hRightB), fill: yellow),
]
// (x0, y0, x1, y1) in fractions; each is a straight black bar.
let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (vMain, 0, vMain, 1),
    (0, hLeft, vMain, hLeft),
    (vLeftLow, hLeft, vLeftLow, 1),
    (vMain, hRightA, 1, hRightA),
    (vMain, hRightB, 1, hRightB),
]

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("could not create context")
}
// Work in a top-left-origin space so the composition reads as written.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
    CGPoint(x: body.minX + fx * body.width, y: body.minY + fy * body.height)
}
func rect(_ r: CGRect) -> CGRect {
    CGRect(x: body.minX + r.minX * body.width, y: body.minY + r.minY * body.height,
           width: r.width * body.width, height: r.height * body.height)
}

let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow under the tile, as macOS icons have.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(black)
ctx.fillPath()
ctx.restoreGState()

// Panes and lead lines, clipped to the rounded tile.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
for cell in cells {
    ctx.setFillColor(cell.fill)
    ctx.fill(rect(cell.rect))
}
ctx.setStrokeColor(black)
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.square)
for (x0, y0, x1, y1) in lines {
    ctx.move(to: point(x0, y0))
    ctx.addLine(to: point(x1, y1))
}
ctx.strokePath()
ctx.restoreGState()

// A hairline edge so the tile holds its shape on light and dark backgrounds.
ctx.addPath(shape)
ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
ctx.setLineWidth(2)
ctx.strokePath()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("could not render")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out.path)") }
print("wrote \(out.path)")
