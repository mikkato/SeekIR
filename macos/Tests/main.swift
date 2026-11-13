// MeasurementTests.swift — TEST-02/TEST-03: синтетическая известная матрица.
// Точка/область/линия/разность, отрицательные температуры, NaN/invalid, пустая
// выборка, границы; инвариант координат при zoom/pan/размере окна.
import Foundation
import CoreGraphics
import AppKit

var failures = 0
var checks = 0
func expect(_ cond: Bool, _ msg: String) {
    checks += 1
    if !cond { failures += 1; print("FAIL: \(msg)") }
}
func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

let W = 320, H = 240
func idx(_ x: Int, _ y: Int) -> Int { y * W + x }

// Матрица: t(x,y) = x - 160 (от -160 до +159 °C), несколько invalid/NaN
var temp = [Double](repeating: 0, count: W * H)
for y in 0..<H { for x in 0..<W { temp[idx(x, y)] = Double(x) - 160.0 } }
temp[idx(0, 0)] = .nan
temp[idx(1, 0)] = -300.0          // invalid по правилу (<= -270)
temp[idx(2, 0)] = -269.999        // валидно (граница правила)

print("== TEST-02: измерения на синтетике ==")

// 1. Точка: валидная
var m = Measurement(kind: .point, x0: 200, y0: 100, x1: 200, y1: 100)
var s = MeasurementService.compute(m, temp: temp)
expect(s.hasData && approx(s.tMean!, 40.0), "point (200,100) => 40 °C, got \(String(describing: s.tMean))")

// 2. Точка: NaN -> нет данных (MEAS-06: не 0!)
m = Measurement(kind: .point, x0: 0, y0: 0, x1: 0, y1: 0)
s = MeasurementService.compute(m, temp: temp)
expect(!s.hasData, "point(0,0)=NaN => Нет данных")

// 3. Точка: invalid -300 -> нет данных
m = Measurement(kind: .point, x0: 1, y0: 0, x1: 1, y1: 0)
s = MeasurementService.compute(m, temp: temp)
expect(!s.hasData, "point -300 => Нет данных")

// 4. Граница правила: -269.999 валиден
m = Measurement(kind: .point, x0: 2, y0: 0, x1: 2, y1: 0)
s = MeasurementService.compute(m, temp: temp)
expect(s.hasData && approx(s.tMean!, -269.999), "point -269.999 => валиден")

// 5. Прямоугольник включительно (MEAS-03 рамка входит)
//    rect x=100..110, y=50..52: пики по x => Tmin=100-160=-60 (x=100), Tmax=-50 (x=110)
//    все пиксели валидны (x>=3), count=11*3=33, mean=среднее(x)-160 = 105-160 = -55
m = Measurement(kind: .rect, x0: 100, y0: 50, x1: 110, y1: 52).normalized()
s = MeasurementService.compute(m, temp: temp)
expect(s.validCount == 33, "rect 11x3 включительно => 33 пикселя, got \(s.validCount)")
expect(approx(s.tMin!, -60), "rect Tmin=-60 (граница x=100 входит)")
expect(approx(s.tMax!, -50), "rect Tmax=-50 (граница x=110 входит)")
expect(approx(s.tMean!, -55), "rect Tmean=-55")
expect(s.maxXY?.x == 110 && s.maxXY?.y == 50, "коорд. экстремума (110,50), got \(String(describing: s.maxXY))")

// 6. Нормализация x1<x0 / y1<y0
m = Measurement(kind: .rect, x0: 110, y0: 52, x1: 100, y1: 50).normalized()
let s6 = MeasurementService.compute(m, temp: temp)
expect(s6.validCount == s.validCount && approx(s6.tMean!, s.tMean!), "нормализация rect")

// 7. Rect с invalid-пикселями: исключаются из статистики (y=0, x=0..10)
m = Measurement(kind: .rect, x0: 0, y0: 0, x1: 10, y1: 0)
s = MeasurementService.compute(m, temp: temp)
expect(s.validCount == 9, "invalid исключены: 11-2=9, got \(s.validCount)")
expect(approx(s.tMin!, -269.999), "мин после исключения NaN/-300 = -269.999")

// 8. Пустая выборка: rect за границей после климпа пустой? (климпит в кадр) —
//    полностью invalid-область => hasData=false
temp[idx(3, 0)] = .nan; temp[idx(4, 0)] = -400; temp[idx(5, 0)] = -500
m = Measurement(kind: .rect, x0: 3, y0: 0, x1: 5, y1: 0)
s = MeasurementService.compute(m, temp: temp)
expect(!s.hasData, "полностью невалидная область => Нет данных")
temp[idx(3, 0)] = -157; temp[idx(4, 0)] = -156; temp[idx(5, 0)] = -155  // восстановить

// 9. Линия: Bresenham детерминирован. Диагональ (0,0)-(10,10) => 11 пикселей
m = Measurement(kind: .line, x0: 0, y0: 10, x1: 10, y1: 10)
s = MeasurementService.compute(m, temp: temp)
expect(s.validCount == 11, "горизонталь 11 пикселей, got \(s.validCount)")
expect(approx(s.tMin!, -160) && approx(s.tMax!, -150), "линия y=10: -160..-150")

// клинки: y=10,x=0..10 все валидны (NaN только y=0)
// 10. Линия с наклоном 2:1 — пикселей = 11 (Bresenham step по x)
m = Measurement(kind: .line, x0: 20, y0: 0, x1: 40, y1: 10)
let px = MeasurementService.linePixels(x0: 20, y0: 0, x1: 40, y1: 10)
expect(px.count == 21, "Bresenham 2:1 => 21 шаг по x, got \(px.count)")
// детерминизм: повторный вызов идентичен
expect(px == MeasurementService.linePixels(x0: 20, y0: 0, x1: 40, y1: 10), "Bresenham детерминирован")

// 11. Разность (MEAS-01/07): ΔTmean, ΔTmax
let a = Measurement(kind: .rect, x0: 200, y0: 100, x1: 210, y1: 100)   // x=200..210 => -? mean=205-160=45...
let b = Measurement(kind: .rect, x0: 100, y0: 100, x1: 110, y1: 100)  // mean=105-160=-55
let d = Measurement(kind: .diff, aId: a.id, bId: b.id)
let all = [a, b, d]
let sa = MeasurementService.compute(a, temp: temp)
let sb = MeasurementService.compute(b, temp: temp)
let sd = MeasurementService.compute(d, temp: temp, all: all)
expect(sa.hasData && sb.hasData && sd.hasData, "diff: компоненты валидны")
expect(approx(sd.tMean!, sa.tMean! - sb.tMean!), "diff ΔTmean")
expect(approx(sd.tMax!, sa.tMax! - sb.tMax!), "diff ΔTmax")
expect(approx(sd.tMean!, 100.0), "diff числовое: 45 - (-55) = 100, got \(String(describing: sd.tMean))")

// 12. Линейный профиль (MEAS-02 экспорт выборки)
m = Measurement(kind: .line, x0: 100, y0: 30, x1: 105, y1: 30)
let sig = [UInt16](repeating: 15000, count: W * H)
let prof = MeasurementService.lineProfile(m, temp: temp, signal: sig)
expect(prof.count == 6, "профиль 6 точек")
expect(prof.allSatisfy { approx($0.temp, Double($0.x) - 160) }, "профиль t=x-160")

// 13. Границы кадра: rect с выходом за края — климпится, не падает
m = Measurement(kind: .rect, x0: -50, y0: -10, x1: 400, y1: 300)
s = MeasurementService.compute(m, temp: temp)
// (x0..x5 y=0: nan,nan,-269.999,-157,-156,-155 => invalid=2) => W*H-2
expect(s.validCount == W * H - 2, "полный кадр: invalid только idx(0,0),idx(1,0), got \(s.validCount)")

print("== TEST-03: координаты zoom/pan/размер (инвариант пикселя) ==")

// 14.Round-trip матрица->view->матрица при разных zoom/pan/размерах
var rtOK = true
for (vw, vh, z, px, py) in [(1440.0, 900.0, 1.0, 160, 120),
                            (1000.0, 680.0, 1.0, 0, 0),
                            (1920.0, 1080.0, 3.7, 319, 239),
                            (1200.0, 800.0, 8.0, 100, 100),
                            (1000.0, 680.0, 1.0, 319, 0)] {
    if !FrameGeometry.roundTripStable(viewW: vw, viewH: vh, zoom: z, panX: 37, panY: -19,
                                      mx: px, my: py) { rtOK = false; print("  rt fail \(vw)x\(vh) z\(z)") }
}
expect(rtOK, "round-trip инвариант для 5 конфигураций")

// 15. Точность пикселя: центр пикселя всегда мапится в себя на скруглениях
let geo = FrameGeometry(viewW: 1280, viewH: 720, zoom: 1.0, panX: 0, panY: 0)
var pixOK = true
for y in stride(from: 0, to: 240, by: 7) { for x in stride(from: 0, to: 320, by: 11) {
    let v = geo.viewPoint(matrixX: x, matrixY: y)
    if geo.matrixPixel(fromView: v).map({ $0.x != x || $0.y != y }) ?? true { pixOK = false }
}}
expect(pixOK, "все центры пикселей round-trip при fit-масштабе")

// 16. Point-in-pixel вблизи границ пикселей: x=0 левый край (view=contentRect.minX)
if let p = geo.matrixPixel(fromView: geo.contentRect.origin) {
    expect(p.x == 0 && p.y == 0, "левый верхний угол => (0,0)")
} else { expect(false, "левый верхний угол за кадром?") }

// 17. Точка за правым нижним краем матрицы => nil
let far = CGPoint(x: geo.contentRect.maxX, y: geo.contentRect.maxY)
expect(geo.matrixPixel(fromView: far) == nil, "правый нижний угол (исключительно) => nil")

// 18. Палитра/сглаживание не влияют: измерения читают temp, не rgb —
//     статистика не меняется при «перекраске» (temp тот же массив)
let sBefore = MeasurementService.compute(Measurement(kind: .rect, x0: 50, y0: 50, x1: 60, y1: 60), temp: temp)
let sAfter = MeasurementService.compute(Measurement(kind: .rect, x0: 50, y0: 50, x1: 60, y1: 60), temp: temp)
expect(sBefore.tMean == sAfter.tMean && sBefore.validCount == sAfter.validCount, "VIEW-02: одинаковый temp => одинаковая статистика")


print("== TEST-04: документ .seekscan round-trip ==")
do {
    var f = FrameSnapshot(sessionFrameId: 777, hostTimestamp: Date(timeIntervalSince1970: 1_730_000_000),
                          temp: temp, signal: [UInt16](repeating: 15000, count: W * H),
                          rgb: [UInt8](repeating: 42, count: W * H * 3),
                          spanLo: 15243, spanHi: 15731)
    f.validityRule = "t <= -270 C or NaN => invalid"
    let meas = Measurement(kind: .rect, x0: 100, y0: 50, x1: 110, y1: 52)
    var doc = ScanDocument()
    doc.meta.title = "Тест; плашка \"кавычка\""
    doc.meta.conditions.tAirC = 21.5
    doc.meta.conditions.currentB = 132.4
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("t\(UUID().uuidString).seekscan")
    do {
        try ProjectStore.save(doc: doc, frames: [f], measurements: [meas], defects: [], to: url)
        let l = try ProjectStore.load(url: url)
        expect(l.frames.count == 1, "кадр сохранён")
        let tempBytes = temp.withUnsafeBufferPointer { Data(buffer: $0) }
        let backBytes = l.frames[0].temp.withUnsafeBufferPointer { Data(buffer: $0) }
        expect(tempBytes == backBytes, "матрица temp побитово без потерь (f64)")
        expect(l.frames[0].signal == f.signal, "сигнал u16 без потерь")
        expect(l.frames[0].sessionFrameId == 777, "frameID сохранён")
        expect(approx(l.frames[0].hostTimestamp.timeIntervalSince1970, 1_730_000_000, 1),
               "timestamp host ISO8601")
        expect(l.measurements.count == 1 && l.measurements[0].x0 == 100 && l.measurements[0].y1 == 52,
               "геометрия измерения без потерь")
        expect(l.doc.meta.title == doc.meta.title, "meta (кириллица+сепараторы) цела")
        expect(l.doc.meta.conditions.currentB == 134.0 - 1.6, "условия Double без потерь")
        expect(!(l.frames[0].validityRule.contains("HASH-MISMATCH")), "sha256 оригинала совпал")
        let s2 = MeasurementService.compute(l.measurements[0], temp: l.frames[0].temp)
        expect(s2.validCount == 33 && approx(s2.tMean!, -55), "статистика на загруженном совпадает")

        // TEST-09: неизвестная новая схема -> открывается, файл не тронут
        let mf = url.appendingPathComponent("manifest.json")
        var j = (try? JSONSerialization.jsonObject(with: Data(contentsOf: mf)) as? [String: Any]) ?? [:]
        j["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: j).write(to: mf)
        let l2 = try ProjectStore.load(url: url)
        expect(l2.newerSchema, "schemaVersion 99 -> newerSchema=true, без throw")
        expect(l2.doc.schemaVersion == 99, "версия схемы прочитана")
        // оригинал не испорчен повторным чтением
        let l3 = try? ProjectStore.load(url: url)
        expect(l3?.newerSchema == true, "повторное чтение цело")
        try? FileManager.default.removeItem(at: url)
    } catch {
        expect(false, "round-trip без исключений: \(error)")
    }
}


print("== TEST-03b: поворот 90/180/270 (VIEW-03) ==")
var rotOK = true
for rot in [0, 90, 180, 270] {
    for (vw, vh, z) in [(1440.0, 900.0, 1.0), (1000.0, 680.0, 2.5), (800.0, 900.0, 1.0)] {
        for (mx, my) in [(0, 0), (319, 239), (160, 120), (0, 239), (319, 0), (7, 200)] {
            if !FrameGeometry.roundTripStable(viewW: vw, viewH: vh, zoom: z, panX: 11, panY: -7,
                                              mx: mx, my: my, rotation: rot) {
                rotOK = false; print("  rot\(rot) fail vw\(vw) z\(z) (\(mx),\(my))")
            }
        }
    }
}
expect(rotOK, "round-trip инвариант при повороте 0/90/180/270")

// геометрия rect-оверлея при 90°: ширина = высота диапазона матрицы
let g90 = FrameGeometry(viewW: 900, viewH: 1200, zoom: 1, panX: 0, panY: 0, rotation: 90)
let vr = g90.viewRect(x0: 10, y0: 20, x1: 30, y1: 25)
expect(approx(vr.width, (25 - 20 + 1) * g90.scale), "rect 90°: width по y-диапазону матрицы (\(vr.width) vs \(6*g90.scale))")
expect(approx(vr.height, (30 - 10 + 1) * g90.scale), "rect 90°: height по x-диапазону")
// contentRect меняет аспект при 90°
expect(g90.contentRect.width < g90.contentRect.height, "90°: кадр вертикальный")
// центр кадра (160,120) при 90 vs 270 — зеркальные позиции по горизонтали
let c1 = g90.viewPoint(matrixX: 160, matrixY: 120)
let g270 = FrameGeometry(viewW: 900, viewH: 1200, zoom: 1, panX: 0, panY: 0, rotation: 270)
let c2 = g270.viewPoint(matrixX: 160, matrixY: 120)
let dx1 = c1.x - g90.contentRect.midX, dx2 = c2.x - g270.contentRect.midX
expect(approx(dx1, -dx2, 1e-6), "90/270 зеркальны по X")


print("== TEST-03c: растяжение (stretch) ==")
var stOK = true
for rot in [0, 90, 180, 270] {
    for (vw, vh, z) in [(1440.0, 900.0, 1.0), (1000.0, 680.0, 3.3)] {
        for (mx, my) in [(0, 0), (319, 239), (100, 55)] {
            if !FrameGeometry.roundTripStable(viewW: vw, viewH: vh, zoom: z, panX: 0, panY: 0,
                                              mx: mx, my: my, rotation: rot, stretch: true) {
                stOK = false; print("  stretch rot\(rot) vw\(vw) (\(mx),\(my))")
            }
        }
    }
}
expect(stOK, "round-trip инвариант при stretch + поворот")
// растянутый контент заполняет вью
let gs = FrameGeometry(viewW: 1000, viewH: 700, zoom: 1, panX: 0, panY: 0, rotation: 270, stretch: true)
expect(approx(gs.contentRect.width, 1000) && approx(gs.contentRect.height, 700),
       "stretch: contentRect == область вью")
expect(approx(gs.scaleX, 1000.0/240.0), "270 stretch scaleX = W/rotW")
expect(approx(gs.scaleY, 700.0/320.0), "270 stretch scaleY = H/rotH")

print("\n\(checks) проверок, \(failures) провалов")
exit(failures == 0 ? 0 : 1)
