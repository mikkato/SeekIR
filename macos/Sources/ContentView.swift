// ContentView + App — UI SeekIR (E2). Интерфейс — нативный macOS, язык RU.
import SwiftUI
import AppKit

struct LiveView: NSViewRepresentable {
    @ObservedObject var engine: Engine
    var onHover: ((CGPoint?, Int, Int) -> Void)?
    func makeNSView(context: Context) -> ClickView {
        let v = ClickView()
        v.onClick = { x, y in engine.probe(x: x, y: y) }
        v.onHoverPix = { p, x, y in onHover?(p, x, y) }
        v.onHoverEnd = { onHover?(nil, 0, 0) }
        return v
    }
    func updateNSView(_ v: ClickView, context: Context) {
        v.image = engine.frameImage
        v.onHoverPix = { p, x, y in onHover?(p, x, y) }
    }
}

final class ClickView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onClick: ((Int, Int) -> Void)?
    var onHoverPix: ((CGPoint, Int, Int) -> Void)?
    var onHoverEnd: (() -> Void)?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited,
                                         .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    private func pix(_ p: CGPoint) -> (Int, Int) {
        (min(max(Int(p.x / bounds.width * CGFloat(Engine.W)), 0), Engine.W - 1),
         min(max(Int(p.y / bounds.height * CGFloat(Engine.H)), 0), Engine.H - 1))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image = image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let (x, y) = pix(p)
        onClick?(x, y)
    }
    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let (x, y) = pix(p)
        onHoverPix?(p, x, y)
    }
    override func mouseExited(with e: NSEvent) { onHoverEnd?() }
}

struct CalibSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State var t1 = "0.0"
    @State var t2 = "99.7"
    @State var m1: (n: Int, mean: Double)? = nil
    @State var m2: (n: Int, mean: Double)? = nil
    @State var phase = 1          // 1 = ждём точку 1, 2 = точку 2, 3 = готов
    @State var message = "Наведите камеру на первый эталон (например, стакан ледяной воды, крупный план ≥ половины кадра)."
    @State var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Калибровка Планка (чёрное тело)").font(.headline)
            Text(message).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
            HStack {
                Text("T₁ эталона, °C:"); TextField("", text: $t1).frame(width: 70)
                Spacer()
                if let m = m1 { Text("сигнал₁ \(Int(m.mean)) (\(m.n) кадр.)") }
            }
            HStack {
                Text("T₂ эталона, °C:"); TextField("", text: $t2).frame(width: 70)
                Spacer()
                if let m = m2 { Text("сигнал₂ \(Int(m.mean)) (\(m.n) кадр.)") }
            }
            HStack(spacing: 16) {
                Button(busy ? "Идёт замер (30 кадров)…" :
                            (phase == 1 ? "Замер 1" : "Замер 2")) {
                    measure()
                }.disabled(busy || phase == 3)
                Button("Применить и сохранить") { apply() }
                    .disabled(m1 == nil || m2 == nil)
                Button("Сброс калибровки") {
                    engine.resetPlanck(); dismiss()
                }
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    func measure() {
        busy = true
        engine.startMeasure()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            guard let r = engine.finishMeasure() else {
                message = "Не набралось 30 кадров — проверьте поток."; busy = false; return
            }
            if phase == 1 {
                m1 = r
                message = "Точка 1 записана (сигнал \(Int(r.mean))). Наведите на второй эталон (кипяток) и жмите «Замер 2»."
                phase = 2
            } else {
                m2 = r
                message = "Точка 2 записана (сигнал \(Int(r.mean))). Проверяйте T₁/T₂ и жмите «Применить и сохранить»."
                phase = 3
            }
            busy = false
        }
    }

    func apply() {
        guard let m1 = m1, let m2 = m2,
              let v1 = Double(t1.replacingOccurrences(of: ",", with: ".")),
              let v2 = Double(t2.replacingOccurrences(of: ",", with: ".")),
              abs(v1 - v2) > 5 else {
            message = "Температуры эталонов должны различаться минимум на 5 °C."; return
        }
        if engine.fitPlanck(s1: m1.mean, t1: v1, s2: m2.mean, t2: v2) {
            if engine.savePlanck() {
                message = "Калибровка сохранена в planck.calib. Точность по эталонам — в пределах фита."
            } else {
                message = "Фит выполнен, но запись файла не удалась."
            }
        } else {
            message = "Фит вырожден (сигналы слишком близки?) — повторите замеры."
        }
    }
}

struct ContentView: View {
    @ObservedObject var engine: Engine
    @State var showCalib = false
    @State var lastSnap = ""
    @State private var hover: (at: CGPoint, text: String)? = nil

    var body: some View {
        HStack(spacing: 0) {
            GalleryView(engine: engine)
                .frame(width: 168)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    LiveView(engine: engine, onHover: { p, x, y in
                        if let p = p { hover = (p, engine.hoverTemp(x: x, y: y)) }
                        else { hover = nil }
                    })
                    .aspectRatio(CGFloat(Engine.W) / CGFloat(Engine.H), contentMode: .fit)
                    .overlay {
                        GeometryReader { geo in
                            if let h = hover {
                                TooltipBadge(text: h.text)
                                    .position(x: min(h.at.x + 70, geo.size.width - 46),
                                              y: max(h.at.y - 18, 14))
                            }
                            if engine.recording {
                                HStack(spacing: 5) {
                                    Circle().fill(.red).frame(width: 10, height: 10)
                                    Text("REC").font(.system(.caption, design: .monospaced,
                                                             weight: .bold))
                                        .foregroundColor(.white)
                                }
                                .padding(6).background(.black.opacity(0.7))
                                .cornerRadius(6)
                                .position(x: geo.size.width - 42, y: 20)
                            }
                        }
                    }
                    ColorBar(engine: engine).frame(width: 100)
                }
                .padding(10)
                .background(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                .padding(12)
                Divider()
                controlPanel
                statusBar
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .toolbar { toolbarContent }
        .onAppear {
            let hm = Bundle.main.path(forResource: "hot", ofType: "bin")
            engine.start(hotmap: hm)
            engine.refreshGallery()
        }
        .onDisappear { engine.stop() }
        .sheet(isPresented: $showCalib) { CalibSheet(engine: engine) }
        .onReceive(NotificationCenter.default.publisher(for: .seekCalib)) { _ in
            showCalib = true
        }
        .background(KeyHandler(freeze: { engine.setFrozen(!engine.isFrozen) }))
    }

    // --- родная панель инструментов ---
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let p = engine.snapshot() { lastSnap = "фото: \(p)" }
                engine.refreshGallery()
            } label: { Label("Снять фото", systemImage: "camera.fill") }
                .help("Снимок PNG16 + JPEG + метаданные (⌘S)")
                .keyboardShortcut("s", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { engine.toggleRecording() } label: {
                Label(engine.recording ? "Остановить" : "Снять видео",
                      systemImage: engine.recording ? "stop.fill" : "video.fill")
                    .foregroundStyle(engine.recording ? Color.red : Color.primary)
            }
            .help(engine.recording ? "Остановить запись видео"
                                   : "Запись видео MP4 (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { engine.setFrozen(!engine.isFrozen) } label: {
                Label("Заморозка", systemImage:
                        engine.frozenUI ? "play.fill" : "pause.fill")
            }
            .help("Пауза потока (Пробел)")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Палитра", selection: $engine.palette) {
                    ForEach(engine.palettes, id: \.1) { Text($0.0).tag($0.1) }
                }
                .onChange(of: engine.palette) { engine.applyPalette($0) }
            } label: { Label("Палитра", systemImage: "paintpalette.fill") }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showCalib = true } label: {
                Label("Калибровка Планка", systemImage: "crosshair")
            }
            .help("Мастер калибровки по двум чёрным телам (⌘⇧K)")
        }
    }

    // --- панель управления под кадром ---
    var controlPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Toggle("Span авто", isOn: $engine.spanAuto)
                    .onChange(of: engine.spanAuto) { _ in engine.applySpan() }
                if !engine.spanAuto {
                    Text("чёрный").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $engine.spanLo, in: 12000...18000)
                        .frame(width: 110)
                        .onChange(of: engine.spanLo) { _ in engine.applySpan() }
                    Text("белый").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $engine.spanHi, in: 12000...20000)
                        .frame(width: 110)
                        .onChange(of: engine.spanHi) { _ in engine.applySpan() }
                }
                Spacer()
                Picker("Единицы", selection: $engine.units) {
                    Text("°C").tag(0); Text("°F").tag(1); Text("K").tag(2)
                }
                .pickerStyle(.segmented).fixedSize()
                Toggle("HOT/COLD", isOn: $engine.showSpots)
                    .toggleStyle(.switch).controlSize(.small)
            }
            HStack(spacing: 20) {
                sliderCol("Сглаживание", value: $engine.smooth, range: 0.05...1.0,
                          key: "smooth")
                sliderCol("Чувств. движения", value: Binding(
                    get: { Double(engine.motion) },
                    set: { engine.motion = Int($0) }), range: 60...600, key: "motion")
                sliderCol("Зачистка шума", value: Binding(
                    get: { Double(engine.spatial) },
                    set: { engine.spatial = Int($0) }), range: 5...80, key: "spatial")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    func sliderCol(_ title: String, value: Binding<Double>,
                   range: ClosedRange<Double>, key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .onChange(of: value.wrappedValue) { _ in engine.applyDenoise() }
                .accessibilityLabel(key)
        }
    }

    var statusBar: some View {
        HStack(spacing: 14) {
            Text(engine.connected
                    ? String(format: "%.1f кадр/с", engine.fps) : "камера не подключена")
            Text("span \(Int(engine.spanLo))…\(Int(engine.spanHi))")
            Text("зонд: \(engine.probeText)")
            Spacer()
            if !lastSnap.isEmpty {
                Text(lastSnap).lineLimit(1).truncationMode(.middle)
            }
            if !engine.videoPath.isEmpty {
                Text("видео: \(engine.videoPath)").lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 5)
    }
}

// Галерея снимков/видео слева
struct GalleryView: View {
    @ObservedObject var engine: Engine
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "photo.on.rectangle.angled")
                Text("Галерея").font(.headline)
                Spacer()
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(engine.shots) { s in
                        GalleryThumb(shot: s)
                            .onTapGesture { NSWorkspace.shared.open(s.url) }
                            .contextMenu {
                                Button("Показать в Finder") {
                                    NSWorkspace.shared
                                        .activateFileViewerSelecting([s.url])
                                }
                                Button("Открыть") { NSWorkspace.shared.open(s.url) }
                            }
                    }
                }
                .padding(8)
            }
            Divider()
            Button("Обновить") { engine.refreshGallery() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct GalleryThumb: View {
    let shot: Engine.Shot
    var body: some View {
        Group {
            if shot.isVideo {
                VStack(spacing: 4) {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(shot.url.lastPathComponent)
                        .font(.caption2).lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 84)
                .background(Color(nsColor: .underPageBackgroundColor))
            } else if let img = NSImage(contentsOf: shot.url) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 84)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color(nsColor: .separatorColor)))
        .help(shot.url.lastPathComponent)
    }
}

// Контрастная подпись: белое полужирное на почти-чёрном, обводка цветом
struct TooltipBadge: View {
    let text: String
    var accent: Color = .gray
    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.black.opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(accent, lineWidth: 1))
            .cornerRadius(5)
            .fixedSize()
    }
}

// Вертикальная шкала температур: палитра + подписи span + риски HOT/COLD
struct ColorBar: View {
    @ObservedObject var engine: Engine
    var body: some View {
        GeometryReader { geo in
            let ok = geo.size.width.isFinite && geo.size.height.isFinite
            let lut = engine.paletteRGB()
            let barW = geo.size.width - 48
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                if ok {
                Canvas { ctx, sz in
                    let rows = 128
                    for r in 0..<rows {
                        let gi = (rows - 1 - r) * 2          // сверху = hi (255)
                        let c = Color(.sRGB,
                                     red: Double(lut[gi * 3]) / 255,
                                     green: Double(lut[gi * 3 + 1]) / 255,
                                     blue: Double(lut[gi * 3 + 2]) / 255)
                        ctx.fill(
                            Path(CGRect(x: 0,
                                        y: CGFloat(r) * sz.height / CGFloat(rows),
                                        width: barW,
                                        height: sz.height / CGFloat(rows) + 0.6)),
                            with: .color(c))
                    }
                }
                .frame(width: barW)
                }
                // риски HOT / COLD
                if ok, engine.showSpots, let hs = engine.hotSpot,
                   engine.tempToFrac(hs.t).isFinite {
                    ScaleTick(color: .yellow)
                        .frame(width: barW + 6, height: 8)
                        .position(x: barW / 2 + 3,
                                  y: (1 - engine.tempToFrac(hs.t)) * h)
                }
                if ok, engine.showSpots, let cs = engine.coldSpot,
                   engine.tempToFrac(cs.t).isFinite {
                    ScaleTick(color: .cyan)
                        .frame(width: barW + 6, height: 8)
                        .position(x: barW / 2 + 3,
                                  y: (1 - engine.tempToFrac(cs.t)) * h)
                }
                // подписи span
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.fmtT(engine.signalToC(engine.spanHi)))
                    Spacer()
                    Text(engine.fmtT(engine.signalToC((engine.spanLo + engine.spanHi) / 2)))
                    Spacer()
                    Text(engine.fmtT(engine.signalToC(engine.spanLo)))
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.white)
                .shadow(color: .black, radius: 2)
                .offset(x: barW + 5)
            }
        }
        .background(Color.black)
    }
}

// Риска на шкале: линия через бар + треугольник-указатель слева
struct ScaleTick: View {
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }.stroke(color, lineWidth: 1.5)
                Path { p in
                    let w: CGFloat = 6, hh = geo.size.height / 2
                    p.move(to: CGPoint(x: 0, y: hh))
                    p.addLine(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: w, y: geo.size.height))
                    p.closeSubpath()
                }.fill(color)
            }
        }
        .shadow(color: .black.opacity(0.9), radius: 1)
    }
}

struct KeyHandler: NSViewRepresentable {
    var freeze: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = KeyView(); v.freeze = freeze; return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        (v as? KeyView)?.freeze = freeze
    }
    final class KeyView: NSView {
        var freeze: (() -> Void)?
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with e: NSEvent) {
            if e.keyCode == 49 { freeze?() }   // Пробел
            else { super.keyDown(with: e) }
        }
    }
}

// legacy E2 entry (отключён: точка входа теперь SeekIRInspectionApp)
struct SeekIRAppLegacy: App {
    @StateObject private var engine = Engine()
    var body: some Scene {
        WindowGroup("SeekIR") {
            ContentView(engine: engine)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Калибровка Планка…") {
                    NotificationCenter.default.post(name: .seekCalib, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name { static let seekCalib = Notification.Name("seekCalib") }
