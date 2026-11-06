import AppKit

// Draws the app icon: a dark squircle, a light drive and load bars. Usage: swift make_icon.swift <out.iconset>
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // background
    let inset = s * 0.06
    let bg = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: bg, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.10, green: 0.16, blue: 0.30, alpha: 1).cgColor,
                                   NSColor(red: 0.04, green: 0.07, blue: 0.14, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.restoreGState()

    // drive body
    let body = CGRect(x: s * 0.20, y: s * 0.52, width: s * 0.60, height: s * 0.26)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: s * 0.06, cornerHeight: s * 0.06, transform: nil)
    ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor); ctx.addPath(bodyPath); ctx.fillPath()
    ctx.setFillColor(NSColor(red: 0.20, green: 0.80, blue: 0.45, alpha: 1).cgColor)       // LED
    ctx.fillEllipse(in: CGRect(x: s * 0.68, y: s * 0.62, width: s * 0.06, height: s * 0.06))
    ctx.setFillColor(NSColor(white: 0.70, alpha: 1).cgColor)
    ctx.fill(CGRect(x: s * 0.26, y: s * 0.64, width: s * 0.28, height: s * 0.035))

    // load bars
    let heights: [CGFloat] = [0.10, 0.17, 0.26, 0.14, 0.21]
    let colors: [NSColor] = [.systemGreen, .systemGreen, .systemOrange, .systemGreen, .systemRed]
    let bw = s * 0.085, gap = s * 0.028
    var x = s * 0.20 + (s * 0.60 - (bw * 5 + gap * 4)) / 2
    for (h, c) in zip(heights, colors) {
        let r = CGRect(x: x, y: s * 0.17, width: bw, height: s * h * 1.0)
        ctx.setFillColor(c.cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: bw * 0.3, cornerHeight: bw * 0.3, transform: nil)); ctx.fillPath()
        x += bw + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                              ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes { try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png")) }
print("iconset ready: \(out)")
