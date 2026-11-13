// Inspector.swift — инспектор справа (NAV-06: свойства выбора, иначе свойства кадра),
// страницы Сведения/Оборудование/Дефекты, галерея импорта.
import SwiftUI
import AppKit

struct InspectorPane: View {
    @EnvironmentObject var model: InspectionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let id = model.selection.first,
                   let m = model.measurements.first(where: { $0.id == id }) {
                    measurementSection(m)
                }
                frameSection
                viewSection
                sceneSection
                metadataSection
            }
            .padding(12)
        }
    }

    // — свойства выбранного измерения —
    // Binding по id, НЕ по индексу: индекс, захваченный в $measurements[idx],
    // вычисляется лениво при update() и падает после удаления строки (SIGTRAP).
    private func mBind<T>(_ id: UUID, _ keyPath: WritableKeyPath<Measurement, T>) -> Binding<T> {
        Binding(
            get: { model.measurements.first(where: { $0.id == id }).map { $0[keyPath: keyPath] } ?? defaultFor(keyPath) },
            set: { nv in
                if let i = model.measurements.firstIndex(where: { $0.id == id }) {
                    model.measurements[i][keyPath: keyPath] = nv
                    model.markDirty()
                }
            })
    }
    private func defaultFor<T>(_ keyPath: WritableKeyPath<Measurement, T>) -> T {
        if T.self == String.self { return "" as! T }
        if T.self == Bool.self { return false as! T }
        if T.self == UUID?.self { return ((nil as UUID?) as! T) }
        return model.measurements.first?[keyPath: keyPath] ?? (0 as! T)
    }

    @ViewBuilder private func measurementSection(_ m: Measurement) -> some View {
        GroupBox("Измерение: \(m.name)") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Название", text: mBind(m.id, \Measurement.name))
                Toggle("Виден на термограмме", isOn: mBind(m.id, \Measurement.visible))
                ColorPicker("Цвет", selection: Binding(
                    get: { Color(NSColor(hex: mBind(m.id, \Measurement.colorHex).wrappedValue)) },
                    set: { c in mBind(m.id, \Measurement.colorHex).wrappedValue = NSColor(c).hexString }))
                Picker("Оборудование", selection: mBind(m.id, \Measurement.equipmentId)) {
                    Text("—").tag(UUID?.none)
                    ForEach(model.doc.meta.equipment) { e in
                        Text(e.name.isEmpty ? e.cell : e.name).tag(UUID?.some(e.id))
                    }
                }
                TextField("Комментарий", text: mBind(m.id, \Measurement.comment), axis: .vertical)
                    .lineLimit(2...4)
                let s = model.stats(for: m)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    statRow("Пиксели валидных", s.hasData ? "\(s.validCount)" : "нет данных")
                    statRow("Tmin", s.tMin.map { model.units.format($0) } ?? "—")
                    statRow("Tmax", s.tMax.map { model.units.format($0) } ?? "—")
                    statRow("Tmean", s.tMean.map { model.units.format($0) } ?? "—")
                    if let xy = s.maxXY { statRow("Коорд. макс", "(\(xy.x),\(xy.y))") }
                    if let xy = s.minXY { statRow("Коорд. мин", "(\(xy.x),\(xy.y))") }
                }
                .font(.system(size: 11, design: .monospaced))
            }
            .padding(4)
        }
    }
    private func statRow(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundColor(.secondary); Text(v) }
    }

    // — свойства кадра (общие, если нет selection) —
    @ViewBuilder private var frameSection: some View {
        GroupBox(model.selection.isEmpty ? "Кадр" : "Текущий кадр") {
            VStack(alignment: .leading, spacing: 4) {
                if let f = model.selectedFrame, model.mode != .camera {
                    infoLine("Источник", "снимок документа")
                    infoLine("Время (host)", f.hostTimestamp.formatted())
                    infoLine("frameID", "\(f.sessionFrameId)")
                    infoLine("Матрица", "\(f.width)×\(f.height) \(f.dataKind)")
                    infoLine("Единицы", f.temperatureUnit + " (единицы ядра)")
                    infoLine("Правило валидности", f.validityRule)
                    infoLine("Палитра", model.engine.palettes.indices.contains(f.palette)
                             ? model.engine.palettes[f.palette].0 : "\(f.palette)")
                } else if model.acquisition == .streaming {
                    infoLine("Источник", "live-поток PIR324")
                    infoLine("Время", "host (устройство время не передаёт)")
                } else {
                    Text("Кадр недоступен — подключите камеру или откройте документ")
                        .foregroundColor(.secondary)
                }
            }
            .padding(4)
        }
    }
    private func infoLine(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).foregroundColor(.secondary); Spacer(minLength: 4); Text(v)
                .textSelection(.enabled)
        }.font(.system(size: 11))
    }

    // — параметры отображения (отдельно от расчётных — MEAS-08/VIEW-02) —
    @ViewBuilder private var viewSection: some View {
        GroupBox("Отображение") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Единицы", selection: $model.units) {
                    Text("°C").tag(DisplayUnits.celsius)
                    Text("°F").tag(DisplayUnits.fahrenheit)
                    Text("K").tag(DisplayUnits.kelvin)
                }
                Picker("Палитра", selection: $model.palette) {
                    ForEach(model.engine.palettes, id: \.1) { (n, v) in
                        Text(n).tag(Int(v))
                    }
                }
                .onChange(of: model.palette) { _, v in
                    UserDefaults.standard.set(v, forKey: "palette")
                }
                Picker("Поворот изображения", selection: $model.imageRotation) {
                    Text("0°").tag(0)
                    Text("90° против часовой").tag(90)
                    Text("180°").tag(180)
                    Text("270° против часовой").tag(270)
                }
                Toggle("Растянуть кадр на всю область", isOn: $model.stretchFill)
                Toggle("Без сглаживания (пиксельно)", isOn: $model.nearestFilter)
                Toggle("Автодиапазон", isOn: Binding(
                    get: { model.spanAuto }, set: { $0 ? model.setSpanAuto() : () }))
                HStack {
                    TextField("ниже", value: $model.spanLo, format: .number)
                        .disabled(model.spanAuto)
                    TextField("выше", value: $model.spanHi, format: .number)
                        .disabled(model.spanAuto)
                }
                HStack {
                    Text("сигнал, counts").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button("Применить") { model.setSpanManual(lo: model.spanLo, hi: model.spanHi) }
                        .fixedSize().disabled(model.spanAuto)
                }
                Text("Палитра/диапазон/сглаживание не меняют температуры (VIEW-02).")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(4)
        }
    }

    // — параметры ядра (реально поддержаны: skcap_set_scene) —
    @ViewBuilder private var sceneSection: some View {
        GroupBox("Условия измерения (ядро применяет)") {
            VStack(alignment: .leading, spacing: 6) {
                stepper("ε излучательная способность", value: $model.currentScene.emissivity,
                        in: 0.01...1.0, step: 0.01)
                stepper("Отражённая, °C", value: $model.currentScene.tReflC,
                        in: (-40)...80, step: 1)
                stepper("Воздух, °C", value: $model.currentScene.tAtmC, in: (-40)...60, step: 1)
                stepper("Дистанция, м", value: $model.currentScene.distanceM, in: 0.05...30, step: 0.05)
                stepper("Влажность, %", value: $model.currentScene.relHumidity, in: 0...100, step: 1)
                Text("Влияют на температурную матрицу ядра; фиксируются в метаданных снимка. "
                     + "Условия конкретного обследования — в разделе «Сведения».")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(4)
        }
    }
    private func stepper(_ label: String, value: Binding<Double>,
                         in range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).font(.system(size: 11))
                Spacer()
                TextField("", value: value, format: .number).frame(width: 60)
                    .multilineTextAlignment(.trailing)
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.mini)
                .onChange(of: value.wrappedValue) { _, _ in model.applyScene() }
        }
    }

    private var metadataSection: some View {
        GroupBox("Метаданные ядра") {
            VStack(alignment: .leading, spacing: 4) {
                let p = model.currentPlanckForUI
                infoLine("Планк r1", String(format: "%.6g", p.r1))
                infoLine("Планк b/f", String(format: "%.6g / %.6g", p.b, p.f))
                infoLine("Планк r2/o", String(format: "%.6g / %.6g", p.r2, p.o))
                infoLine("Калибровка", model.calibratedText)
            }
            .padding(4)
        }
    }
}

// MARK: — страница «Сведения» (DOC-02/DOC-03) —

struct DetailsPage: View {
    @EnvironmentObject var model: InspectionModel
    var body: some View {
        Form {
            Section("Обследование") {
                TextField("Название", text: $model.doc.meta.title)
                TextField("Площадка", text: $model.doc.meta.site)
                TextField("Исполнитель", text: $model.doc.meta.inspector)
                TextField("Примечание", text: $model.doc.meta.note, axis: .vertical)
            }
            Section("Условия (неизвестное оставляйте пустым)") {
                optionalField("Температура воздуха, °C", value: $model.doc.meta.conditions.tAirC)
                optionalField("Ток фаза A, А", value: $model.doc.meta.conditions.currentA)
                optionalField("Ток фаза B, А", value: $model.doc.meta.conditions.currentB)
                optionalField("Ток фаза C, А", value: $model.doc.meta.conditions.currentC)
                optionalField("Напряжение, В", value: $model.doc.meta.conditions.voltage)
                optionalField("Мощность, кВт", value: $model.doc.meta.conditions.powerKW)
                optionalField("Номинальный ток, А", value: $model.doc.meta.conditions.nominalCurrent)
                optionalField("Номинальное напряжение, В", value: $model.doc.meta.conditions.nominalVoltage)
                DatePicker("Время регистрации нагрузки",
                           selection: Binding(get: { model.doc.meta.conditions.loadTime ?? Date() },
                                              set: { model.doc.meta.conditions.loadTime = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
                TextField("Комментарий", text: $model.doc.meta.conditions.comment, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.doc.meta) { _, _ in model.markDirty() }
    }
    private func optionalField(_ label: String, value: Binding<Double?>) -> some View {
        HStack {
            Text(label)
            TextField("—", value: Binding(get: { value.wrappedValue ?? 0 },
                                          set: { value.wrappedValue = $0 }),
                      format: .number)
                .frame(width: 110)
                .multilineTextAlignment(.trailing)
            Button("Сброс") { value.wrappedValue = nil }.controlSize(.mini)
        }
    }
}

// MARK: — Оборудование —

struct EquipmentPage: View {
    @EnvironmentObject var model: InspectionModel
    var body: some View {
        VStack {
            Table(model.doc.meta.equipment) {
                TableColumn("Название") { e in
                    let i = model.doc.meta.equipment.firstIndex(where: { $0.id == e.id }) ?? 0
                    TextField("", text: $model.doc.meta.equipment[i].name)
                }
                TableColumn("Ячейка/шкаф") { e in
                    let i = model.doc.meta.equipment.firstIndex(where: { $0.id == e.id }) ?? 0
                    TextField("", text: $model.doc.meta.equipment[i].cell)
                }
                .width(120)
                TableColumn("Фаза") { e in
                    let i = model.doc.meta.equipment.firstIndex(where: { $0.id == e.id }) ?? 0
                    TextField("", text: $model.doc.meta.equipment[i].phase)
                }
                .width(70)
            }
            HStack {
                Button("Добавить") {
                    model.doc.meta.equipment.append(Equipment(name: "Оборудование \(model.doc.meta.equipment.count + 1)"))
                    model.markDirty()
                }
                Button("Удалить выбранное") {
                    model.doc.meta.equipment.removeAll { model.selectedEquipment.contains($0.id) }
                    model.markDirty()
                }
                Spacer()
            }.padding(.horizontal, 8).padding(.bottom, 6)
        }
        .onChange(of: model.doc.meta.equipment) { _, _ in model.markDirty() }
    }
}

// MARK: — Дефекты (REP-01) —

struct DefectsPage: View {
    @EnvironmentObject var model: InspectionModel
    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedDefectId) {
                ForEach(model.defects) { d in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(d.status == .fixed ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(d.nodeName.isEmpty ? "Дефект" : d.nodeName)
                            Text(d.observation).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(d.status.rawValue).font(.caption2)
                    }.tag(d.id)
                }
                .onDelete { idx in
                    model.defects.remove(atOffsets: idx); model.markDirty()
                }
            }
            if let id = model.selectedDefectId,
               let i = model.defects.firstIndex(where: { $0.id == id }) {
                Divider()
                Form {
                    TextField("Узел", text: $model.defects[i].nodeName)
                    Picker("Оборудование", selection: $model.defects[i].equipmentId) {
                        Text("—").tag(UUID?.none)
                        ForEach(model.doc.meta.equipment) { e in
                            Text(e.name).tag(UUID?.some(e.id))
                        }
                    }
                    TextField("Наблюдение (факт)", text: $model.defects[i].observation, axis: .vertical)
                    TextField("Предполагаемая причина (гипотеза)",
                              text: $model.defects[i].suspectedCause, axis: .vertical)
                    TextField("Оценка инженера", text: $model.defects[i].engineerAssessment, axis: .vertical)
                    TextField("Рекомендации", text: $model.defects[i].recommendation, axis: .vertical)
                    HStack {
                        TextField("Ответственный", text: $model.defects[i].assignee)
                        Picker("Статус", selection: $model.defects[i].status) {
                            ForEach(Defect.Status.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .frame(width: 140)
                    }
                }
                .formStyle(.columns)
                .padding(8)
            }
            HStack {
                Button("Новый дефект") {
                    model.defects.append(Defect(nodeName: "Дефект \(model.defects.count + 1)"))
                    model.markDirty()
                }
                Spacer()
            }.padding(8)
        }
        .onChange(of: model.defects) { _, _ in model.markDirty() }
    }
}

// MARK: — Импорт PNG16 (ре-радиометрия сигнальных снимков E2) —

struct SnapshotGallery: View {
    @EnvironmentObject var model: InspectionModel
    var body: some View {
        VStack {
            Button("Импортировать PNG16 сигнала…") { model.importPNG16() }
                .padding(.top, 16)
            Text("Импорт читает 16-битный сигнал (snap-*.png из ~/Pictures/SeekIR), пересчитывает температуры текущей калибровкой ядра и добавляет кадр в документ. Температуры будут помечены как пересчитанные.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 40)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 10) {
                    ForEach(model.engine.shots.filter { !$0.isVideo }) { s in
                        VStack {
                            AsyncImage(url: s.url) { img in
                                img.resizable().scaledToFit()
                            } placeholder: { Color.gray.opacity(0.2) }
                                .frame(height: 135).clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(s.url.lastPathComponent).font(.caption2).lineLimit(1)
                        }
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(s.url) }
                        .contextMenu {
                            Button("Импортировать в документ") { model.importPNG16(url: s.url) }
                            Button("Показать в Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([s.url])
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .onAppear { model.engine.refreshGallery() }
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "FFD60A" }
        return String(format: "%02X%02X%02X",
                      Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}
