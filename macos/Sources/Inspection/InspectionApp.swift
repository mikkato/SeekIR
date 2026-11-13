// InspectionApp.swift — точка входа macOS 26+ приложения (ARC-01: SwiftUI-сцены +
// AppKit-компоненты; Liquid Glass — системными компонентами), меню (MENU), настройки (SET).
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct SeekIRInspectionApp: App {
    @StateObject private var model = InspectionModel()
    @StateObject private var settings = SettingsModel()

    init() {}

    var body: some Scene {
        WindowGroup("Термография") {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
                .onAppear {
                    model.start()
                    ForceFrontWindow.bring()   // окно иногда рождается невидимым
                }
                .onDisappear { model.disconnect() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            // Файл (MENU-02)
            CommandGroup(replacing: .newItem) {
                Button("Новое обследование") { model.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Открыть…") { model.openViaPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Сохранить обследование") {
                    if model.docURL == nil { model.saveAs() } else { model.save() }
                }
                .keyboardShortcut("s", modifiers: .command)
                Button("Сохранить как…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Снимок с камеры") { model.takeSnapshot() }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Закрыть") { model.closeWindowRequested = true }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .undoRedo) {
                Button("Разность выбранных двух") { model.makeDiff() }
                    .disabled(model.selection.count != 2)
                Button("Удалить измерения") { model.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
            }
            // Вид (встроен в системное меню «Вид», без дубля)
            CommandGroup(after: .sidebar) {
                Picker("Единицы", selection: $model.units) {
                    Text("°C").tag(DisplayUnits.celsius)
                    Text("°F").tag(DisplayUnits.fahrenheit)
                    Text("K").tag(DisplayUnits.kelvin)
                }
                Divider()
                ForEach(AppMode.allCases, id: \.self) { m in
                    Button(m.rawValue) { model.mode = m }
                        .keyboardShortcut(KeyEquivalent(m.shortcut),
                                          modifiers: [.command, .control])
                }
                Divider()
                Toggle("Таблица измерений", isOn: $model.showMeasureTable)
                Toggle("Инспектор", isOn: $model.showInspector)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Вписать") { model.zoom = 1; model.pan = .zero }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Приблизить") { model.zoom = min(model.zoom * 1.4, 16) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Отдалить") { model.zoom = max(model.zoom / 1.4, 0.5) }
                    .keyboardShortcut("-", modifiers: .command)
            }
            // Камера
            CommandMenu("Камера") {
                Button("Подключить") { model.connect() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.acquisition == .streaming || model.acquisition == .connecting)
                Button("Отключить") { model.disconnect() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Повторное подключение") { model.retry() }
                    .keyboardShortcut("r", modifiers: [.command, .control])
                Divider()
                Button("Снимок в документ") { model.takeSnapshot() }
                    .keyboardShortcut("3", modifiers: .command)
                Button(model.engine.isFrozen ? "Продолжить просмотр" : "Заморозить просмотр") {
                    model.engine.setFrozen(!model.engine.isFrozen)
                }
                .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("Калибровка Планка…") { model.calibRequested = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Menu("Палитра") {
                    ForEach(model.engine.palettes, id: \.1) { (n, v) in
                        Button(n) { model.palette = Int(v) }
                    }
                }
            }
            // Измерения
            CommandMenu("Измерения") {
                ForEach(DrawTool.allCases, id: \.self) { t in
                    Button(t.rawValue) { model.tool = model.tool == t ? nil : t }
                        .keyboardShortcut(KeyEquivalent(t.shortcut), modifiers: .command)
                }
                Divider()
                Button("Удалить выбранное") { model.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Отменить") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button("Повторить") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            // Справка + диагностика (ERR-04)
            CommandGroup(replacing: .help) {
                Button("Диагностика: экспорт журнала…") { model.exportDiagnosticsPanel() }
                Button("О приложении") { model.showAbout() }
            }
        }
        // Настройки (SET-01; условия обследования — не глобальные)
        Settings {
            SettingsView(settings: settings)
                .environmentObject(model)
        }
    }
}

extension AppMode {
    var shortcut: Character {
        switch self { case .camera: "1"; case .analysis: "2"; case .report: "3" }
    }
}
extension DrawTool {
    var shortcut: Character {
        switch self { case .point: "p"; case .rect: "u"; case .line: "l" }
    }
}

// MARK: — Настройки (UserDefaults; интернет/аккаунт/телеметрия не нужны — SET-02) —

final class SettingsModel: ObservableObject {
    @AppStorage("units") var units: Int = 0
    @AppStorage("palette") var palette: Int = 0
    @AppStorage("defaultScale") var defaultScale: String = "C"
    @AppStorage("exportPath") var exportPath: String = ""
    @AppStorage("autosave") var autosave: Bool = true
    @AppStorage("diagnostics") var diagnostics: Bool = true
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @EnvironmentObject var model: InspectionModel
    var body: some View {
        TabView {
            Form {
                Picker("Единицы отображения", selection: $settings.units) {
                    Text("°C").tag(0); Text("°F").tag(1); Text("K").tag(2)
                }
                Picker("Палитра по умолчанию", selection: $settings.palette) {
                    Text("Ironbow").tag(0); Text("Ironbow2").tag(1); Text("Rainbow").tag(2)
                    Text("Arctic").tag(3); Text("White Hot").tag(4); Text("Black Hot").tag(5)
                    Text("Lava").tag(6); Text("Jet").tag(7); Text("Medical").tag(8)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Интерфейс", systemImage: "slider.horizontal.3") }

            Form {
                TextField("Каталог экспорта по умолчанию", text: $settings.exportPath)
                Toggle("Автосохранение черновика обследования", isOn: $settings.autosave)
                Toggle("Вести диагностический журнал", isOn: $settings.diagnostics)
                Text("Приложение работает без интернета, аккаунта и телеметрии.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Экспорт и данные", systemImage: "square.and.arrow.up") }

            Form {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Сглаживание (доля свежего кадра в покое): %.2f",
                                model.engine.smooth))
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { model.engine.smooth }, set: { model.engine.smooth = $0 }), in: 0.05...1.0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Порог движения (дельта, dilate 3×3): \(model.engine.motion)")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(model.engine.motion) },
                                          set: { model.engine.motion = Int($0) }),
                           in: 60...600)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Зачистка шума (позиция гейта границ): \(model.engine.spatial)")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(model.engine.spatial) },
                                          set: { model.engine.spatial = Int($0) }),
                           in: 5...80)
                }
                HStack {
                    Button("Сбросить к baseline (0.75 / 440 / 75)") {
                        model.engine.smooth = 0.75; model.engine.motion = 440; model.engine.spatial = 75
                        if model.engine.connected { model.engine.applyDenoise() }
                    }
                    Spacer()
                    Button("Применить к камере") {
                        if model.engine.connected { model.engine.applyDenoise() }
                    }
                    .disabled(!model.engine.connected)
                }
                Text("Применяется ядром к живому потоку (F9): ↑ сглаживание = меньше шум, больше шлейф; "
                     + "↑ порог движения = шум не имитирует движение; ↑ зачистка = шире гладкие зоны. "
                     + "На измеренные температуры снимка не влияет (применяется до пересчёта).")
                    .font(.caption).foregroundColor(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Постобработка", systemImage: "waveform.path") }
            .onChange(of: model.engine.smooth) { _ in if model.engine.connected { model.engine.applyDenoise() } }
            .onChange(of: model.engine.motion) { _ in if model.engine.connected { model.engine.applyDenoise() } }
            .onChange(of: model.engine.spatial) { _ in if model.engine.connected { model.engine.applyDenoise() } }
        }
        .frame(width: 520, height: 330)
    }
}


// Аварийный вывод окна на экран: SwiftUI-окно регистрируется в AppKit
// (видно в меню «Окно»), но до WindowServer не доходит — показываем вручную.
enum ForceFrontWindow {
    static func bring() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            for w in NSApp.windows {
                guard w.styleMask.contains(.titled), !(w is NSPanel) else { continue }
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.titleVisibility = .visible
                w.toolbarStyle = .expanded    // заголовок по центру строкой выше кнопок
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
            // повторить после сборки тулбара AppKit
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                for w in NSApp.windows where w.styleMask.contains(.titled) && !(w is NSPanel) {
                    w.titleVisibility = .visible
                    w.toolbarStyle = .expanded
                }
            }
        }
    }
}
