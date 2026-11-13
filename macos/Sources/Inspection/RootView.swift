// RootView.swift — окно: toolbar, sidebar (Источник/Обследование), термограмма+шкала,
// inspector справа, таблица измерений снизу (NAV-01…NAV-06).
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case camera, importFile, details, snapshots, equipment, defects, report
    var id: String { rawValue }
    var label: String {
        switch self {
        case .camera: "Камера"; case .importFile: "Импорт"; case .details: "Сведения"
        case .snapshots: "Все снимки"; case .equipment: "Оборудование"
        case .defects: "Дефекты"; case .report: "Отчёт"
        }
    }
    var symbol: String {
        switch self {
        case .camera: "camera"; case .importFile: "square.and.arrow.down"
        case .details: "doc.text"; case .snapshots: "photo.stack"
        case .equipment: "bolt.circle"; case .defects: "exclamationmark.triangle"
        case .report: "doc.richtext"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: InspectionModel
    @State private var sidebar: SidebarItem = .camera
    @State private var colWidth: CGFloat? = 220
    @State private var showCalib = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebarList
                .navigationSplitViewColumnWidth(min: 180, ideal: colWidth ?? 220, max: 320)
        } detail: {
            detailView
        }
        .frame(minWidth: 1000, minHeight: 680)
        .sheet(isPresented: $showCalib) { CalibSheet(engine: model.engine) }
        .onChange(of: model.calibRequested) { _, v in
            guard v else { return }
            showCalib = true
            model.calibRequested = false
        }
        .onChange(of: model.closeWindowRequested) { _, v in
            guard v else { return }
            model.closeWindowRequested = false
            model.flushSaveOrCancel { NSApp.keyWindow?.performClose(nil) }
        }
        .alert(item: $model.lastError) { err in alertFor(err) }
        .onChange(of: model.mode) { _, m in
            sidebar = m == .camera ? .camera : (m == .report ? .report : .snapshots)
        }
    }

    func alertFor(_ err: AppError) -> Alert {
        let msg = err.userText + "\n\n" + err.savedDataText + "\n" + err.actionText
        return Alert(title: Text("Ошибка"), message: Text(msg),
                     dismissButton: .default(Text("Понятно")))
    }

    var detailView: some View {
        let showTable = model.showMeasureTable
        return VStack(spacing: 0) {
            mainArea
            if showTable {
                Divider()
                measurementsTable
            }
        }
        .toolbar { toolbarContent }
        .inspector(isPresented: $model.showInspector) { inspectorPane }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
    }

    // MARK: sidebar (NAV-02)

    private var sidebarList: some View {
        List(selection: $sidebar) {
            Section("Источник") {
                Label(SidebarItem.camera.label, systemImage: SidebarItem.camera.symbol)
                    .tag(SidebarItem.camera)
                Button {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.data, .init(filenameExtension: "seekscan") ?? .data]
                    if p.runModal() == .OK, let u = p.url { model.open(url: u) }
                } label: { Label(SidebarItem.importFile.label, systemImage: SidebarItem.importFile.symbol) }
            }
            Section("Обследование") {
                ForEach([SidebarItem.details, .snapshots, .equipment, .defects, .report]) { it in
                    Label(it.label, systemImage: it.symbol).tag(it)
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: sidebar) { _, s in
            switch s {
            case .camera: model.mode = .camera
            case .report: model.mode = .report
            case .snapshots, .details, .equipment, .defects: model.mode = .analysis
            case .importFile: break
            }
        }
        .symbolRenderingMode(.monochrome)
    }

    // MARK: центр

    @ViewBuilder private var mainArea: some View {
        switch sidebar {
        case .camera, .snapshots:
            // канвас + шкала = одна группа ровно в пропорции кадра, по центру области
            GeometryReader { geo in
                let ratio = model.imageRotation % 180 == 0 ? 320.0 / 240.0 : 240.0 / 320.0
                let availH = max(geo.size.height - 16, 120)
                let availW = max(geo.size.width - 16 - 96, 160)
                let w = min(availH * ratio, availW)
                HStack(spacing: 8) {
                    ThermogramCanvas(model: model)
                        .frame(width: w, height: w / ratio)
                        .background(Color(nsColor: .windowBackgroundColor))
                    TempScaleBar(model: model)
                        .frame(height: w / ratio)
                }
                .padding(8)                                   // рамка вплотную к видео+шкале
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .underPageBackgroundColor))
                )
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
                .frame(width: geo.size.width, height: geo.size.height)  // группа по центру области
            }
            .padding(8)
            .overlay(alignment: .topLeading) {
                if let f = model.selectedFrame, model.mode != .camera {
                    Text("Снимок \(f.hostTimestamp.formatted(date: .omitted, time: .standard)) · frame \(f.sessionFrameId)")
                        .font(.caption).padding(6)
                        .background(.windowBackground, in: RoundedRectangle(cornerRadius: 6))
                        .padding(14)
                }
            }
        case .details:
            DetailsPage()
        case .equipment:
            EquipmentPage()
        case .defects:
            DefectsPage()
        case .importFile:
            SnapshotGallery()
        case .report:
            ReportPanel()
        }
    }

    // MARK: toolbar (NAV-04/05)

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("Режим", selection: $model.mode) {
                ForEach(AppMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Камера / Анализ / Отчёт (данные не теряются)")
        }

        ToolbarItemGroup {
            Menu {
                ForEach(DrawTool.allCases, id: \.self) { t in
                    Button(t.rawValue) {
                        model.tool = model.tool == t ? nil : t
                    }
                }
                Divider()
                Button("Разность выбранных двух") { model.makeDiff() }
                    .disabled(model.selection.count != 2)
                Button("Удалить выбранное", action: model.deleteSelected)
                    .disabled(model.selection.isEmpty)
            } label: {
                Label("Измерения", systemImage: model.tool?.symbolName ?? "scope")
            }
            .help("Инструменты измерений")

            Button {
                model.takeSnapshot()
            } label: { Label("Снимок", systemImage: "camera.fill") }
                .disabled(model.acquisition != .streaming && !model.engine.isFrozen)
                .help("Зафиксировать кадр в документ (⌘3; ⌘S — сохранение документа)")

            Button {
                model.engine.setFrozen(!model.engine.isFrozen)
            } label: {
                Label("Заморозка", systemImage: model.engine.isFrozen ? "play.fill" : "pause.fill")
            }
            .help("Пауза просмотра (поток продолжает считываться)")

            Menu {
                ForEach(model.engine.palettes, id: \.1) { (name, v) in
                    Button(name) { model.palette = Int(v) }
                }
            } label: { Label("Палитра", systemImage: "paintpalette") }

            Menu {
                Button("Автодиапазон") { model.setSpanAuto() }
                Divider()
                Text("Ручной: задайте в инспекторе")
            } label: { Label("Диапазон", systemImage: "slider.horizontal.below.rectangle") }

            Button { showCalib = true } label: { Label("Калибровка Планка", systemImage: "target") }
                .disabled(!model.engine.isSessionOpen)
                .help("Двухточечная калибровка по чёрным телам (⌘⇧K)")

            Menu {
                Button("PDF-отчёт…") { model.exportPDF() }
                Button("PNG с оформлением…") { model.exportPNG() }
                Button("CSV измерений…") { model.exportCSV() }
                Button("Температурная матрица (.f64)…") { model.exportTempMatrix() }
            } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }

            Button {
                model.showInspector.toggle()
            } label: { Label("Инспектор", systemImage: "sidebar.right") }
        }
    }

    // MARK: низ — таблица измерений (NAV-01) + статус

    private var measurementsTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Измерения (\(model.measurements.count))").font(.caption.bold())
                Spacer()
                Toggle("Таблица", isOn: $model.showMeasureTable).toggleStyle(.button).controlSize(.mini)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Table(model.measurements, selection: $model.selection) {
                TableColumn("Название") { m in Text(m.name) }
                TableColumn("Тип") { m in Text(m.kind.rawValue) }
                    .width(70)
                TableColumn("Геометрия") { m in
                    Text(m.kind == .diff ? "Δ(\(short(m.aId)) − \(short(m.bId)))"
                         : m.kind == .point ? "(\(m.x0),\(m.y0))"
                         : "(\(m.x0),\(m.y0))–(\(m.x1),\(m.y1))")
                        .font(.system(size: 11, design: .monospaced))
                }
                TableColumn("Tmin") { m in statCell(model.stats(for: m).tMin) }.width(80)
                TableColumn("Tmax") { m in statCell(model.stats(for: m).tMax) }.width(80)
                TableColumn("Tmean") { m in statCell(model.stats(for: m).tMean) }.width(80)
                TableColumn("Пиксели") { m in
                    let s = model.stats(for: m)
                    Text(s.hasData ? "\(s.validCount)" : "нет данных")
                        .foregroundColor(s.hasData ? .primary : .secondary)
                }
                .width(80)
            }
            .contextMenu(forSelectionType: Measurement.self) { ids in
                Button("Удалить") { model.selection = Set(ids.map { $0.id }); model.deleteSelected() }
                    .disabled(ids.isEmpty)
                Button("Скрыть/показать") {
                    for i in model.measurements.indices where ids.contains(where: { $0.id == model.measurements[i].id }) {
                        model.measurements[i].visible.toggle()
                    }
                    model.markDirty()
                }
            } primaryAction: { _ in
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 90, maxHeight: 220)
        }
    }

    private func short(_ id: UUID?) -> String {
        guard let id = id, let m = model.measurements.first(where: { $0.id == id }) else { return "?" }
        return m.name
    }
    @ViewBuilder private func statCell(_ t: Double?) -> some View {
        if let t = t {
            Text(model.units.format(t)).font(.system(size: 11, design: .monospaced))
        } else {
            Text("—").foregroundColor(.secondary)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            // CAM: критический статус НЕ только здесь (дублируется в alert и заголовке)
            acquisitionBadge
            Text("кадр/с доставки \(String(format: "%.1f", model.engine.fps))")
                .foregroundColor(.secondary)
            Text(model.minMaxText).foregroundColor(.secondary)
            if let h = model.hover {
                Text("x=\(h.x) y=\(h.y) · \(model.hoverTemp(x: h.x, y: h.y))")
                    .font(.system(size: 11, design: .monospaced))
            }
            Spacer()
            if model.isDirty { Text("● несохранено").foregroundColor(.orange) }
            if !model.capabilities.supportsVisibleImage {
                Text("видеокадры: нет видимой камеры").foregroundColor(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder private var acquisitionBadge: some View {
        switch model.acquisition {
        case .streaming:
            HStack(spacing: 4) { Circle().fill(.green).frame(width: 7, height: 7); Text("LIVE") }
                .foregroundColor(.green)
        case .connecting: ProgressView().controlSize(.small).help("Подключение…")
        case .initializing: HStack(spacing: 4) { ProgressView().controlSize(.small); Text("инициализация") }
        case .error(let e):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(e).lineLimit(1)
                Button("Повтор") { model.retry() }.controlSize(.mini)
            }
        case .disconnecting: Text("отключение…").foregroundColor(.secondary)
        case .notConnected:
            HStack(spacing: 4) {
                Image(systemName: "cable.connector").foregroundColor(.secondary)
                Text("камера не подключена")
                Button("Подключить") { model.connect() }.controlSize(.mini)
            }
        }
    }

    // inspector справа
    private var inspectorPane: some View {
        InspectorPane()
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
}

extension DrawTool { var symbolName: String {
    switch self { case .point: "largecircle.fill.circle"; case .rect: "rectangle"; case .line: "line.diagonal" }
} }


// Скрытие штатного заголовка NSWindow (Title), чтобы центральный Text был единственным.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let w = v.window { w.titleVisibility = .hidden }
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let w = v.window { w.titleVisibility = .hidden }
    }
}
