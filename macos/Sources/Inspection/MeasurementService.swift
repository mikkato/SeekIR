// MeasurementService.swift — статистика измерений по готовой температурной матрице.
// ЧИСТЫЕ функции (ARC-04): радиометрический пересчёт остаётся в ядре, здесь только
// геометрия/выборка по °C. Правила MEAS-03 зафиксированы и покрыты тестами (Tests/).
import Foundation

enum MeasurementService {

    /// Пиксели прямоугольной области. ПРАВИЛО (MEAS-03): включаются ВСЕ целочисленные
    /// пиксели x0<=x<=x1, y0<=y<=y1 включительно (рамка входит), геометрия нормализована.
    static func rectPixels(x0: Int, y0: Int, x1: Int, y1: Int, w: Int = 320, h: Int = 240)
        -> [Int]
    {
        let a = max(0, min(x0, x1)), b = min(w - 1, max(x0, x1))
        let c = max(0, min(y0, y1)), d = min(h - 1, max(y0, y1))
        guard a <= b, c <= d else { return [] }
        var out = [Int]()
        out.reserveCapacity((b - a + 1) * (d - c + 1))
        for y in c...d { for x in a...b { out.append(y * w + x) } }
        return out
    }

    /// Пиксели линии. ПРАВИЛО: целочисленный Bresenham (детерминированная выборка,
    /// без субпиксельной точности). Симметричная классика, одинаковый результат на всех ОС.
    static func linePixels(x0: Int, y0: Int, x1: Int, y1: Int, w: Int = 320, h: Int = 240)
        -> [Int]
    {
        var x = x0, y = y0
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        var out = [Int]()
        while true {
            if x >= 0, x < w, y >= 0, y < h { out.append(y * w + x) }
            if x == x1, y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
        return out
    }

    /// Статистика по индексам (MEAS-02). Невалидные исключаются (tempIsValid), пустая
    /// выборка -> hasData=false — «Нет данных», не 0 °C (MEAS-06).
    static func stats(temp: [Double], indices: [Int], w: Int = 320) -> MeasureStats {
        var count = 0, sum = 0.0
        var tMin = Double.infinity, tMax = -Double.infinity
        var minXY: (x: Int, y: Int)?, maxXY: (x: Int, y: Int)?
        for i in indices where i >= 0 && i < temp.count {
            let t = temp[i]
            guard tempIsValid(t) else { continue }
            count += 1; sum += t
            if t < tMin { tMin = t; minXY = (i % w, i / w) }
            if t > tMax { tMax = t; maxXY = (i % w, i / w) }
        }
        guard count > 0 else { return MeasureStats() }
        return MeasureStats(hasData: true, validCount: count, tMin: tMin, tMax: tMax,
                            tMean: sum / Double(count), minXY: minXY, maxXY: maxXY)
    }

    private static let areaKinds: Set<MeasureKind> = [.rect]

    /// Результат измерения на матрице кадра.
    static func compute(_ m: Measurement, temp: [Double],
                        all: [Measurement]? = nil) -> MeasureStats {
        switch m.kind {
        case .point:
            return stats(temp: temp, indices: [m.y0 * 320 + m.x0])
        case .rect:
            return stats(temp: temp, indices: rectPixels(x0: m.x0, y0: m.y0, x1: m.x1, y1: m.y1))
        case .line:
            return stats(temp: temp, indices: linePixels(x0: m.x0, y0: m.y0, x1: m.x1, y1: m.y1))
        case .diff:
            // Δ над результатами двух измерений одного кадра (MEAS-01): ΔTmean, ΔTmax, ΔTmin.
            guard let all = all, let a = all.first(where: { $0.id == m.aId }),
                  let b = all.first(where: { $0.id == m.bId }) else { return MeasureStats() }
            let sa = compute(a, temp: temp), sb = compute(b, temp: temp)
            guard sa.hasData, sb.hasData,
                  let ma = sa.tMean, let mb = sb.tMean else { return MeasureStats() }
            var st = MeasureStats()
            st.hasData = true
            st.validCount = min(sa.validCount, sb.validCount)
            st.tMean = ma - mb
            if let a = sa.tMax, let b = sb.tMax { st.tMax = a - b }
            if let a = sa.tMin, let b = sb.tMin { st.tMin = a - b }
            return st
        }
    }

    /// Профиль линии: последовательность (x, y, signal, temp) для таблицы/экспорта (MEAS-02).
    static func lineProfile(_ m: Measurement, temp: [Double], signal: [UInt16])
        -> [(x: Int, y: Int, signal: UInt16, temp: Double)]
    {
        guard m.kind == .line else { return [] }
        return linePixels(x0: m.x0, y0: m.y0, x1: m.x1, y1: m.y1).map {
            ($0 % 320, $0 / 320,
             $0 < signal.count ? signal[$0] : 0,
             $0 < temp.count ? temp[$0] : .nan)
        }
    }
}
