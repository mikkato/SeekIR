// ModelExtensions.swift — недостающие члены InspectionModel: экспорт, импорт PNG16,
// панели, мета-хелперы (UI-хуки для RootView/App).
import AppKit
import UniformTypeIdentifiers

@MainActor
extension InspectionModel {
    var currentPlanckForUI: PlanckValues {
        var p = sk_planck_t()
        skcap_planck_get(engine.cap, &p)
        return PlanckValues(r1: p.r1, b: p.b, f: p.f, o: p.o, r2: p.r2)
    }
    var calibratedText: String {
        FileManager.default.fileExists(atPath: Engine.calibPath)
            ? "двухточечная Планка загружена" : "нет (дефолт ядра, ±5 °C)"
    }

    // MARK: экспорт из toolbar (страница «Отчёт» — расширенный вариант с превью)

    func exportPDF() {
        guard !frames.isEmpty else {
            lastError = AppError(kind: .noTemperature, userText: "Нет снимков для отчёта.",
                                 savedDataText: "—", actionText: "Сделайте снимок (⌘3).")
            return
        }
        let p = NSSavePanel()
        p.nameFieldStringValue = (doc.meta.title.isEmpty ? "Отчёт" : doc.meta.title) + ".pdf"
        p.allowedContentTypes = [.pdf]
        guard p.runModal() == .OK, let url = p.url else { return }
        let d = collectReportData(self), e = engine
        runExport(name: "PDF") { try ReportService.exportPDF(data: d, engine: e, to: url) }
    }
    func exportPNG() {
        guard let f = selectedFrame ?? frames.last else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "Термограмма.png"
        p.allowedContentTypes = [.png]
        guard p.runModal() == .OK, let url = p.url else { return }
        let d = collectReportData(self), e = engine
        runExport(name: "PNG") { try ReportService.exportPNG(data: d, engine: e, frame: f, to: url) }
    }
    func exportCSV() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Измерения.csv"
        p.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        let d = collectReportData(self)
        runExport(name: "CSV") { try ReportService.exportCSV(data: d, to: url) }
    }
    func exportTempMatrix() {
        guard let f = selectedFrame ?? frames.last else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "Матрица_temp.f64"
        guard p.runModal() == .OK, let url = p.url else { return }
        runExport(name: "матрица") { try ReportService.exportTempMatrix(frame: f, to: url) }
    }
    private func runExport(name: String, work: @escaping @Sendable () throws -> Void) {
        Task.detached(priority: .userInitiated) { [weak self] in
            do { try work() }
            catch let e as AppError { await MainActor.run { self?.lastError = e } }
            catch {
                await MainActor.run {
                    self?.lastError = AppError(kind: .writeFailed,
                                               userText: "Экспорт \(name) не выполнен.",
                                               savedDataText: "Документ не изменён.",
                                               actionText: "Повторите.",
                                               technical: String(describing: error))
                }
            }
        }
    }

    func openViaPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "seekscan") ?? .data, .data]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { open(url: u) }
    }

    func exportDiagnosticsPanel() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "seekir-diag-\(sessionId).log"
        p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        // ERR-04: без полных путей и ПД; экспорт только по команде пользователя
        try? exportDiagnostics().replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Термография",
            .applicationVersion: "1.0-P0 (core E1 bit-exact)"])
    }

    // MARK: импорт PNG16 (E2 signal snapshots -> кадр документа)

    func importPNG16(url: URL? = nil) {
        let fileURL: URL?
        if let url = url { fileURL = url }
        else {
            let p = NSOpenPanel()
            p.allowedContentTypes = [.png]
            p.directoryURL = FileManager.default.urls(for: .picturesDirectory,
                                                      in: .userDomainMask)[0]
                .appendingPathComponent("SeekIR")
            fileURL = p.runModal() == .OK ? p.url : nil
        }
        guard let u = fileURL else { return }
        // снимок UI-настроек в main actor (фон не лезет в @MainActor-свойства)
        let palIdx = palette
        let sceneNow = currentScene
        var planckRaw = sk_planck_t()
        skcap_planck_get(engine.cap, &planckRaw)
        let planckNow = PlanckValues(r1: planckRaw.r1, b: planckRaw.b, f: planckRaw.f,
                                    o: planckRaw.o, r2: planckRaw.r2)
        let eng = engine
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self,
                  let rep = NSBitmapImageRep(data: (try? Data(contentsOf: u)) ?? Data()),
                  rep.samplesPerPixel == 1, rep.bitsPerSample == 16,
                  let base = rep.bitmapData else {
                await MainActor.run {
                    self?.lastError = AppError(kind: .docCorrupt,
                        userText: "Файл не является 16-битным сигнальным PNG (snap-*.png).",
                        savedDataText: "Импортный файл не изменён.",
                        actionText: "Выберите PNG16 из ~/Pictures/SeekIR.")
                }
                return
            }
            let w = 320, h = 240
            let signal = base.withMemoryRebound(to: UInt16.self, capacity: w * h) {
                Array(UnsafeBufferPointer(start: $0, count: w * h))
            }
            // температуры — пересчёт ТЕКУЩИМ ядром (Планк-калибровка на момент импорта)
            var temp = [Double](repeating: .nan, count: w * h)
            for i in 0..<(w * h) where i < signal.count {
                temp[i] = eng.signalToC(Double(signal[i]))
            }
            // рендер ядром: tonemap(авто) + LUT палитры
            var tm = sk_tonemap_t(automatic: true, lo: 0, hi: 0, seeded: false)
            sk_tonemap_init(&tm, true)
            var gray = [UInt8](repeating: 0, count: w * h)
            temp.withUnsafeBufferPointer { td in
                sk_tonemap_apply(&tm, td.baseAddress, false, &gray)
            }
            var lut = [(UInt8, UInt8, UInt8)](repeating: (0, 0, 0), count: 256)
            let pal = sk_palette_t(rawValue: UInt32(palIdx))
            sk_palette_lut(pal, &lut)
            var rgb = [UInt8](repeating: 0, count: w * h * 3)
            lut.withUnsafeBufferPointer { l in
                sk_palette_map(l.baseAddress, &gray, &rgb)
            }
            var f = FrameSnapshot(sessionFrameId: -1, hostTimestamp: Date(),
                                  dataKind: "import:signal+render; temp=core-recalc",
                                  temp: temp, signal: signal, rgb: rgb,
                                  spanLo: tm.lo, spanHi: tm.hi, palette: palIdx,
                                  planck: planckNow, scene: sceneNow)
            f.validityRule += "; imported (temp per current calib)"
            await MainActor.run {
                self.frames.append(f)
                self.selectedFrameId = f.id
                self.mode = .analysis
                self.markDirty()
                self.logAdd("import png16 \(u.lastPathComponent)")
            }
        }
    }
}
