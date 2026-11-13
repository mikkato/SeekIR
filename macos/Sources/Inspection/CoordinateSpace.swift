// CoordinateSpace.swift — единственное место преобразования view ↔ матрица (VIEW-03).
// Используется canvas, экспортом и тестами. Все величины в points; Retina прозрачен.
// Поворот — только отображение (VIEW-02): измерения хранятся в координатах матрицы,
// обратное преобразование учитывает поворот (VIEW-03).
import Foundation
import CoreGraphics

struct FrameGeometry: Equatable {
    static let matrixW = 320
    static let matrixH = 240

    var viewW: Double = 1
    var viewH: Double = 1
    var zoom: Double = 1          // 1.0 == вписать
    var panX: Double = 0          // смещение центра контента в view points
    var panY: Double = 0
    var rotation: Int = 0         // против часовой: 0/90/180/270 (экран поворот)
    var stretch: Bool = false     // растянуть на всю область (разные масштабы X/Y, только вид)
    /// view-координаты flipped (y вниз) — как NSView.isFlipped == true и row-major матрицы.

    /// Размер кадра на экране с учётом поворота.
    var rotW: Int { (rotation % 180 == 0) ? Self.matrixW : Self.matrixH }
    var rotH: Int { (rotation % 180 == 0) ? Self.matrixH : Self.matrixW }

    var fitScale: Double { min(viewW / Double(rotW), viewH / Double(rotH)) }
    var fitScaleX: Double { stretch ? viewW / Double(rotW) : fitScale }
    var fitScaleY: Double { stretch ? viewH / Double(rotH) : fitScale }
    var scaleX: Double { fitScaleX * zoom }
    var scaleY: Double { fitScaleY * zoom }
    var scale: Double { scaleX }   // совместимость: в aspect-режиме scaleX == scaleY

    var contentRect: CGRect {
        let w = Double(rotW) * scaleX
        let h = Double(rotH) * scaleY
        let cx = viewW / 2 + panX
        let cy = viewH / 2 + panY
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private var normRot: Int { ((rotation % 360) + 360) % 360 }

    /// Центр пикселя матрицы -> координаты в повёрнутом пространстве кадра.
    private func rotatedCenter(_ x: Int, _ y: Int) -> (Double, Double) {
        switch normRot {
        case 90:  return (Double(y) + 0.5, Double(Self.matrixW - 1 - x) + 0.5)
        case 180: return (Double(Self.matrixW - 1 - x) + 0.5, Double(Self.matrixH - 1 - y) + 0.5)
        case 270: return (Double(Self.matrixH - 1 - y) + 0.5, Double(x) + 0.5)
        default:  return (Double(x) + 0.5, Double(y) + 0.5)
        }
    }

    /// Точка view -> пиксель матрицы (отбрасывается за пределами). Дискретный пиксель,
    /// без субпиксельной интерполяции (MEAS-03): экранное сглаживание не даёт измерений (VIEW-04).
    func matrixPixel(fromView p: CGPoint) -> (x: Int, y: Int)? {
        let r = contentRect
        guard r.width > 0, r.height > 0 else { return nil }
        let u = (Double(p.x) - r.minX) / scaleX
        let v = (Double(p.y) - r.minY) / scaleY
        guard u >= 0, v >= 0, u < Double(rotW), v < Double(rotH) else { return nil }
        let ru = Int(u.rounded(.down)), rv = Int(v.rounded(.down))
        let x: Int, y: Int
        switch normRot {
        case 90:  x = Self.matrixW - 1 - rv; y = ru
        case 180: x = Self.matrixW - 1 - ru; y = Self.matrixH - 1 - rv
        case 270: x = rv;                    y = Self.matrixH - 1 - ru
        default:  x = ru;                    y = rv
        }
        guard x >= 0, y >= 0, x < Self.matrixW, y < Self.matrixH else { return nil }
        return (x, y)
    }

    /// Центр пикселя матрицы -> view-координаты (для отрисовки оверлеев).
    func viewPoint(matrixX: Int, matrixY: Int) -> CGPoint {
        let r = contentRect
        let (u, v) = rotatedCenter(matrixX, matrixY)
        return CGPoint(x: r.minX + u * scaleX, y: r.minY + v * scaleY)
    }

    func viewRect(x0: Int, y0: Int, x1: Int, y1: Int) -> CGRect {
        // четыре угла (валидно при любом повороте), + полпиксела на сторону
        var pts = [viewPoint(matrixX: x0, matrixY: y0)]
        for (mx, my) in [(x1, y0), (x0, y1), (x1, y1)] { pts.append(viewPoint(matrixX: mx, matrixY: my)) }
        let minX = pts.map { $0.x }.min() ?? 0, maxX = pts.map { $0.x }.max() ?? 0
        let minY = pts.map { $0.y }.min() ?? 0, maxY = pts.map { $0.y }.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -scaleX / 2, dy: -scaleY / 2)
    }

    /// Проверка инварианта TEST-03: одна и та же матричная точка при любых zoom/pan/размере/повороте.
    static func roundTripStable(viewW: Double, viewH: Double, zoom: Double,
                                panX: Double, panY: Double, mx: Int, my: Int,
                                rotation: Int = 0, stretch: Bool = false) -> Bool {
        let g = FrameGeometry(viewW: viewW, viewH: viewH, zoom: zoom, panX: panX,
                              panY: panY, rotation: rotation, stretch: stretch)
        guard let v = Optional(g.viewPoint(matrixX: mx, matrixY: my)) else { return false }
        return g.matrixPixel(fromView: v).map { $0.x == mx && $0.y == my } ?? false
    }
}
