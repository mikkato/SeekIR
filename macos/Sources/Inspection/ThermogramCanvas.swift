// ThermogramCanvas.swift — термограмма: NEAREST-битмап кадра + оверлеи измерений,
// зонд под курсором, рисование инструментов, zoom/pan (VIEW-01…VIEW-07).
// Все преобразования — через FrameGeometry (единственный источник, TEST-03).
import SwiftUI
import AppKit

final class ThermogramNSView: NSView {
    weak var model: InspectionModel?
    var image: CGImage?
    var geometry: FrameGeometry = FrameGeometry()
    var onZoom: ((Double) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onFit: (() -> Void)?
    var onDraw: (((x: Int, y: Int)) -> Void)?
    var onHover: (((x: Int, y: Int)?) -> Void)?

    private var spaceDown = false
    private var panning = false
    private var panStart: CGPoint = .zero
    private var panBase: CGSize = .zero

    override var isFlipped: Bool { true }           // y вниз == row-major матрицы
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    // MARK: отрисовка

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(bounds)
        guard let model = model else { return }
        let g = FrameGeometry(viewW: Double(bounds.width), viewH: Double(bounds.height),
                              zoom: model.zoom, panX: Double(model.pan.width),
                              panY: Double(model.pan.height), rotation: model.imageRotation,
                              stretch: model.stretchFill)
        geometry = g
        let r = g.contentRect

        if let img = image {
            ctx.saveGState()
            ctx.interpolationQuality = model.nearestFilter ? .none : .high   // VIEW-04
            ctx.draw(img, in: r)
            ctx.restoreGState()
        } else {
            // пустое состояние (CAM-04 «Нет потока» / нет кадра) — не чёрный прямоугольник-обманка
            ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let s = NSAttributedString(string: emptyText(for: model), attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 15), .paragraphStyle: p])
            s.draw(in: CGRect(x: bounds.midX - 200, y: bounds.midY - 12, width: 400, height: 24))
        }

        // оверлеи измерений (координаты матрицы -> view)
        for m in model.measurements where m.visible {
            let sel = model.selection.contains(m.id)
            let col = NSColor(hex: m.colorHex).cgColor
            switch m.kind {
            case .point:
                let p = g.viewPoint(matrixX: m.x0, matrixY: m.y0)
                ctx.setStrokeColor(col); ctx.setLineWidth(sel ? 2.5 : 1.5)
                ctx.strokeEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                ctx.move(to: CGPoint(x: p.x - 10, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 10, y: p.y))
                ctx.move(to: CGPoint(x: p.x, y: p.y - 10)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 10))
                ctx.strokePath()
            case .rect:
                let rr = g.viewRect(x0: m.x0, y0: m.y0, x1: m.x1, y1: m.y1)
                ctx.setStrokeColor(col); ctx.setLineWidth(sel ? 2.5 : 1.5)
                ctx.stroke(rr)
            case .line:
                let a = g.viewPoint(matrixX: m.x0, matrixY: m.y0)
                let b = g.viewPoint(matrixX: m.x1, matrixY: m.y1)
                ctx.setStrokeColor(col); ctx.setLineWidth(sel ? 2.5 : 1.5)
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            case .diff:
                break   // отображается в таблице (нет своей геометрии)
            }
            if sel, m.kind != .diff {
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            }
        }

        // черновик рисования
        if let a = model.draftA, let p = model.hover {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3]); ctx.setLineWidth(1.5)
            switch model.tool {
            case .rect:
                let rr = g.viewRect(x0: min(a.x, p.x), y0: min(a.y, p.y),
                                    x1: max(a.x, p.x), y1: max(a.y, p.y))
                ctx.stroke(rr)
            case .line:
                ctx.move(to: g.viewPoint(matrixX: a.x, matrixY: a.y))
                ctx.addLine(to: g.viewPoint(matrixX: p.x, matrixY: p.y)); ctx.strokePath()
            default: break
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // курсорная визирная линия + подпись температуры (подпись непрозрачна — UI-04)
        if let h = model.hover, let img = image {
            let p = g.viewPoint(matrixX: h.x, matrixY: h.y)
            ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: r.minX, y: p.y)); ctx.addLine(to: CGPoint(x: r.maxX, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: r.minY)); ctx.addLine(to: CGPoint(x: p.x, y: r.maxY))
            ctx.strokePath()
            let txt = model.hoverTemp(x: h.x, y: h.y)
            let maxLabelW: CGFloat = 170
            let lx: CGFloat = (p.x + 12 + maxLabelW > bounds.maxX) ? p.x - 12 - maxLabelW : p.x + 12
            drawLabel(txt, at: CGPoint(x: max(2, lx), y: min(max(p.y + 14, 2), bounds.maxY - 24)),
                      in: ctx)
        }
    }

    private func emptyText(for m: InspectionModel) -> String {
        switch m.acquisition {
        case .notConnected: return "Камера не подключена\nПодключите Seek PIR324 и нажмите «Подключить»"
        case .connecting: return "Подключение камеры…"
        case .initializing: return "Инициализация… первый кадр"
        case .error(let e): return "Нет потока: \(e)"
        case .disconnecting: return "Отключение…"
        case .streaming: return "Ожидание кадра…"
        }
    }

    func drawLabel(_ s: String, at p: CGPoint, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor]
        let astr = NSAttributedString(string: s, attributes: attrs)
        let sz = astr.size()
        let bg = CGRect(x: p.x - 4, y: p.y - 2, width: sz.width + 8, height: sz.height + 4)
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)   // непрозрачно (UI-04)
        ctx.fill(bg)
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.stroke(bg)
        // view flipped (isFlipped == true): AppKit рисует текст сам правильно;
        // рисовать строго внутри плашки bg (справа от перекрестия), иначе глифы
        // улетали в левый край в зеркальном виде.
        astr.draw(at: CGPoint(x: bg.minX + 4, y: bg.minY + 2))
    }

    // MARK: события

    override func mouseDown(with e: NSEvent) {
        guard let model = model else { return }
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2 { onFit?(); return }
        if spaceDown || e.modifierFlags.contains(.control) {
            panning = true; panStart = p; panBase = model.pan; return
        }
        if model.tool == nil {
            // клик по измерению -> selection (обратный поиск по view-геометрии)
            if let hit = hitTestMeasurement(at: p, model: model) {
                if e.modifierFlags.contains(.shift) {
                    if model.selection.contains(hit) { model.selection.remove(hit) }
                    else { model.selection.insert(hit) }
                } else { model.selection = [hit] }
            } else { model.selection.removeAll() }
            return
        }
        if let mp = geometry.matrixPixel(fromView: p) { onDraw?(mp) }
    }

    private func hitTestMeasurement(at p: CGPoint, model: InspectionModel) -> UUID? {
        for m in model.measurements.reversed() where m.visible && m.kind != .diff {
            switch m.kind {
            case .point:
                let c = geometry.viewPoint(matrixX: m.x0, matrixY: m.y0)
                if hypot(p.x - c.x, p.y - c.y) < 10 { return m.id }
            case .rect:
                let r = geometry.viewRect(x0: m.x0, y0: m.y0, x1: m.x1, y1: m.y1).insetBy(dx: -4, dy: -4)
                if r.contains(p) { return m.id }
            case .line:
                let a = geometry.viewPoint(matrixX: m.x0, matrixY: m.y0)
                let b = geometry.viewPoint(matrixX: m.x1, matrixY: m.y1)
                if distanceToSegment(p, a, b) < 8 { return m.id }
            default: break
            }
        }
        return nil
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if panning {
            onPan?(CGSize(width: panBase.width + (p.x - panStart.x),
                          height: panBase.height + (p.y - panStart.y)))
        } else if let mp = geometry.matrixPixel(fromView: p) {
            model?.hover = (mp.x, mp.y)
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) { panning = false }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        model?.hover = geometry.matrixPixel(fromView: p)
        needsDisplay = true
    }
    override func mouseExited(with e: NSEvent) { onHover?(nil); needsDisplay = true }

    override func scrollWheel(with e: NSEvent) {
        guard let model = model else { return }
        if e.modifierFlags.contains(.control) || abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX),
           e.hasPreciseScrollingDeltas {
            // pinch/двухпальцевый — zoom (VIEW-05)
            let f = exp(Double(e.scrollingDeltaY) * 0.01)
            onZoom?(min(max(model.zoom * f, 0.5), 16))
        } else {
            onPan?(CGSize(width: model.pan.width - e.scrollingDeltaX,
                          height: model.pan.height - e.scrollingDeltaY))
        }
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 { spaceDown = true }          // Space = pan (VIEW-05)
        if e.keyCode == 53 { model?.draftA = nil }       // Escape — отмена фигуры
        if e.keyCode == 51 { model?.deleteSelected() }   // Delete — удалить выбранное (MEAS-05)
        if e.keyCode == 6, e.modifierFlags.contains(.command) {   // ⌘Z / ⇧⌘Z (MEAS-05)
            if e.modifierFlags.contains(.shift) { model?.redo() } else { model?.undo() }
            return
        }
        let step = e.modifierFlags.contains(.shift) ? 10 : 1   // стрелки 1px / Shift 10px
        switch e.keyCode {
        case 123: model?.nudgeSelected(dx: -step, dy: 0); return
        case 124: model?.nudgeSelected(dx: step, dy: 0); return
        case 125: model?.nudgeSelected(dx: 0, dy: step); return
        case 126: model?.nudgeSelected(dx: 0, dy: -step); return
        default: break
        }
        super.keyDown(with: e)
    }
    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 { spaceDown = false }
        super.keyUp(with: e)
    }
}

private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let l2 = dx * dx + dy * dy
    guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2
    t = max(0, min(1, t))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
extension CGRect {
    init(center: CGPoint, size: CGFloat) {
        self.init(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }
}

// MARK: — SwiftUI-обёртка + colorbar (шкала непрозрачна, HOT/COLD риски + подписи) —

struct ThermogramCanvas: NSViewRepresentable {
    @ObservedObject var model: InspectionModel

    func makeNSView(context: Context) -> ThermogramNSView {
        let v = ThermogramNSView()
        v.model = model
        return v
    }
    func updateNSView(_ v: ThermogramNSView, context: Context) {
        v.model = model
        v.image = context.coordinator.currentImage(for: model)
        v.onZoom = { z in model.zoom = z; v.needsDisplay = true }
        v.onPan = { p in model.pan = p; v.needsDisplay = true }
        v.onFit = { model.zoom = 1; model.pan = .zero; v.needsDisplay = true }
        v.onDraw = { model.beginOrContinueTool(at: $0) }
        v.onHover = { model.hover = $0 }
        v.needsDisplay = true
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    @MainActor
    final class Coordinator {
        var lastStamp = Date.distantPast
        var cache: CGImage?
        func currentImage(for model: InspectionModel) -> CGImage? {
            if let f = model.selectedFrame, model.mode != .camera {
                return cacheIfChanged(rgb: f.rgb, key: "r\(model.imageRotation) f\(f.id)")
            }
            if let s = model.workingFrame() {
                return cacheIfChanged(rgb: s.rgb, key: "r\(model.imageRotation) s\(s.frameID)")
            }
            return nil
        }
        private var key = ""
        private func cacheIfChanged(rgb: [UInt8], key: String) -> CGImage? {
            if key == self.key, cache != nil { return cache }
            self.key = key
            guard !rgb.isEmpty else { cache = nil; return nil }
            let rot = key.split(separator: " ").first.flatMap { Int($0.dropFirst()) } ?? 0
            cache = Self.makeCGImage(rgb: rgb, rotation: rot)
            return cache
        }
        /// Построение битмапа с поворотом Пиксельных данных (против часовой, 0/90/180/270).
        /// Данные поворачиваются в буфере — CTM остаётся как у рабочего render-path.
        static func makeCGImage(rgb: [UInt8], rotation: Int) -> CGImage? {
            let w = 320, h = 240
            let rot = ((rotation % 360) + 360) % 360
            let swap = rot == 90 || rot == 270
            let dw = swap ? h : w, dh = swap ? w : h
            var rgba = [UInt8](repeating: 255, count: dw * dh * 4)
            for y in 0..<h { for x in 0..<w {
                let dx: Int, dy: Int
                switch rot {
                case 90:  dx = y;       dy = w - 1 - x   // против часовой
                case 180: dx = w - 1 - x; dy = h - 1 - y
                case 270: dx = h - 1 - y; dy = x
                default:  dx = x;       dy = y
                }
                let si = (y * w + x) * 3, di = (dy * dw + dx) * 4
                rgba[di] = rgb[si]; rgba[di+1] = rgb[si+1]; rgba[di+2] = rgb[si+2]
            }}
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            return rgba.withUnsafeMutableBytes { buf in
                CGContext(data: buf.baseAddress, width: dw, height: dh, bitsPerComponent: 8,
                          bytesPerRow: dw * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
        }
    }
}

// MARK: — палитра LUT ядра -> SwiftUI градиент; треугольник-риска HOT/COLD —

func gradientStops(palette: Int, samples: Int = 32) -> [Gradient.Stop] {
    var lut = [UInt8](repeating: 0, count: 256 * 3)
    lut.withUnsafeMutableBytes { raw in
        if let p = raw.bindMemory(to: (UInt8, UInt8, UInt8).self).baseAddress {
            sk_palette_lut(sk_palette_t(rawValue: UInt32(palette)), p)
        }
    }
    var stops: [Gradient.Stop] = []
    for i in 0..<samples {
        let idx = i * 255 / (samples - 1)
        let r: Double = Double(lut[idx * 3]) / 255.0
        let g: Double = Double(lut[idx * 3 + 1]) / 255.0
        let b: Double = Double(lut[idx * 3 + 2]) / 255.0
        let c = Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
        let loc: Double = Double(i) / Double(samples - 1)
        stops.append(Gradient.Stop(color: c, location: loc))
    }
    return stops
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Вертикальная шкала текущего span в единицах отображения; HOT/COLD — цветные риски (E2-спека).
struct TempScaleBar: View {
    @ObservedObject var model: InspectionModel

    var body: some View {
        let lo = model.spanLo
        let hi = model.spanHi
        let loC: Double = model.engine.signalToC(lo)
        let hiC: Double = model.engine.signalToC(hi)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                bar
                hotTick(lo: loC, hi: hiC, h: geo.size.height)
                coldTick(lo: loC, hi: hiC, h: geo.size.height)
                labels(loC: loC, hiC: hiC)
            }
        }
        .frame(width: 74)
        .accessibilityLabel(Text(scaleAX(loC: model.engine.signalToC(lo), hiC: model.engine.signalToC(hi))))
    }

    private var bar: some View {
        LinearGradient(stops: gradientStops(palette: model.palette),
                       startPoint: .bottom, endPoint: .top)
            .frame(width: 16).padding(.leading, 2)
    }

    private func tickY(_ t: Double, lo: Double, hi: Double, h: CGFloat) -> CGFloat {
        guard hi > lo else { return h / 2 }
        let f = min(max((t - lo) / (hi - lo), 0), 1)
        return h * CGFloat(1 - f) - 4
    }

    @ViewBuilder private func hotTick(lo: Double, hi: Double, h: CGFloat) -> some View {
        if let mx = extreme(max: true) {
            Triangle().fill(.yellow).frame(width: 7, height: 7)
                .rotationEffect(.degrees(90))
                .offset(x: 18, y: tickY(mx, lo: lo, hi: hi, h: h))
        }
    }
    @ViewBuilder private func coldTick(lo: Double, hi: Double, h: CGFloat) -> some View {
        if let mn = extreme(max: false) {
            Triangle().fill(.cyan).frame(width: 7, height: 7)
                .rotationEffect(.degrees(-90))
                .offset(x: -1, y: tickY(mn, lo: lo, hi: hi, h: h))
        }
    }

    private func extreme(max: Bool) -> Double? {
        guard let f = model.workingFrame() else { return nil }
        var v = max ? -Double.infinity : Double.infinity
        var any = false
        for t in f.temp where tempIsValid(t) {
            any = true
            v = max ? Swift.max(v, t) : Swift.min(v, t)
        }
        return any ? v : nil
    }

    private func labels(loC: Double, hiC: Double) -> some View {
        let f = model.units
        func lbl(_ t: Double) -> some View {
            Text(f.format(t, digits: 1))
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1).fixedSize()
                .padding(2).background(.windowBackground)
        }
        return VStack(spacing: 0) {
            lbl(hiC)
            Spacer(minLength: 0)
            lbl((loC + hiC) / 2)
            Spacer(minLength: 0)
            lbl(loC)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func scaleAX(loC: Double, hiC: Double) -> String {
        "Температурная шкала \(model.units.format(loC, digits: 0)) … \(model.units.format(hiC, digits: 0))"
    }
}

// °C-значение границы шкалы: span сигналов -> °C пересчётом ядра (Engine.signalToC)
func EngineSignalToC(model: InspectionModel, sig: Double) -> Double {
    model.engine.signalToC(sig)
}
