// Renders the Downright app icon (concept "A": the ↳ glyph) into an .iconset folder.
//   swift App/Icon/render-icon.swift App/Icon/Downright.iconset
//   iconutil -c icns App/Icon/Downright.iconset -o App/Downright/Resources/AppIcon.icns
// Geometry follows Apple's macOS icon template: the rounded square occupies 824/1024 of
// the canvas with a soft shadow beneath, so it sizes like neighbouring icons.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Downright.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(size: Int, scale: Int, name: String) {
    let px = size * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let s = CGFloat(px) / 1024.0            // design units → pixels
    cg.scaleBy(x: s, y: s)
    // Flip to a top-left origin so coordinates match the SVG concept.
    cg.translateBy(x: 0, y: 1024); cg.scaleBy(x: 1, y: -1)

    let inset: CGFloat = 100
    let square = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
    let radius = square.width * 0.2237
    let shape = CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Shadow (only meaningful at larger sizes; scale it with the icon)
    if px >= 64 {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        cg.addPath(shape); cg.setFillColor(CGColor(gray: 0.1, alpha: 1)); cg.fillPath()
        cg.restoreGState()
    }

    // Ground: deep green-black vertical gradient, clipped to the squircle
    cg.saveGState()
    cg.addPath(shape); cg.clip()
    let colors = [CGColor(srgbRed: 0x26/255, green: 0x35/255, blue: 0x2E/255, alpha: 1),
                  CGColor(srgbRed: 0x12/255, green: 0x1A/255, blue: 0x16/255, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: square.minY), end: CGPoint(x: 0, y: square.maxY), options: [])
    // Faint top highlight, as Apple's template icons have
    cg.setFillColor(CGColor(gray: 1, alpha: 0.05))
    cg.fill(CGRect(x: square.minX, y: square.minY, width: square.width, height: square.height * 0.5))
    cg.restoreGState()

    // The ↳ glyph. Coordinates are the SVG's, scaled into the inset square.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: square.minX + x * square.width / 1024, y: square.minY + y * square.height / 1024) }
    let stroke = 112 * square.width / 1024
    cg.setStrokeColor(CGColor(srgbRed: 0xF2/255, green: 0xF5/255, blue: 0xF1/255, alpha: 1))
    cg.setLineWidth(stroke); cg.setLineCap(.round); cg.setLineJoin(.round)
    cg.move(to: p(330, 220)); cg.addLine(to: p(330, 620)); cg.addLine(to: p(640, 620)); cg.strokePath()
    cg.move(to: p(600, 470)); cg.addLine(to: p(760, 620)); cg.addLine(to: p(600, 770)); cg.strokePath()
    // Green dot where the stroke starts
    cg.setFillColor(CGColor(srgbRed: 0x2F/255, green: 0xA3/255, blue: 0x5A/255, alpha: 1))
    let r = 72 * square.width / 1024
    cg.fillEllipse(in: CGRect(x: p(330, 220).x - r, y: p(330, 220).y - r, width: 2 * r, height: 2 * r))

    ctx.flushGraphics()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    render(size: size, scale: 1, name: "icon_\(size)x\(size).png")
    render(size: size, scale: 2, name: "icon_\(size)x\(size)@2x.png")
}
print("wrote iconset to \(outDir)")
