// ReportService.swift — PDF A4 фиксированный шаблон (REP-03…REP-08), PNG с оформлением,
// CSV (рус. Excel: UTF-8 BOM + ';'), температурная матрица f64.
// Данные собираются на main (collect), тяжёлый экспорт — вне main (ARC-05).
// PDF фиксирует снимок данных на момент экспорта (REP-06).
import AppKit
import UniformTypeIdentifiers

struct ReportData {
    var meta: ScanMeta
    var units: DisplayUnits
    var frames: [FrameSnapshot]
    var measurements: [Measurement]
    var defects: [Defect]
    var calibrated: String
    var created: Date
    var exportId: String
    var exportDate = Date()
}

@MainActor
func collectReportData(_ m: InspectionModel) -> ReportData {
    ReportData(meta: m.doc.meta, units: m.units, frames: m.frames,
               measurements: m.measurements, defects: m.defects,
               calibrated: m.calibratedText, created: m.doc.created,
               exportId: String(UUID().uuidString.prefix(8)))
}

enum ReportService {
    static let appVersion = "1.0-P0"

    // MARK: — PDF (REP-03) —

    static func exportPDF(data d: ReportData, engine e: Engine, to url: URL) throws {
        let pageW: CGFloat = 595.28, pageH: CGFloat = 841.89   // A4 portrait, pt
        guard let ctx = CGContext(url as CFURL, mediaBox: nil,
                                  [kCGPDFContextCreator as String: "SeekIR \(appVersion)"] as CFDictionary)
        else { throw err("CGContext PDF не создан") }
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = g
        let R = Rep(ctx: ctx, pageW: pageW, pageH: pageH, data: d, engine: e)

        // 1. Титул
        R.newPage()
        R.text("Отчёт тепловизионного обследования", size: 22, weight: .bold, y: pageH - 90)
        R.text(d.meta.title.isEmpty ? "Без названия" : d.meta.title, size: 16, y: pageH - 122)
        R.line(y: pageH - 140)
        var y = pageH - 170
        y = R.kv("Площадка", d.meta.site, y: y)
        y = R.kv("Исполнитель", d.meta.inspector, y: y)
        y = R.kv("Дата обследования", d.created.formatted(date: .long, time: .shortened), y: y)
        y = R.kv("Снимков", "\(d.frames.count)", y: y)
        y = R.kv("Измерений", "\(d.measurements.count)", y: y)
        y = R.kv("Дефектов", "\(d.defects.count)", y: y)
        y += 14
        y = R.text("Прибор: Seek Thermal CompactPRO (PIR324), матрица 320×240 VOx 17 мкм. "
                   + "Ядро E1 bit-exact. Время кадра — хост-часы (устройство время не передаёт).",
                   size: 10, color: .secondaryLabelColor, y: y, maxW: pageW - 110)
        y -= 16
        R.text("Отчёт не содержит автоматической классификации опасности; причины дефектов — "
               + "гипотезы исполнителя.", size: 10, color: .secondaryLabelColor, y: y, maxW: pageW - 110)

        // 2. Объект и условия (DOC-03)
        R.newPage()
        R.header("Объект и условия измерений")
        y = pageH - 110
        y = R.kv("Название", d.meta.title, y: y)
        y = R.kv("Площадка", d.meta.site, y: y)
        if !d.meta.equipment.isEmpty {
            y = R.text("Оборудование:", weight: .bold, y: y) - 2
            for eq in d.meta.equipment {
                y = R.kv("—", [eq.name, eq.cell, eq.phase].filter { !$0.isEmpty }.joined(separator: " · "), y: y)
            }
            y -= 6
        }
        let c = d.meta.conditions
        let u = d.units
        y = R.text("Условия среды и нагрузки", size: 11, weight: .semibold,
                   color: .secondaryLabelColor, y: y) - 4
        y = R.kvOpt("Температура воздуха", c.tAirC.map { u.format($0) }, y: y)
        y = R.kvOpt("Токи фаз A/B/C",
                    [c.currentA, c.currentB, c.currentC].contains(where: { $0 != nil })
                        ? [c.currentA, c.currentB, c.currentC]
                            .map { $0.map { String(format: "%.1f", $0) } ?? "—" }
                            .joined(separator: " / ") + " А"
                        : nil, y: y)
        y = R.kvOpt("Напряжение", c.voltage.map { String(format: "%.0f В", $0) }, y: y)
        y = R.kvOpt("Активная мощность", c.powerKW.map { String(format: "%.1f кВт", $0) }, y: y)
        y = R.kvOpt("Номинальные (ток/напряжение)",
                    c.nominalCurrent != nil || c.nominalVoltage != nil
                        ? "\((c.nominalCurrent.map { String(format: "%.0f А", $0) }) ?? "—") / \((c.nominalVoltage.map { String(format: "%.0f В", $0) }) ?? "—")"
                        : nil, y: y)
        y = R.kvOpt("Время регистрации нагрузки",
                    c.loadTime?.formatted(date: .abbreviated, time: .standard), y: y)
        y = R.kvOpt("Комментарий", c.comment.isEmpty ? nil : c.comment, y: y)

        // 3. Прибор и калибровка
        R.newPage()
        R.header("Прибор и метрологические условия")
        y = pageH - 110
        y = R.kv("Камера", "Seek Thermal PIR324 (VID:PID 289d:0011)", y: y)
        y = R.kv("Матрица", "320×240, FOV 32° (аудит репозитория, не паспорт)", y: y)
        y = R.kv("Ядро", "E1 bit-exact (FF-коррекция + денуаз F9 + Планк)", y: y)
        let p = (d.frames.last ?? d.frames.first)?.planck
        y = R.kv("Планк-константы",
                 p.map { String(format: "r1=%.5g b=%.4g f=%.4g r2=%.5g o=%.4g", $0.r1, $0.b, $0.f, $0.r2, $0.o) } ?? "—", y: y)
        y = R.kv("Калибровка Планка", d.calibrated, y: y)
        let sc = (d.frames.last ?? d.frames.first)?.scene
        y = R.kv("Сцена (применена ядром)",
                 sc.map { String(format: "ε=%.2f T_отр=%.0f°C T_возд=%.0f°C d=%.2fм RH=%.0f%%",
                                 $0.emissivity, $0.tReflC, $0.tAtmC, $0.distanceM, $0.relHumidity) } ?? "—", y: y)
        R.text("Встроенной видимой камеры нет — фотоснимок объекта не прикладывается (REP-05). "
               + "Без двухточечной калибровки погрешность температур порядка ±5 °C.",
               size: 10, color: .secondaryLabelColor, y: y - 24, maxW: pageW - 110)

        // 4. Карточки снимков (REP-04)
        for f in d.frames {
            R.newPage()
            R.header("Снимок \(R.page): \(f.hostTimestamp.formatted(date: .abbreviated, time: .standard))")
            let imgW: CGFloat = pageW - 110
            let imgH = imgW * 240 / 320
            let top = pageH - 110 - imgH
            R.drawImage(rgb: f.rgb, spanLo: f.spanLo, spanHi: f.spanHi, palette: f.palette,
                        measurements: d.measurements.filter { $0.frameId == f.id },
                        units: u,
                        rect: CGRect(x: 55, y: top, width: imgW, height: imgH))
            y = top - 14
            y = R.text("frameID \(f.sessionFrameId) · время host · span \(String(format: "%.0f…%.0f", f.spanLo, f.spanHi)) counts · палитра \(f.palette) · ε=\(String(format: "%.2f", f.scene.emissivity)) · данные: \(f.dataKind)",
                       size: 9, color: .secondaryLabelColor, y: y) - 8
            let mm = d.measurements.filter { $0.frameId == f.id }
            if !mm.isEmpty {
                y = R.table(rows: mm.map { meas -> [String] in
                    let s = MeasurementService.compute(meas, temp: f.temp, all: d.measurements)
                    return [meas.name, meas.kind.rawValue,
                            meas.kind == .point ? "(\(meas.x0),\(meas.y0))" : "(\(meas.x0),\(meas.y0))–(\(meas.x1),\(meas.y1))",
                            s.tMin.map { u.format($0) } ?? "нет данных",
                            s.tMax.map { u.format($0) } ?? "нет данных",
                            s.tMean.map { u.format($0) } ?? "нет данных",
                            s.hasData ? "\(s.validCount)" : "—"]
                }, headers: ["Название", "Тип", "Геометрия",
                             "Tmin\(u.suffix)", "Tmax\(u.suffix)", "Tmean\(u.suffix)", "Пикс"],
                   widths: [110, 45, 120, 72, 72, 72, 45], y: y)
            } else {
                y = R.text("Измерений, привязанных к этому кадру, нет.",
                           size: 9, color: .secondaryLabelColor, y: y) - 4
            }
            y = R.text("Валидность: \(f.validityRule); температуры — расчёт ядра (Планк); исходный сигнал u16 сохранён в пакете документа.",
                       size: 9, color: .secondaryLabelColor, y: y)
        }

        // 5. Дефекты (REP-01)
        if !d.defects.isEmpty {
            R.newPage()
            R.header("Дефекты и рекомендации")
            y = pageH - 110
            for (i, dd) in d.defects.enumerated() {
                if y < 200 { R.newPage(); R.header("Дефекты и рекомендации (продолжение)"); y = pageH - 110 }
                y = R.text("Дефект \(i + 1). \(dd.nodeName)", weight: .bold, y: y)
                let eq = d.meta.equipment.first(where: { $0.id == dd.equipmentId })
                y = R.kv("Оборудование", eq.map { [$0.name, $0.cell, $0.phase].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "—", y: y)
                y = R.kv("Наблюдение", dd.observation, y: y)
                y = R.kv("Предполагаемая причина",
                         dd.suspectedCause.isEmpty ? "не указана" : dd.suspectedCause + " (гипотеза)", y: y)
                y = R.kv("Оценка инженера", dd.engineerAssessment, y: y)
                y = R.kv("Рекомендации", dd.recommendation, y: y)
                y = R.kv("Ответственный / срок / статус",
                         "\(dd.assignee.isEmpty ? "—" : dd.assignee) · \(dd.dueDate?.formatted(date: .abbreviated, time: .omitted) ?? "—") · \(dd.status.rawValue)", y: y)
                y -= 14
            }
        }

        // 6. Ограничения
        R.newPage()
        R.header("Ограничения отчёта")
        y = pageH - 110
        for line in [
            "Температуры получены радиометрическим пересчётом ядра (Планк); поверка по чёрному телу"
                + (d.calibrated.contains("загружена") ? " выполнена (калибровка Планка загружена)." : " в ходе обследования не выполнена — возможна погрешность ±5 °C."),
            "Время кадров — хост-часы компьютера; время устройства не передаётся.",
            "Видимая камера отсутствует; геометрическое совмещение с фотографиями не заявляется.",
            "Классификация опасности не автоматизирована; решения принимает ответственный инженер.",
            "Отчёт фиксирует данные на момент экспорта (\(d.exportDate.formatted())); последующие изменения проекта его не меняют.",
        ] {
            y = R.text("— " + line, size: 10.5, y: y, maxW: pageW - 110) - 6
        }

        R.finish()
        ctx.closePDF()
        NSGraphicsContext.current = nil
    }

    private static func err(_ s: String) -> AppError {
        AppError(kind: .writeFailed, userText: "Не удалось создать PDF.",
                 savedDataText: "Данные обследования сохранены в памяти/документе.",
                 actionText: "Повторите экспорт.", technical: s)
    }

    // MARK: — PNG с оформлением (REP-07) —

    static func exportPNG(data d: ReportData, engine e: Engine, frame f: FrameSnapshot, to url: URL) throws {
        let scale = 5, w = 320 * scale, h = 240 * scale
        let barH = 90
        guard let ctx = CGContext(data: nil, width: w, height: h + barH, bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw err("PNG context") }
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h + barH))
        let R = Rep(ctx: ctx, pageW: CGFloat(w), pageH: CGFloat(h + barH), data: d,
                    engine: e, noFooter: true)
        R.drawImage(rgb: f.rgb, spanLo: f.spanLo, spanHi: f.spanHi, palette: f.palette,
                    measurements: d.measurements.filter { $0.frameId == f.id },
                    units: d.units,
                    rect: CGRect(x: 0, y: CGFloat(barH), width: CGFloat(w), height: CGFloat(h)))
        R.small("\(d.meta.title) · \(f.hostTimestamp.formatted()) · frame \(f.sessionFrameId) · SeekIR \(appVersion)", y: 58)
        R.small("span \(String(format: "%.0f…%.0f counts", f.spanLo, f.spanHi)) · ε=\(String(format: "%.2f", f.scene.emissivity)) · отбор: \(f.validityRule)", y: 38)
        R.small("Seek-IR v\(appVersion) · экспорт \(Date().formatted())", y: 14)
        guard let img = ctx.makeImage() else { throw err("makeImage") }
        let rep = NSBitmapImageRep(cgImage: img)
        try (rep.representation(using: .png, properties: [:]))?.write(to: url)
    }

    // MARK: — CSV (REP-07, рус. Excel) —

    static func exportCSV(data d: ReportData, to url: URL) throws {
        let u = d.units
        var out = "\u{FEFF}"   // BOM для Excel
        out += "SeekIR;версия \(appVersion);экспорт \(ISO8601DateFormatter().string(from: d.exportDate));единицы \(u.suffix)\n\n"
        out += "Измерения\n"
        out += "Название;Тип;Геометрия;Пиксели валидных;Tmin \(u.suffix);Tmax \(u.suffix);Tmean \(u.suffix);Комментарий\n"
        func name(_ id: UUID?) -> String {
            guard let id = id, let m = d.measurements.first(where: { $0.id == id }) else { return "?" }
            return m.name
        }
        for meas in d.measurements {
            let f = d.frames.first { $0.id == meas.frameId } ?? d.frames.last
            let temp = f?.temp ?? []
            let s = MeasurementService.compute(meas, temp: temp, all: d.measurements)
            let geo = meas.kind == .diff ? "Δ(\(name(meas.aId)) − \(name(meas.bId)))"
                : meas.kind == .point ? "(\(meas.x0);\(meas.y0))"
                : "(\(meas.x0);\(meas.y0))–(\(meas.x1);\(meas.y1))"
            func num(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
            out += [csv(meas.name), meas.kind.rawValue, csv(geo),
                    s.hasData ? "\(s.validCount)" : "нет данных",
                    num(s.tMin), num(s.tMax), num(s.tMean), csv(meas.comment)].joined(separator: ";") + "\n"
        }
        for meas in d.measurements where meas.kind == .line {
            guard let f = d.frames.first(where: { $0.id == meas.frameId }) ?? d.frames.last else { continue }
            out += "\nПрофиль «\(meas.name)»;x;y;сигнал counts;температура °C\n"
            for p in MeasurementService.lineProfile(meas, temp: f.temp, signal: f.signal) {
                let t = tempIsValid(p.temp) ? String(format: "%.3f", p.temp) : ""
                out += ";\(p.x);\(p.y);\(p.signal);\(t)\n"
            }
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
    private static func csv(_ s: String) -> String {
        if s.contains(";") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    // MARK: — температурная матрица (f64, формат golden-теста ядра) —

    static func exportTempMatrix(frame f: FrameSnapshot, to url: URL) throws {
        var temp = f.temp
        let data = temp.withUnsafeMutableBufferPointer { Data(buffer: $0) }
        try data.write(to: url)
        let side = url.deletingPathExtension().appendingPathExtension("sidecar.json")
        let meta = """
        {"width":\(f.width),"height":\(f.height),"dtype":"float64 LE row-major",\
        "unit":"celsius","validityRule":"t <= -270 or NaN = invalid",\
        "frameID":\(f.sessionFrameId),"timestamp":"\(ISO8601DateFormatter().string(from: f.hostTimestamp))",\
        "app":"SeekIR \(appVersion)"}
        """
        try meta.write(to: side, atomically: true, encoding: .utf8)
    }
}

// MARK: — низкоуровневый рисователь страниц (переносы, повтор заголовков, footer) —

final class Rep {
    let ctx: CGContext
    let pageW: CGFloat, pageH: CGFloat
    let data: ReportData
    let engine: Engine
    let noFooter: Bool
    var page = 0
    var opened = false

    init(ctx: CGContext, pageW: CGFloat, pageH: CGFloat, data: ReportData,
         engine: Engine, noFooter: Bool = false) {
        self.ctx = ctx; self.pageW = pageW; self.pageH = pageH
        self.data = data; self.engine = engine; self.noFooter = noFooter
    }

    func newPage() {
        if opened { footer() }
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        ctx.beginPage(mediaBox: &box)
        opened = true
        page += 1
    }
    func finish() { if opened { footer() } }

    func footer() {
        guard !noFooter else { return }
        NSAttributedString(string:
            "SeekIR \(ReportService.appVersion) · экспорт \(data.exportId) · \(data.exportDate.formatted(date: .abbreviated, time: .standard)) · стр. \(page)",
            attributes: [.font: NSFont.systemFont(ofSize: 8),
                         .foregroundColor: NSColor.tertiaryLabelColor])
            .draw(at: NSPoint(x: 55, y: 24))
    }

    func header(_ t: String) {
        _ = text(t, size: 15, weight: .bold, y: pageH - 78)
        line(y: pageH - 90)
    }
    func line(y: CGFloat) {
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.6)
        ctx.move(to: CGPoint(x: 55, y: y)); ctx.addLine(to: CGPoint(x: pageW - 55, y: y))
        ctx.strokePath()
    }

    @discardableResult
    func text(_ s: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
              color: NSColor = .labelColor, y: CGFloat, maxW: CGFloat = 0) -> CGFloat {
        let w = maxW > 0 ? maxW : pageW - 110
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        var lineY = y
        for ln in wrap(s, font: font, maxW: w) {
            NSAttributedString(string: ln, attributes: [
                .font: font, .foregroundColor: color]).draw(at: NSPoint(x: 55, y: lineY))
            lineY -= size + 3
        }
        return lineY
    }

    func wrap(_ s: String, font: NSFont, maxW: CGFloat) -> [String] {
        var lines = [String]()
        for para in s.components(separatedBy: "\n") {
            var cur = ""
            for word in para.components(separatedBy: " ") {
                let test = cur.isEmpty ? word : cur + " " + word
                if (test as NSString).size(withAttributes: [.font: font]).width > maxW, !cur.isEmpty {
                    lines.append(cur); cur = word
                } else { cur = test }
            }
            lines.append(cur)
        }
        return lines
    }

    @discardableResult
    func kv(_ k: String, _ v: String, y: CGFloat) -> CGFloat {
        let kx = NSAttributedString(string: k + ": ", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor])
        kx.draw(at: NSPoint(x: 55, y: y))
        let kw = kx.size().width
        let vr = CGRect(x: 55 + kw, y: y - 30, width: pageW - 110 - kw, height: 400)
        let textV = v.isEmpty ? "—" : v
        NSAttributedString(string: textV, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5)]).draw(in: vr)
        let h = (textV as NSString).boundingRect(
            with: CGSize(width: vr.width, height: 1000),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: NSFont.systemFont(ofSize: 10.5)]).height
        return y - max(16, ceil(h) + 6)
    }
    @discardableResult
    func kvOpt(_ k: String, _ v: String?, y: CGFloat) -> CGFloat {
        guard let v = v, !v.isEmpty else { return kv(k, "— (не задано)", y: y) }
        return kv(k, v, y: y)
    }
    func small(_ s: String, y: CGFloat) {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor.secondaryLabelColor]).draw(at: NSPoint(x: 0, y: y))
    }

    // таблица с повтором заголовка на переносе (REP-08)
    @discardableResult
    func table(rows: [[String]], headers: [String], widths: [CGFloat], y: CGFloat) -> CGFloat {
        var yy = y
        func drawHeader() {
            var x: CGFloat = 55
            ctx.setFillColor(NSColor.quaternaryLabelColor.cgColor)
            ctx.fill(CGRect(x: 55, y: yy - 4, width: widths.reduce(0, +), height: 16))
            for (i, hh) in headers.enumerated() {
                NSAttributedString(string: hh, attributes: [
                    .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor])
                    .draw(at: NSPoint(x: x + 2, y: yy - 1))
                x += widths[i]
            }
            yy -= 16
        }
        drawHeader()
        var alt = false
        for row in rows {
            if yy < 90 {
                footer()
                var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
                ctx.beginPage(mediaBox: &box)
                page += 1
                header("Измерения (продолжение)")   // повтор заголовка таблицы (REP-08)
                yy = pageH - 110
                drawHeader()
                alt = false
            }
            if alt {
                ctx.setFillColor(NSColor.quaternaryLabelColor.withAlphaComponent(0.3).cgColor)
                ctx.fill(CGRect(x: 55, y: yy - 4, width: widths.reduce(0, +), height: 14))
            }
            alt.toggle()
            var x: CGFloat = 55
            for (i, cell) in row.enumerated() {
                NSAttributedString(string: String(cell.prefix(60)), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)])
                    .draw(at: NSPoint(x: x + 2, y: yy - 1))
                x += widths[i]
            }
            yy -= 14
        }
        return yy - 8
    }

    // термограмма с colorbar + подписи + оверлеи измерений (REP-04)
    func drawImage(rgb: [UInt8], spanLo: Double, spanHi: Double, palette: Int,
                   measurements ms: [Measurement], units u: DisplayUnits, rect: CGRect) {
        guard !rgb.isEmpty, let img = RepKit.cg(rgb) else { return }
        let imgRect = CGRect(x: rect.minX, y: rect.minY + 18,
                             width: rect.width - 60, height: (rect.width - 60) * 240 / 320)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(img, in: imgRect)
        ctx.restoreGState()
        // colorbar из LUT ядра
        var lut = [UInt8](repeating: 0, count: 256 * 3)
        lut.withUnsafeMutableBytes { raw in
            if let p = raw.bindMemory(to: (UInt8, UInt8, UInt8).self).baseAddress {
                sk_palette_lut(sk_palette_t(rawValue: UInt32(palette)), p)
            }
        }
        let barX = imgRect.maxX + 8
        for i in 0..<256 {
            ctx.setFillColor(CGColor(red: CGFloat(lut[i * 3]) / 255,
                                     green: CGFloat(lut[i * 3 + 1]) / 255,
                                     blue: CGFloat(lut[i * 3 + 2]) / 255, alpha: 1))
            ctx.fill(CGRect(x: barX, y: imgRect.minY + CGFloat(i) / 256 * imgRect.height,
                            width: 14, height: imgRect.height / 256 + 1))
        }
        let hiC = engine.signalToC(spanHi), loC = engine.signalToC(spanLo)
        NSAttributedString(string: u.format(hiC, digits: 1), attributes: [
            .font: NSFont.systemFont(ofSize: 8)]).draw(at: NSPoint(x: barX + 18, y: imgRect.maxY - 8))
        NSAttributedString(string: u.format(loC, digits: 1), attributes: [
            .font: NSFont.systemFont(ofSize: 8)]).draw(at: NSPoint(x: barX + 18, y: imgRect.minY))
        // оверлеи (геометрия матрицы -> PDF y-вверх)
        let sx = imgRect.width / 320, sy = imgRect.height / 240
        for m in ms where m.visible {
            let col = NSColor(hex: m.colorHex).cgColor
            ctx.setStrokeColor(col); ctx.setLineWidth(1.2)
            switch m.kind {
            case .rect:
                ctx.stroke(CGRect(x: imgRect.minX + CGFloat(m.x0) * sx,
                                  y: imgRect.maxY - CGFloat(m.y1 + 1) * sy,
                                  width: CGFloat(m.x1 - m.x0 + 1) * sx,
                                  height: CGFloat(m.y1 - m.y0 + 1) * sy))
            case .line:
                ctx.move(to: CGPoint(x: imgRect.minX + (CGFloat(m.x0) + 0.5) * sx,
                                     y: imgRect.maxY - (CGFloat(m.y0) + 0.5) * sy))
                ctx.addLine(to: CGPoint(x: imgRect.minX + (CGFloat(m.x1) + 0.5) * sx,
                                        y: imgRect.maxY - (CGFloat(m.y1) + 0.5) * sy))
                ctx.strokePath()
            case .point:
                ctx.strokeEllipse(in: CGRect(x: imgRect.minX + CGFloat(m.x0) * sx - 3,
                                             y: imgRect.maxY - CGFloat(m.y0) * sy - 3,
                                             width: 6, height: 6))
            case .diff: break
            }
            if m.kind != .diff {
                let lx = m.kind == .rect ? imgRect.minX + CGFloat(m.x0) * sx
                    : imgRect.minX + CGFloat((m.x0 + m.x1) / 2) * sx
                NSAttributedString(string: m.name, attributes: [
                    .font: NSFont.systemFont(ofSize: 7.5, weight: .semibold),
                    .foregroundColor: NSColor(hex: m.colorHex)])
                    .draw(at: NSPoint(x: lx, y: imgRect.maxY - CGFloat(m.y0) * sy - 10))
            }
        }
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(imgRect)
    }
}

extension RepKit {
    static func cg(_ rgb: [UInt8]) -> CGImage? {
        let w = 320, h = 240
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i*4] = rgb[i*3]; rgba[i*4+1] = rgb[i*3+1]; rgba[i*4+2] = rgb[i*3+2]
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        return rgba.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
