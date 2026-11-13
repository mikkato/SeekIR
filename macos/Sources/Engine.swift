// SeekIR.macos — E2 клиент поверх core (seekcap).
// Живой просмотр, палитры, span, freeze, зонд, снимок PNG16+JPEG+meta,
// пункт меню «Калибровка Планка» (мастер 2 чёрных тел, ТЗ F8).
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

// MARK: — мост к C (seekcap/seekcore через Bridging-Header) —

final class Engine: ObservableObject {
    static let W = 320, H = 240

    @Published var frameImage: NSImage? = nil
    @Published var fps: Double = 0
    @Published var connected = false
    @Published var spanAuto = true
    @Published var spanLo = 15000.0
    @Published var spanHi = 16500.0
    @Published var palette: Int32 = 0          // sk_palette_t
    // F9 постобработка (старое ТЗ §9): baseline 0.75/440/75, персист в UserDefaults
    @Published var smooth: Double = UserDefaults.standard.object(forKey: "denoiseSmooth") as? Double ?? 0.75 {
        didSet { UserDefaults.standard.set(smooth, forKey: "denoiseSmooth") }
    }
    @Published var motion: Int = UserDefaults.standard.object(forKey: "denoiseMotion") as? Int ?? 440 {
        didSet { UserDefaults.standard.set(motion, forKey: "denoiseMotion") }
    }
    @Published var spatial: Int = UserDefaults.standard.object(forKey: "denoiseSpatial") as? Int ?? 75 {
        didSet { UserDefaults.standard.set(spatial, forKey: "denoiseSpatial") }
    }
    @Published var probeText = "—"
    @Published var statusText = "подключение…"
    @Published var units: Int = 0               // 0=°C 1=°F 2=K
    @Published var showSpots = true             // авто HOT/COLD (F2)

    struct Spot { let x: Int; let y: Int; let t: Double }
    @Published var hotSpot: Spot? = nil
    @Published var coldSpot: Spot? = nil
    @Published var recording = false
    @Published var videoPath = ""

    struct Shot: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let isVideo: Bool
    }
    @Published var shots: [Shot] = []

    private(set) var cap: OpaquePointer? = nil
    private var frozen = false
    // последний кадр (для зонда/снимка в main-потоке)
    private var latestRGB = [UInt8]()
    private var latestTemp = [Double]()
    private var latestSignal = [UInt16]()
    private var latestLo = 0.0, latestHi = 0.0
    private var latestFrameID = 0          // счётчик кадров сессии skcap (DATA-01)
    private var latestStamp = Date()       // хост-время приёма (устройство время не даёт)
    let lock = NSLock()
    // видеописьмо (E2: MP4/H.264 через AVAssetWriter)
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    // калибровка: счётчик замеров
    var measureSamples = [Double]()
    var measuring = false

    let palettes: [(String, Int32)] = [
        ("Ironbow", 0), ("Ironbow2", 1), ("Rainbow", 2), ("Arctic", 3),
        ("White Hot", 4), ("Black Hot", 5), ("Lava", 6), ("Jet", 7),
        ("Medical", 8),
    ]

    static var calibPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("SeekIR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir.appendingPathComponent("planck.calib").path
    }

    func start(hotmap: String?) {
        measureSamples = []
        cap = skcap_open({ user, f in
            guard let user = user, let f = f else { return }
            let e = Unmanaged<Engine>.fromOpaque(user).takeUnretainedValue()
            e.onFrame(f)
        }, Unmanaged.passUnretained(self).toOpaque(), hotmap)
        if cap == nil { statusText = "камера не найдена" }
        // калибровка из Application Support, если есть
        if FileManager.default.fileExists(atPath: Self.calibPath) {
            let r = skcap_planck_load(cap, Self.calibPath)
            statusText = r == 0 ? "поток (калибровка загружена)"
                                : "поток (калибр. не прочитан — дефолт)"
        } else {
            statusText = "поток (без калибровки, ±5 °C)"
        }
    }

    func stop() {
        if let cap = cap { skcap_close(cap); self.cap = nil }
    }

    private func onFrame(_ f: UnsafePointer<skcap_frame_t>) {
        let n = Self.W * Self.H
        var hot: Spot?, cold: Spot?
        lock.lock()
        if !frozen {
            latestRGB = Array(UnsafeBufferPointer(start: f.pointee.rgb, count: n * 3))
            latestTemp = Array(UnsafeBufferPointer(start: f.pointee.temp, count: n))
            latestSignal = Array(UnsafeBufferPointer(start: f.pointee.signal, count: n))
            latestLo = f.pointee.lo
            latestHi = f.pointee.hi
            latestFrameID = Int(f.pointee.frames)
            latestStamp = Date()
            // авто HOT/COLD (F2): по радиометрической карте, невалидные (-273) мимо
            var hiT = -Double.greatestFiniteMagnitude, loT = Double.greatestFiniteMagnitude
            var hiI = -1, loI = -1
            for i in 0..<n {
                let t = latestTemp[i]
                if t < -270 || t.isNaN { continue }
                if t > hiT { hiT = t; hiI = i }
                if t < loT { loT = t; loI = i }
            }
            if hiI >= 0 && hiT > loT {
                hot = Spot(x: hiI % Self.W, y: hiI / Self.W, t: hiT)
                cold = Spot(x: loI % Self.W, y: loI / Self.W, t: loT)
            }
            if recording { appendVideoFrame() }
        }
        if measuring { measureSamples.append(f.pointee.mean_signal) }
        let fps = f.pointee.fps
        let conn: Bool = { var c: Int32 = 0
            skcap_stats(cap, nil, nil, nil, nil, &c); return c != 0 }()
        lock.unlock()
        DispatchQueue.main.async {
            self.fps = fps
            self.connected = conn
            if !self.frozen {
                if self.spanAuto {
                    self.spanLo = self.latestLo.rounded(); self.spanHi = self.latestHi.rounded()
                }
                if hot != nil { self.hotSpot = hot; self.coldSpot = cold }
                self.buildImage()
            }
        }
    }

    private func buildImage() {
        let w = Self.W, h = Self.H
        guard latestRGB.count == w * h * 3 else { return }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i*4] = latestRGB[i*3]
            rgba[i*4+1] = latestRGB[i*3+1]
            rgba[i*4+2] = latestRGB[i*3+2]
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w*4,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgi = ctx.makeImage()!
        // апскейл нативным NEAREST для пиксельной чёткости
        let img = NSImage(size: NSSize(width: w * 3, height: h * 3))
        img.lockFocus()
        if let cg = ctx.data {
            let src = CGContext(data: cg, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w*4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: src.makeImage()!, size: img.size)
                .draw(in: NSRect(origin: .zero, size: img.size))
        }
        img.unlockFocus()
        _ = cgi
        frameImage = img
    }

    // MARK: действия UI
    func setFrozen(_ f: Bool) { frozen = f; frozenUI = f }
    var isFrozen: Bool { frozen }
    @Published var frozenUI = false

    // MARK: атомарный снимок кадра (ARC-07, MEAS-07)
    // Независимые копии temp+signal+rgb+span+planck под тем же NSLock —
    // указатели skcap_frame_t переиспользуются ядром, в асинхронную отрисовку не отдаём.
    struct Snapshot {
        var frameID: Int
        var stamp: Date
        var temp: [Double]
        var signal: [UInt16]
        var rgb: [UInt8]
        var lo: Double
        var hi: Double
        var palette: Int
        var planck: PlanckValues
        var scene: SceneValues
        var denoise: DenoiseValues
    }

    func captureSnapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard latestRGB.count == Self.W * Self.H * 3,
              latestTemp.count == Self.W * Self.H else { return nil }
        var p = sk_planck_t()
        skcap_planck_get(cap, &p)
        var s = sk_scene_t()
        sk_scene_default(&s)   // текущие scene-параметры ядра недоступны напрямую —
        // берём из UI-зеркала ниже (applyScene вызывает InspectionModel)
        return Snapshot(frameID: latestFrameID, stamp: latestStamp,
                        temp: latestTemp, signal: latestSignal, rgb: latestRGB,
                        lo: latestLo, hi: latestHi, palette: Int(palette),
                        planck: PlanckValues(r1: p.r1, b: p.b, f: p.f, o: p.o, r2: p.r2),
                        scene: s2v(s), denoise: DenoiseValues(smooth: smooth, motion: motion,
                                                              spatial: spatial))
    }
    private func s2v(_ s: sk_scene_t) -> SceneValues {
        SceneValues(emissivity: s.emissivity, tReflC: s.t_refl_c, tAtmC: s.t_atm_c,
                    distanceM: s.distance_m, relHumidity: s.rel_humidity)
    }

    /// Диагностика состояния для CAM-машинки (одна сессия, без параллельных команд).
    func pollConnected() -> Bool {
        guard cap != nil else { return false }
        var c: Int32 = 0
        skcap_stats(cap, nil, nil, nil, nil, &c)
        return c != 0
    }

    func applyPalette(_ p: Int32) { skcap_set_palette(cap, sk_palette_t(rawValue: UInt32(p))) }
    func applyDenoise() {
        skcap_set_denoise(cap, Float(smooth), Int32(motion), Int32(spatial), true)
    }
    func applySpan() {
        skcap_set_span_manual(cap, !spanAuto, spanLo, spanHi)
    }
    /// Прямая передача параметров сцены ядру (работает — влияет на temp-матрицу).
    func skcapScene(_ v: SceneValues) {
        skcap_set_scene(cap, v.emissivity, v.tReflC, v.tAtmC, v.distanceM, v.relHumidity)
    }
    var isSessionOpen: Bool { cap != nil }

    func probe(x: Int, y: Int) {
        lock.lock(); defer { lock.unlock() }
        let ix = min(max(x, 0), Self.W - 1), iy = min(max(y, 0), Self.H - 1)
        guard latestTemp.count == Self.W * Self.H else { probeText = "—"; return }
        // CG координаты сверху вниз, буфер тоже row-major сверху вниз
        let t = latestTemp[iy * Self.W + ix]
        probeText = fmtT(t) + "  сигн.\(Int(latestSignal[iy * Self.W + ix]))"
    }
    func fmtT(_ t: Double) -> String {
        switch units {
        case 1: return String(format: "%.1f °F", t * 9/5 + 32)
        case 2: return String(format: "%.1f K", t + 273.15)
        default: return String(format: "%.1f °C", t)
        }
    }

    // MARK: галерея (снимки/видео в Pictures/SeekIR)
    func galleryDir() -> URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeekIR", isDirectory: true)
    }

    func refreshGallery() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: galleryDir(),
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let keep: Set<String> = ["jpg", "png", "mp4"]
        let shots = items
            .filter { keep.contains($0.pathExtension.lowercased())
                && ($0.lastPathComponent.hasPrefix("snap-")
                    || $0.lastPathComponent.hasPrefix("vid-")) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da > db
            }
            .map { Shot(url: $0, isVideo: $0.pathExtension == "mp4") }
        DispatchQueue.main.async { self.shots = shots }
    }

    // MARK: снимок (F6)
    func snapshot() -> String? {
        lock.lock()
        let sig = latestSignal, tmp = latestTemp, rgb = latestRGB
        let lo = latestLo, hi = latestHi
        lock.unlock()
        guard sig.count == Self.W * Self.H, !rgb.isEmpty else { return nil }
        let fm = FileManager.default
        let pics = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeekIR", isDirectory: true)
        try? fm.createDirectory(at: pics, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = pics.appendingPathComponent("snap-\(stamp.string(from: Date()))")
        // PNG16 — 16-битный сигнал (ре-радиометрия без камеры)
        let pngURL = base.appendingPathExtension("png")
        if !writePNG16(sig, to: pngURL) { return nil }
        // JPEG — палитра
        let jpegURL = base.appendingPathExtension("jpg")
        writeJPEG(rgb, to: jpegURL)
        // meta
        var p = sk_planck_t()
        skcap_planck_get(cap, &p)
        let calib = FileManager.default.fileExists(atPath: Self.calibPath)
        let meta = """
        {
          "device": "Seek CompactPRO",
          "timestamp": "\(ISO8601DateFormatter().string(from: Date()))",
          "width": \(Self.W), "height": \(Self.H),
          "signal_png16": "\(pngURL.lastPathComponent)",
          "jpeg": "\(jpegURL.lastPathComponent)",
          "span_lo": \(lo), "span_hi": \(hi),
          "palette": \(palette),
          "denoise": { "smooth": \(smooth), "motion": \(motion), "spatial": \(spatial) },
          "planck": { "r1": \(p.r1), "b": \(p.b), "f": \(p.f), "o": \(p.o), "r2": \(p.r2) },
          "planck_calibrated": \(calib),
          "core": "E1 bit-exact"
        }
        """
        let metaURL = base.appendingPathExtension("seekmeta.json")
        try? meta.write(to: metaURL, atomically: true, encoding: .utf8)
        return base.path
    }

    private func writePNG16(_ sig: [UInt16], to url: URL) -> Bool {
        var data = sig
        let cs16 = CGColorSpace(name: CGColorSpace.linearGray)!
        guard let ctx = CGContext(data: &data, width: Self.W, height: Self.H,
                                  bitsPerComponent: 16, bytesPerRow: Self.W * 2,
                                  space: cs16,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return false
        }
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    private func writeJPEG(_ rgb: [UInt8], to url: URL) {
        let w = Self.W, h = Self.H
        var rgba = [UInt8](repeating: 255, count: w*h*4)
        for i in 0..<(w*h) {
            rgba[i*4] = rgb[i*3]; rgba[i*4+1] = rgb[i*3+1]; rgba[i*4+2] = rgb[i*3+2]
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
        memcpy(rep.bitmapData, rgba, rgba.count)
        if let d = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
            try? d.write(to: url)
        }
    }

    // MARK: калибровка Планка (F8)
    func startMeasure() { lock.lock(); measureSamples.removeAll(); measuring = true; lock.unlock() }
    func finishMeasure() -> (n: Int, mean: Double)? {
        lock.lock(); measuring = false
        let s = measureSamples; lock.unlock()
        guard s.count >= 30 else { return nil }
        return (s.count, s.reduce(0, +) / Double(s.count))
    }
    func fitPlanck(s1: Double, t1: Double, s2: Double, t2: Double) -> Bool {
        return skcap_planck_fit(cap, s1, t1, s2, t2)
    }
    func savePlanck() -> Bool {
        return skcap_planck_save(cap, Self.calibPath) == sk_err_t(SK_OK.rawValue)
    }
    func resetPlanck() {
        _ = skcap_planck_load(cap, nil)
        try? FileManager.default.removeItem(atPath: Self.calibPath)
    }
    func currentPlanck() -> sk_planck_t {
        var p = sk_planck_t()
        skcap_planck_get(cap, &p)
        return p
    }

    // MARK: температура под курсором / шкала
    func hoverTemp(x: Int, y: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        guard latestTemp.count == Self.W * Self.H else { return "—" }
        let i = min(max(y, 0), Self.H - 1) * Self.W + min(max(x, 0), Self.W - 1)
        return fmtT(latestTemp[i])
    }

    /// сигнал span -> °C для подписей колорбара (та же цепочка, что у карты)
    func signalToC(_ sig: Double) -> Double {
        var p = currentPlanck()
        var s = sk_scene_t(emissivity: 0.95, t_refl_c: 20, t_atm_c: 20,
                           distance_m: 1, rel_humidity: 50)
        return sk_signal_to_celsius(&p, &s, sig)
    }

    /// °C -> доля 0..1 по серой шкале текущего span (для рисок HOT/COLD)
    func tempToFrac(_ t: Double) -> CGFloat {
        var p = currentPlanck()
        let sig = sk_celsius_to_signal(&p, t)
        let span = spanHi - spanLo
        guard span > 1 else { return 0.5 }
        return min(max((sig - spanLo) / span, 0), 1)
    }

    /// LUT текущей палитры 256x3 RGB
    func paletteRGB() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 256 * 3)
        buf.withUnsafeMutableBytes { raw in
            if let p = raw.bindMemory(to: (UInt8, UInt8, UInt8).self).baseAddress {
                sk_palette_lut(sk_palette_t(rawValue: UInt32(palette)), p)
            }
        }
        return buf
    }

    // MARK: видео (MP4/H.264)
    func toggleRecording() { recording ? stopRecording() : startRecording() }

    private func startRecording() {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.urls(for: .picturesDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("SeekIR", isDirectory: true)
            .appendingPathComponent("vid-\(stamp.string(from: Date())).mp4")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            statusText = "видео: не создан писатель"; return
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.W, AVVideoHeightKey: Self.H,
        ])
        input.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.W,
                kCVPixelBufferHeightKey as String: Self.H,
            ])
        w.add(input)
        if w.startWriting() {
            w.startSession(atSourceTime: CMClockGetTime(.hostTimeClock))
            writer = w; writerInput = input; adaptor = ad
            videoPath = ""
            recording = true
            statusText = "запись видео…"
        } else {
            statusText = "видео: startWriting failed"
        }
    }

    private func stopRecording() {
        recording = false
        statusText = "поток"
        writerInput?.markAsFinished()
        writer?.finishWriting { [weak self] in
            let p = self?.writer?.outputURL.path ?? ""
            DispatchQueue.main.async {
                self?.videoPath = p
                self?.writer = nil
                self?.writerInput = nil
                self?.adaptor = nil
                self?.refreshGallery()
            }
        }
    }

    /// вызывается под lock в capture-потоке
    private func appendVideoFrame() {
        guard let ad = adaptor, let input = writerInput,
              input.isReadyForMoreMediaData,
              latestRGB.count == Self.W * Self.H * 3 else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, Self.W, Self.H, kCVPixelFormatType_32BGRA,
                                 nil, &pb) == kCVReturnSuccess,
              let buf = pb else { return }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let d = base.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(Self.W * Self.H) {
            let o = (i / Self.W) * bpr + (i % Self.W) * 4
            d[o] = latestRGB[i * 3 + 2]      // B
            d[o + 1] = latestRGB[i * 3 + 1]  // G
            d[o + 2] = latestRGB[i * 3]      // R
            d[o + 3] = 255
        }
        ad.append(buf, withPresentationTime: CMClockGetTime(.hostTimeClock))
    }
}
