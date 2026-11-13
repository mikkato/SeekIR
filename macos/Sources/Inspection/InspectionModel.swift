// InspectionModel.swift — presentation model (ARC-02). Камера, документ, измерения,
// выбор, режимы, undo/redo, ошибки. Ядро не трогает — только через Engine (адаптер).
import Foundation
import AppKit
import Combine

enum AppMode: String, CaseIterable { case camera = "Камера", analysis = "Анализ", report = "Отчёт" }
enum DrawTool: String, CaseIterable { case point = "Точка", rect = "Область", line = "Линия" }

@MainActor
final class InspectionModel: ObservableObject {
    static let W = 320, H = 240

    // — ядро-адаптер (E2 Engine) —
    let engine = Engine()

    // — CAM-01: явная машина состояний захвата —
    @Published var acquisition: AcquisitionState = .notConnected {
        didSet { if acquisition != oldValue { logState() } }
    }
    private var sawFrames = false
    private var pollTimer: Timer?

    // — документ —
    @Published var doc = ScanDocument()
    @Published var docURL: URL? = nil
    @Published var isDirty = false
    @Published var readOnlyNewerSchema = false

    @Published var frames: [FrameSnapshot] = []
    @Published var selectedFrameId: UUID? = nil
    @Published var measurements: [Measurement] = []
    @Published var selection: Set<UUID> = []
    @Published var defects: [Defect] = []

    // — режим/инструменты —
    @Published var mode: AppMode = .camera
    @Published var tool: DrawTool? = nil
    @Published var draftA: (x: Int, y: Int)? = nil        // первая точка рисования
    @Published var hover: (x: Int, y: Int)? = nil
    @Published var hoverText = "—"
    @Published var minMaxText = "—"

    // — вид (VIEW-01; на температуры НЕ влияет — VIEW-02) —
    @Published var zoom: Double = 1
    @Published var pan: CGSize = .zero
    @Published var units: DisplayUnits = .celsius { didSet { UserDefaults.standard.set(units.rawValue, forKey: "units"); objectWillChange.send() } }
    @Published var palette: Int = 0 { didSet { engine.applyPalette(Int32(palette)) } }
    @Published var spanAuto = true
    @Published var spanLo = 15000.0
    @Published var spanHi = 16500.0
    @Published var nearestFilter = true
    /// Экранный поворот изображения, градусов против часовой (0/90/180/270).
    /// Только отображение (VIEW-02): матрица и измерения не меняются.
    @Published var imageRotation: Int =
        UserDefaults.standard.object(forKey: "imageRotation") as? Int ?? 270 {
        didSet { UserDefaults.standard.set(imageRotation, forKey: "imageRotation") }
    }
    /// Растянуть кадр на всю область просмотра (только вид; измерения в матрице — CORE-04).
    @Published var stretchFill: Bool =
        UserDefaults.standard.object(forKey: "stretchFill") as? Bool ?? false {
        didSet { UserDefaults.standard.set(stretchFill, forKey: "stretchFill") }
    }
    @Published var showInspector = true
    @Published var showMeasureTable = true

    @Published var lastError: AppError? = nil
    @Published var calibRequested = false
    @Published var closeWindowRequested = false
    @Published var selectedEquipment: Set<UUID> = []
    @Published var selectedDefectId: UUID? = nil

    // — undo/redo (MEAS-05): снимки состояния измерений —
    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    @Published var canUndo = false
    @Published var canRedo = false

    // — диагностика (ERR-03): кольцевой лог —
    struct LogLine { let t: Date; let event: String }
    private(set) var log: [LogLine] = []
    let sessionId = UUID().uuidString.prefix(8)

    var capabilities: Capabilities { Capabilities.live }   // из аудита, не из UI (DATA-03)

    var selectedFrame: FrameSnapshot? {
        frames.first { $0.id == selectedFrameId }
    }

    // MARK: — жизненный цикл / камера (CAM-03: одна сессия, без параллельных open) —

    func start() {
        units = DisplayUnits(rawValue: UserDefaults.standard.integer(forKey: "units")) ?? .celsius
        palette = UserDefaults.standard.integer(forKey: "palette")
        connect()
    }

    func connect() {
        switch acquisition {
        case .connecting, .initializing, .streaming: return   // CAM-03
        default: break
        }
        acquisition = .connecting
        logAdd("connect: начало")
        // skcap_open блокирует ~2-3 с (инициализация прошивки) — вне UI-потока (ARC-05)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let hotmap = Bundle.main.path(forResource: "hot", ofType: "bin")
            let ok: Bool = await Task.detached { self.engine.start(hotmap: hotmap); return self.engine.cap != nil }.value
            await MainActor.run {
                if ok {
                    self.acquisition = .initializing
                    self.startPolling()
                } else {
                    self.acquisition = .error(AppMessage.cameraAbsent)
                    self.logAdd("connect: камера не найдена")
                }
            }
        }
    }

    func disconnect() {
        guard acquisition == .initializing || acquisition == .streaming
                || acquisition.isLive else { return }
        acquisition = .disconnecting
        pollTimer?.invalidate(); pollTimer = nil
        Task.detached { [weak self] in
            self?.engine.stop()
            await MainActor.run { self?.acquisition = .notConnected; self?.logAdd("disconnect") }
        }
    }

    func retry() {
        disconnectIfNeededThen { [weak self] in self?.connect() }
    }
    private func disconnectIfNeededThen(_ body: @escaping () -> Void) {
        if engine.cap != nil {
            Task.detached { [weak self] in
                self?.engine.stop()
                await MainActor.run { body() }
            }
        } else { body() }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollState() }
        }
    }

    private func pollState() {
        let conn = engine.pollConnected()
        let frameCount = captureProbe()
        if conn && frameCount > 0 { sawFrames = true }
        switch acquisition {
        case .initializing where sawFrames:
            acquisition = .streaming
        case .streaming where !conn:
            // CAM-04: поток оборвался — последний кадр остаётся, live-индикатор гаснет
            acquisition = .error(AppMessage.streamLost)
            logAdd("stream lost")
        default: break
        }
        // live min/max + hover-обновление (VIEW-01)
        updateLiveProbe()
    }

    private func captureProbe() -> Int {
        // лёгкий опрос счётчиков без копирования матриц
        guard engine.cap != nil else { return 0 }
        var f: Int = 0, ff: Int = 0, er: Int = 0, rs: Int = 0, c: Int32 = 0
        skcap_stats(engine.cap, &f, &ff, &er, &rs, &c)
        return f
    }

    private var liveMirror: Engine.Snapshot? = nil   // свежий снимок live-потока для зондов
    private var liveMirrorStamp = Date.distantPast
    private func liveProbe(force: Bool = false) -> Engine.Snapshot? {
        if !force, Date().timeIntervalSince(liveMirrorStamp) < 0.25, liveMirror != nil {
            return liveMirror
        }
        let s = engine.captureSnapshot()
        if s != nil { liveMirror = s; liveMirrorStamp = Date() }
        return s ?? liveMirror
    }

    func updateLiveProbe() {
        guard acquisition == .streaming || engine.isFrozen else { minMaxText = "—"; return }
        guard let s = liveProbe() else { minMaxText = "—"; return }
        var lo = Double.infinity, hi = -Double.infinity, loN = 0, hiN = 0, n = 0
        for t in s.temp where tempIsValid(t) {
            n += 1
            if t < lo { lo = t }; if t > hi { hi = t }
        }
        _ = loN; _ = hiN
        minMaxText = n > 0
            ? "мин \(units.format(lo)) · макс \(units.format(hi))"
            : "нет валидных данных"
        if spanAuto, engine.spanAuto {
            spanLo = s.lo.rounded(); spanHi = s.hi.rounded()
        }
    }

    // MARK: — тепловые данные для анализа (MEAS: всегда из зафиксированного кадра или live-снимка) —

    /// Матрица для отображения/измерений: анализ — выбранный снимок; камера — live-снимок.
    func workingFrame() -> Engine.Snapshot? {
        if mode == .camera {
            guard acquisition == .streaming || engine.isFrozen else { return nil }
            return liveProbe(force: engine.isFrozen)
        }
        guard let f = selectedFrame else { return nil }
        return Engine.Snapshot(frameID: f.sessionFrameId, stamp: f.hostTimestamp,
                               temp: f.temp, signal: f.signal, rgb: f.rgb,
                               lo: f.spanLo, hi: f.spanHi, palette: f.palette,
                               planck: f.planck, scene: f.scene, denoise: f.denoise)
    }

    func hoverTemp(x: Int, y: Int) -> String {
        guard let s = workingFrame() else { return "—" }
        let i = min(max(y, 0), Self.H - 1) * Self.W + min(max(x, 0), Self.W - 1)
        guard i < s.temp.count else { return "—" }
        let t = s.temp[i]
        guard tempIsValid(t) else { return "нет данных" }   // MEAS-06: не выдумываем 0
        return units.format(t) + "  сигн.\(i < s.signal.count ? Int(s.signal[i]) : 0)"
    }

    // MARK: — снимок кадра в документ (MEAS-07, DOC) —

    func takeSnapshot() {
        guard let s = liveProbe(force: true) else {
            lastError = AppError(kind: .noTemperature,
                                 userText: "Нет кадра: камера не выдаёт данные.",
                                 savedDataText: "Ничего не потеряно.",
                                 actionText: "Подключите камеру и повторите (⌘E).")
            return
        }
        var f = FrameSnapshot(sessionFrameId: s.frameID, hostTimestamp: s.stamp,
                              temp: s.temp, signal: s.signal, rgb: s.rgb,
                              spanLo: s.lo, spanHi: s.hi, palette: s.palette,
                              planck: s.planck, scene: currentScene)
        f.denoise = DenoiseValues(smooth: engine.smooth, motion: engine.motion,
                                  spatial: engine.spatial)
        if doc.meta.title.isEmpty { doc.meta.title = "Обследование \(Self.dateStamp())" }
        frames.append(f)
        selectedFrameId = f.id
        markDirty()
        // measurements без frameId (live-черновики) привязываем к этому кадру (один frameID на снимок)
        for i in measurements.indices where measurements[i].frameId == nil {
            measurements[i].frameId = f.id
        }
        logAdd("snapshot frame=\(f.sessionFrameId)")
        engine.refreshGallery()   // боковая галерея E2 тоже в курсе
    }

    var currentScene = SceneValues()   // зеркало UI-сцены (ядро применило через applyScene)
    func applyScene() {
        engine.skcapScene(currentScene)
    }

    // MARK: — измерения (MEAS-01…MEAS-05) —

    func beginOrContinueTool(at p: (x: Int, y: Int)) {
        guard capabilities.supportsTemperature, workingFrame() != nil else {
            lastError = AppError(kind: .noTemperature,
                                 userText: "Температурные данные недоступны — измерения заблокированы.",
                                 savedDataText: "Просмотр доступен.",
                                 actionText: "Подключите камеру или откройте документ со снимками.")
            return
        }
        guard let tool = tool else { return }
        if tool == .point {
            pushUndo()
            let m = Measurement(kind: .point, name: autoName(tool), x0: p.x, y0: p.y,
                                x1: p.x, y1: p.y,
                                frameId: mode == .analysis ? selectedFrameId : nil)
            measurements.append(m)
            selection = [m.id]
            markDirty()
            draftA = nil
        } else if draftA == nil {
            draftA = p
        } else {
            pushUndo()
            var m = Measurement(kind: tool == .rect ? .rect : .line,
                                name: autoName(tool),
                                x0: draftA!.x, y0: draftA!.y, x1: p.x, y1: p.y,
                                frameId: mode == .analysis ? selectedFrameId : nil)
            m = m.normalized()
            measurements.append(m)
            selection = [m.id]
            markDirty()
            draftA = nil
        }
    }

    func stats(for m: Measurement) -> MeasureStats {
        // кадр измерения: снимок по frameId; если снимка нет — рабочий live-кадр,
        // иначе на странице «Отчёт» статистика пропадает (mode != .camera).
        let temp: [Double]
        if let fid = m.frameId, let f = frames.first(where: { $0.id == fid }) { temp = f.temp }
        else if let w = workingFrame() { temp = w.temp }
        else { return MeasureStats() }
        return MeasurementService.compute(m, temp: temp, all: measurements)
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        pushUndo()
        measurements.removeAll { selection.contains($0.id) }
        selection.removeAll()
        markDirty()
    }

    func nudgeSelected(dx: Int, dy: Int) {
        guard !selection.isEmpty else { return }
        pushUndo()
        for i in measurements.indices where selection.contains(measurements[i].id) {
            measurements[i].x0 = min(max(measurements[i].x0 + dx, 0), Self.W - 1)
            measurements[i].y0 = min(max(measurements[i].y0 + dy, 0), Self.H - 1)
            if measurements[i].kind != .point {
                measurements[i].x1 = min(max(measurements[i].x1 + dx, 0), Self.W - 1)
                measurements[i].y1 = min(max(measurements[i].y1 + dy, 0), Self.H - 1)
            }
        }
        markDirty()
    }

    func makeDiff() {
        guard selection.count == 2 else { return }
        pushUndo()
        let ids = Array(selection)
        let m = Measurement(kind: .diff, name: autoName(.diff), aId: ids[0], bId: ids[1],
                            frameId: selectedFrameId)
        measurements.append(m)
        selection = [m.id]
        markDirty()
    }

    private func autoName(_ k: DrawTool) -> String {
        "\(k.rawValue) \(measurements.count + 1)"
    }
    private func autoName(_ k: MeasureKind) -> String {
        k == .diff ? "Разность \(measurements.count + 1)" : autoName(DrawTool(rawValue: k.rawValue) ?? .point)
    }

    // MARK: — undo/redo (MEAS-05) —

    func pushUndo() {
        if let d = try? JSONEncoder().encode(measurements) { undoStack.append(d) }
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true; canRedo = false
    }
    func undo() {
        guard let d = undoStack.popLast() else { return }
        if let cur = try? JSONEncoder().encode(measurements) { redoStack.append(cur) }
        if let m = try? JSONDecoder().decode([Measurement].self, from: d) {
            measurements = m; markDirty()
        }
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
    }
    func redo() {
        guard let d = redoStack.popLast() else { return }
        if let cur = try? JSONEncoder().encode(measurements) { undoStack.append(cur) }
        if let m = try? JSONDecoder().decode([Measurement].self, from: d) {
            measurements = m; markDirty()
        }
        canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty
    }

    // MARK: — документ (DOC) —

    func markDirty() { isDirty = true; doc.modified = Date() }

    func newDocument() {
        if isDirty { flushSaveOrCancel { } }
        doc = ScanDocument()
        doc.meta = ScanMeta()
        frames = []; measurements = []; defects = []; selection = []
        selectedFrameId = nil; docURL = nil; isDirty = false; readOnlyNewerSchema = false
    }

    func open(url: URL) {
        do {
            let l = try ProjectStore.load(url: url)
            doc = l.doc; frames = l.frames; measurements = l.measurements
            defects = l.defects; docURL = l.url
            selectedFrameId = l.frames.last?.id
            readOnlyNewerSchema = l.newerSchema
            isDirty = false
            mode = l.frames.isEmpty ? .camera : .analysis
            if l.newerSchema {
                lastError = AppError(kind: .docVersionNew,
                                     userText: "Документ создан новой версией схемы (v\(l.doc.schemaVersion)). Открыт только для просмотра.",
                                     savedDataText: "Оригинальный файл не изменён.",
                                     actionText: "Сохраните как новую копию при необходимости.")
            }
            logAdd("open \(url.lastPathComponent) frames=\(l.frames.count)")
        } catch let e as AppError {
            lastError = e
        } catch {
            lastError = AppError(kind: .docCorrupt,
                                 userText: "Документ не читается.",
                                 savedDataText: "Файл на диске не изменён.",
                                 actionText: "Выберите другой файл.",
                                 technical: String(describing: error))
        }
    }

    func save() {
        if let url = docURL { save(to: url) } else { saveAs() }
    }
    func saveAs() {
        let p = NSSavePanel()
        p.nameFieldStringValue = (doc.meta.title.isEmpty ? "Обследование" : doc.meta.title) + ".\(ProjectStore.ext)"
        p.allowedContentTypes = [.init(filenameExtension: ProjectStore.ext) ?? .data]
        if p.runModal() == .OK, let url = p.url { save(to: url) }
    }
    func save(to url: URL) {
        guard !readOnlyNewerSchema else {
            lastError = AppError(kind: .docVersionNew,
                                 userText: "Документ новой схемы — сохранение на исходный путь запрещено.",
                                 savedDataText: "Данные в памяти.",
                                 actionText: "Сохраните как (.seekscan) в новое место.")
            return
        }
        let d = doc; let fr = frames; let me = measurements; let de = defects
        isDirty = false
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try ProjectStore.save(doc: d, frames: fr, measurements: me, defects: de, to: url)
                await MainActor.run {
                    self?.docURL = url
                    self?.logAdd("saved \(url.lastPathComponent)")
                }
            } catch let e as AppError {
                await MainActor.run { self?.isDirty = true; self?.lastError = e }
            } catch {
                await MainActor.run {
                    self?.isDirty = true
                    self?.lastError = AppError(kind: .writeFailed,
                                               userText: "Ошибка сохранения.",
                                               savedDataText: "Данные в памяти.",
                                               actionText: "Повторите в другой путь.",
                                               technical: String(describing: error))
                }
            }
        }
    }

    /// DOC-08: защита от потери при закрытии.
    func flushSaveOrCancel(then close: @escaping () -> Void) {
        guard isDirty else { close(); return }
        let a = NSAlert()
        a.messageText = "Есть несохранённые изменения"
        a.informativeText = "Документ «\(doc.meta.title.isEmpty ? "Без названия" : doc.meta.title)» изменён. Кадры и измерения будут потеряны."
        a.addButton(withTitle: "Сохранить…")
        a.addButton(withTitle: "Не сохранять")
        a.addButton(withTitle: "Отмена")
        switch a.runModal() {
        case .alertFirstButtonReturn: saveAs(); if !isDirty { close() }
        case .alertSecondButtonReturn: close()
        default: break
        }
    }

    // MARK: — настройки вида (VIEW-07) —

    func setSpanManual(lo: Double, hi: Double) {
        guard lo < hi else {
            lastError = AppError(kind: .writeFailed,
                                 userText: "Нижняя граница должна быть меньше верхней.",
                                 savedDataText: "Текущий диапазон сохранён.",
                                 actionText: "Исправьте значения.")
            return
        }
        spanAuto = false; spanLo = lo; spanHi = hi
        engine.spanAuto = false
        engine.applySpan()
    }
    func setSpanAuto() {
        spanAuto = true
        engine.spanAuto = true
        engine.applySpan()
    }

    // MARK: — журнал (ERR-03/04) —

    func logAdd(_ event: String) {
        log.append(LogLine(t: Date(), event: "[\(sessionId)] \(event)"))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }
    private func logState() { logAdd("state -> \(String(describing: acquisition))") }

    func exportDiagnostics() -> String {
        "SeekIR diagnostics\nsession=\(sessionId)\napp=1.0-P0 core=E1 bit-exact\n" +
        log.map { "\(ISO8601DateFormatter().string(from: $0.t)) \($0.event)" }.joined(separator: "\n")
    }

    static func dateStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: Date())
    }
}

enum AppMessage {
    static let cameraAbsent = "Камера PIR324 (289d:0011) не найдена в USB."
    static let streamLost = "Поток камеры прерван. Последняя термограмма сохранена."
}

// Capabilities — из аудита ядра (DATA-03), не из UI.
struct Capabilities {
    var supportsTemperature = true
    var supportsManualCalibration = true
    var supportsEmissivityAdjustment = true
    var supportsRecording = true
    var supportsRawExport = true
    var supportsTemperatureExport = true
    var supportsVisibleImage = false
    static let live = Capabilities()
}
