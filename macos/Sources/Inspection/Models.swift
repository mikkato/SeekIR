// Models.swift — доменные модели обследования (только Foundation — общо с тестами).
import Foundation

// MARK: — Документ обследования (DOC-01…DOC-08) —

struct ScanDocument: Codable {
    var schemaVersion: Int = 1
    var docId: UUID = UUID()
    var created: Date = Date()
    var modified: Date = Date()
    var appVersion: String = "1.0-P0"
    var coreVersion: String = "E1 bit-exact"
    var meta: ScanMeta = ScanMeta()
}

struct ScanMeta: Codable, Equatable {
    var title: String = ""            // название обследования
    var site: String = ""             // площадка
    var inspector: String = ""        // исполнитель
    var note: String = ""
    var conditions: Conditions = Conditions()
    var equipment: [Equipment] = []
}

struct Equipment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var cell: String = ""             // ячейка/шкаф
    var phase: String = ""            // А/В/С/—
    var note: String = ""
}

/// Условия обследования (DOC-03). Неизвестное остаётся nil — не подменяется нулём.
struct Conditions: Codable, Equatable {
    var tAirC: Double?                // температура воздуха, °C
    var currentA: Double?             // токи фаз, А
    var currentB: Double?
    var currentC: Double?
    var voltage: Double?              // В
    var powerKW: Double?              // активная мощность, кВт
    var nominalCurrent: Double?
    var nominalVoltage: Double?
    var loadTime: Date?               // время регистрации нагрузки
    var comment: String = ""
}

// MARK: — Кадр (DATA-01) —

/// dataKind фиксирован ядром: температура + сигнал + рендер (см. core-audit AUD-04).
struct FrameSnapshot: Codable, Identifiable {
    var id: UUID = UUID()
    var sessionFrameId: Int = -1      // счётчик кадров сессии skcap (word[1] в API нет)
    var hostTimestamp: Date = Date()  // время host; время устройству недоступно (DATA-02)
    var width: Int = 320
    var height: Int = 240
    var dataKind: String = "temperature+signal+render"
    var temperatureUnit: String = "C"
    var temp: [Double] = []           // °C, row-major, валидность: > -270 и !NaN
    var signal: [UInt16] = []         // counts, row-major
    var rgb: [UInt8] = []             // 320×240×3, рендер ядра (палитра/span на момент кадра)
    var spanLo: Double = 0            // применённый span (counts)
    var spanHi: Double = 0
    var palette: Int = 0
    var planck: PlanckValues = PlanckValues()
    var scene: SceneValues = SceneValues()
    var denoise: DenoiseValues = DenoiseValues()
    var validityRule: String = "t <= -270 C or NaN => invalid"

    var hasTemperature: Bool { !temp.isEmpty }
}

struct PlanckValues: Codable, Equatable { var r1 = 0.0, b = 0.0, f = 0.0, o = 0.0, r2 = 0.0 }
struct SceneValues: Codable, Equatable {
    var emissivity = 0.95, tReflC = 20.0, tAtmC = 20.0, distanceM = 1.0, relHumidity = 50.0
}
struct DenoiseValues: Codable, Equatable { var smooth = 0.75, motion = 440, spatial = 75 }

// MARK: — Измерения (MEAS-01…MEAS-08) —

enum MeasureKind: String, Codable { case point, rect, line, diff }

struct Measurement: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var kind: MeasureKind
    var name: String = ""
    // геометрия в координатах МАТРИЦЫ 320×240 (VIEW-03); diff геометрию не имеет
    var x0: Int = 0
    var y0: Int = 0
    var x1: Int = 0                   // rect/line: второй конец ( нормализовано x0<=x1 )
    var y1: Int = 0
    var visible: Bool = true
    var colorHex: String = "FFD60A"   // жёлтый по умолчанию (значимый цвет + подпись)
    /// diff-пара (MEAS-01): id двух измерений
    var aId: UUID?
    var bId: UUID?
    var frameId: UUID?                // снапшот-привязка (MEAS-07); live-инструменты — nil до снимка
    var equipmentId: UUID?
    var defectId: UUID?
    var comment: String = ""
    var created: Date = Date()

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func normalized() -> Measurement {
        var m = self
        if m.kind == .rect || m.kind == .line {
            if m.x1 < m.x0 { swap(&m.x0, &m.x1) }
            if m.y1 < m.y0 { swap(&m.y0, &m.y1) }
        }
        return m
    }
}

/// Результат измерения; пустая выборка — hasData=false, «Нет данных» (MEAS-06).
struct MeasureStats: Codable {
    var hasData: Bool = false
    var validCount: Int = 0
    var tMin: Double?
    var tMax: Double?
    var tMean: Double?
    var minXY: (x: Int, y: Int)?
    var maxXY: (x: Int, y: Int)?
    enum CodingKeys: String, CodingKey { case hasData, validCount, tMin, tMax, tMean }
    init() {}
    init(hasData: Bool, validCount: Int, tMin: Double?, tMax: Double?, tMean: Double?,
         minXY: (x: Int, y: Int)?, maxXY: (x: Int, y: Int)?) {
        self.hasData = hasData; self.validCount = validCount
        self.tMin = tMin; self.tMax = tMax; self.tMean = tMean
        self.minXY = minXY; self.maxXY = maxXY
    }
}

// MARK: — Дефекты (REP-01/REP-02) —

struct Defect: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case new = "Новый", inWork = "В работе", fixed = "Устранён", accepted = "Принят риск"
    }
    var id: UUID = UUID()
    var equipmentId: UUID?
    var nodeName: String = ""         // узел
    var frameIds: [UUID] = []
    var measurementIds: [UUID] = []
    var observation: String = ""      // наблюдение (факт)
    var suspectedCause: String = ""   // предполагаемая причина — ГИПОТЕЗА, не факт (REP-02)
    var engineerAssessment: String = ""
    var recommendation: String = ""
    var assignee: String = ""
    var dueDate: Date?
    var status: Status = .new
}

// MARK: — Состояния камеры (CAM-01) —

enum AcquisitionState: Equatable {
    case notConnected
    case connecting
    case initializing
    case streaming
    case error(String)
    case disconnecting

    var isLive: Bool { self == .streaming }
}

// MARK: — Единицы отображения (DATA-05: перевод не меняет матрицу) —

enum DisplayUnits: Int, Codable, CaseIterable {
    case celsius = 0, fahrenheit = 1, kelvin = 2

    func format(_ t: Double, digits: Int = 1) -> String {
        switch self {
        case .celsius:    return String(format: "%.\(digits)f °C", t)
        case .fahrenheit: return String(format: "%.\(digits)f °F", t * 9 / 5 + 32)
        case .kelvin:     return String(format: "%.\(digits)f K", t + 273.15)
        }
    }
    var suffix: String {
        switch self { case .celsius: "°C"; case .fahrenheit: "°F"; case .kelvin: "K" }
    }
}

// Правило валидности (AUD-04, MEAS-06) — ЕДИНСТВЕННЫЙ источник для кода и тестов.
@inline(__always) func tempIsValid(_ t: Double) -> Bool { !t.isNaN && t > -270.0 }

// MARK: — Ошибки (ERR-01/ERR-02) —

struct AppError: Error, Identifiable {
    enum Kind { case cameraAbsent, cameraBusy, initFailed, streamLost, noTemperature,
                 writeFailed, docCorrupt, docVersionNew }
    let id = UUID()
    let kind: Kind
    let userText: String       // что произошло (для человека)
    let savedDataText: String  // какие данные сохранены
    let actionText: String     // доступное действие
    var technical: String = "" // раскрываемые подробности
}
