// makeicon.swift — генерация иконки приложения: тёмный squircle + горячее пятно ironbow + прицел + шкала.
import AppKit

let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// фон — squircle
let rect = CGRect(x: 90, y: 90, width: S - 180, height: S - 180)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: cs,
    colors: [c(24, 28, 38), c(10, 12, 18)] as CFArray, locations: [0, 1])!,
    start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// ironbow LUT для пятна и шкалы
var lut = [UInt8](repeating: 0, count: 256 * 3)
lut.withUnsafeMutableBytes { raw in
    if let p = raw.bindMemory(to: (UInt8, UInt8, UInt8).self).baseAddress {
        // заполняем аналитически (без ядра): ironbow-подобный ramp
        let stops: [(CGFloat, (Int,Int,Int))] = [
            (0.00,(8,6,28)), (0.15,(38,18,90)), (0.32,(122,32,120)),
            (0.50,(200,60,80)), (0.66,(245,120,40)), (0.82,(252,196,90)), (1.00,(250,244,220))]
        for i in 0..<256 {
            let t = CGFloat(i) / 255
            var a = stops[0], b = stops[stops.count - 1]
            for k in 0..<(stops.count - 1) where t >= stops[k].0 && t <= stops[k+1].0 { a = stops[k]; b = stops[k+1]; break }
            let f = (t - a.0) / max(b.0 - a.0, 0.0001)
            raw[i*3+0] = UInt8((CGFloat(a.1.0) + (CGFloat(b.1.0)-CGFloat(a.1.0))*f).rounded())
            raw[i*3+1] = UInt8((CGFloat(a.1.1) + (CGFloat(b.1.1)-CGFloat(a.1.1))*f).rounded())
            raw[i*3+2] = UInt8((CGFloat(a.1.2) + (CGFloat(b.1.2)-CGFloat(a.1.2))*f).rounded())
        }
    }
}
// пятно-термограмма: радиальный ironbow, со смещением вверх-влево
let center = CGPoint(x: 512, y: 512)
let colors = (0..<48).map { i -> CGColor in
    let j = 255 - (i * 255 / 47)   // центр = hot
    return c(Int(lut[j*3]), Int(lut[j*3+1]), Int(lut[j*3+2]), i == 47 ? 0 : 1)
}
let locs = (0..<48).map { CGFloat($0) / 47.0 }
if let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs) {
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                          endCenter: center, endRadius: 300,
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
// прицел по центру пятна
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
ctx.setLineWidth(14)
ctx.move(to: CGPoint(x: center.x - 150, y: center.y)); ctx.addLine(to: CGPoint(x: center.x - 55, y: center.y))
ctx.move(to: CGPoint(x: center.x + 55, y: center.y)); ctx.addLine(to: CGPoint(x: center.x + 150, y: center.y))
ctx.move(to: CGPoint(x: center.x, y: center.y - 150)); ctx.addLine(to: CGPoint(x: center.x, y: center.y - 55))
ctx.move(to: CGPoint(x: center.x, y: center.y + 55)); ctx.addLine(to: CGPoint(x: center.x, y: center.y + 150))
ctx.strokePath()
ctx.setLineWidth(13)
ctx.setStrokeColor(CGColor(srgbRed: 0.02, green: 0.02, blue: 0.05, alpha: 0.9))
ctx.strokeEllipse(in: CGRect(x: center.x - 36, y: center.y - 36, width: 72, height: 72))
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
ctx.setLineWidth(5)
ctx.strokeEllipse(in: CGRect(x: center.x - 36, y: center.y - 36, width: 72, height: 72))

ctx.setStrokeColor(c(255, 255, 255, 0.10)); ctx.setLineWidth(6)
ctx.addPath(path); ctx.strokePath()
NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon_master.png"
try! png.write(to: URL(fileURLWithPath: out))
print("icon ->", out)
