import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "cuelens/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let colors = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func draw(size: Int) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = Double(size) / 1024
    context.scaleBy(x: scale, y: scale)
    let tile = CGRect(x: 78, y: 78, width: 868, height: 868)
    let silhouette = CGPath(roundedRect: tile, cornerWidth: 208, cornerHeight: 208, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 29, color: color(0.02, 0.09, 0.15, 0.33))
    context.addPath(silhouette)
    context.setFillColor(color(0.06, 0.28, 0.36))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(silhouette)
    context.clip()
    let gradient = CGGradient(colorsSpace: colors, colors: [
        color(0.13, 0.46, 0.52), color(0.06, 0.29, 0.39), color(0.04, 0.16, 0.25)
    ] as CFArray, locations: [0, 0.52, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 210, y: 950), end: CGPoint(x: 780, y: 86), options: [])
    context.restoreGState()

    context.setStrokeColor(color(0.70, 0.94, 0.93, 0.18))
    context.setLineWidth(3)
    context.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 206, cornerHeight: 206, transform: nil))
    context.strokePath()

    context.setLineCap(.round)
    context.setLineWidth(35)
    context.setStrokeColor(color(0.57, 0.91, 0.84))
    context.addArc(center: CGPoint(x: 512, y: 512), radius: 239, startAngle: 0.22, endAngle: 5.55, clockwise: false)
    context.strokePath()

    let signal: [(Double, Double)] = [(381, 86), (447, 142), (512, 221), (577, 153), (643, 92)]
    context.setStrokeColor(color(0.93, 0.99, 0.97))
    context.setLineWidth(38)
    for (x, height) in signal {
        context.move(to: CGPoint(x: x, y: 512 - height / 2))
        context.addLine(to: CGPoint(x: x, y: 512 + height / 2))
    }
    context.strokePath()

    context.setFillColor(color(0.96, 0.81, 0.43))
    context.fillEllipse(in: CGRect(x: 708, y: 638, width: 58, height: 58))
    let target = output.appendingPathComponent("CueLens-\(size).png")
    let encoder = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in sizes { try draw(size: size) }
