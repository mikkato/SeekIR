// ProjectStore.swift — документ .seekscan (DOC-04…DOC-09).
// Каталог-пакет: manifest.json, frames/<uuid>/{meta.json,temp.f64,signal.u16,rgb.png},
// measurements.json, defects.json, attachments/, reports/.
// Атомарная запись через tmp-каталог + replace. Неизвестная schemaVersion -> открытие
// без перезаписи, оригинал не портится (DOC-07).
import Foundation
import CryptoKit

enum ProjectStore {
    static let ext = "seekscan"
    static let supportedMajor = 1

    struct Loaded {
        var doc: ScanDocument
        var frames: [FrameSnapshot]
        var measurements: [Measurement]
        var defects: [Defect]
        var url: URL
        var newerSchema: Bool      // unknown new version -> save-as only
    }

    // MARK: запись

    static func save(doc: ScanDocument, frames: [FrameSnapshot],
                     measurements: [Measurement], defects: [Defect],
                     to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp.appendingPathComponent("frames"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tmp.appendingPathComponent("attachments"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tmp.appendingPathComponent("reports"),
                                                    withIntermediateDirectories: true)

            var varDoc = doc
            varDoc.modified = Date()
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601

            // manifest
            struct Manifest: Codable {
                var schemaVersion: Int
                var docId: UUID
                var appVersion: String
                var coreVersion: String
                var created: Date
                var modified: Date
                var frameCount: Int
                var units: String
                var matrix: [String: String]
                var frames: [FrameRef]
            }
            struct FrameRef: Codable { var id: UUID; var dir: String }

            var refs = [FrameRef]()
            for f in frames {
                let dir = tmp.appendingPathComponent("frames/\(f.id.uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // temp.f64 — LE float64 row-major (схема зафиксирована в docs/ui-architecture.md)
                var temp = f.temp
                let tempData = temp.withUnsafeMutableBufferPointer {
                    Data(buffer: $0)   // nativ LE на arm64/x86; записано в схеме
                }
                try tempData.write(to: dir.appendingPathComponent("temp.f64"))
                var sig = f.signal
                let sigData = sig.withUnsafeMutableBufferPointer { Data(buffer: $0) }
                try sigData.write(to: dir.appendingPathComponent("signal.u16"))
                try rgbPNG(f.rgb).write(to: dir.appendingPathComponent("rgb.png"))
                // meta с хешем оригинала (DOC-05)
                let h = SHA256.hash(data: tempData).map { String(format: "%02x", $0) }.joined()
                var meta = f
                meta.temp = []; meta.signal = []; meta.rgb = []
                struct FrameMeta: Codable { var frame: FrameSnapshot; var sha256Temp: String }
                try enc.encode(FrameMeta(frame: meta, sha256Temp: h))
                    .write(to: dir.appendingPathComponent("meta.json"))
                refs.append(FrameRef(id: f.id, dir: "frames/\(f.id.uuidString)"))
            }

            let mf = Manifest(schemaVersion: varDoc.schemaVersion, docId: varDoc.docId,
                              appVersion: varDoc.appVersion, coreVersion: varDoc.coreVersion,
                              created: varDoc.created, modified: varDoc.modified,
                              frameCount: frames.count, units: "C",
                              matrix: ["width": "320", "height": "240",
                                       "temp": "f64 LE row-major", "signal": "u16 LE row-major"],
                              frames: refs)
            try enc.encode(mf).write(to: tmp.appendingPathComponent("manifest.json"))
            try enc.encode(measurements).write(to: tmp.appendingPathComponent("measurements.json"))
            try enc.encode(defects).write(to: tmp.appendingPathComponent("defects.json"))
            // meta часть ScanDocument — в manifest отдельным блоком
            try enc.encode(varDoc.meta).write(to: tmp.appendingPathComponent("meta.json"))
            varDoc.meta = ScanMeta()  // в doc-блоке не дублируем тяжёлые поля
            try enc.encode(varDoc).write(to: tmp.appendingPathComponent("doc.json"))

            if FileManager.default.fileExists(atPath: url.path) {
                let old = url.deletingLastPathComponent()
                    .appendingPathComponent(".old-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.moveItem(at: url, to: old)
                try FileManager.default.moveItem(at: tmp, to: url)
                try? FileManager.default.removeItem(at: old)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw AppError(kind: .writeFailed,
                           userText: "Не удалось сохранить документ «\(url.lastPathComponent)».",
                           savedDataText: "Все кадры и измерения сохранены в памяти.",
                           actionText: "Проверьте диск/права и повторите сохранение в другой путь.",
                           technical: String(describing: error))
        }
    }

    // MARK: чтение

    static func load(url: URL) throws -> Loaded {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
            throw AppError(kind: .docCorrupt,
                           userText: "Файл не является документом обследования (.seekscan).",
                           savedDataText: "Файл не изменён.",
                           actionText: "Выберите другой файл.")
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        struct FrameRef: Codable { var id: UUID; var dir: String }
        struct Manifest: Codable {
            var schemaVersion: Int
            var docId: UUID
            var appVersion: String
            var coreVersion: String
            var created: Date
            var modified: Date
            var frameCount: Int
            var frames: [FrameRef]
        }
        let manifest: Manifest
        do {
            manifest = try dec.decode(Manifest.self,
                from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
        } catch {
            throw AppError(kind: .docCorrupt,
                           userText: "Манифест документа повреждён и не читается.",
                           savedDataText: "Файл на диске не изменён.",
                           actionText: "Восстановите из резервной копии.")
        }
        if manifest.schemaVersion > supportedMajor {
            // DOC-07: умеем прочитать частично — открываем как «только просмотр».
            // Кадровые матрицы не грузим (формат мог измениться).
            var doc = ScanDocument(schemaVersion: manifest.schemaVersion, docId: manifest.docId,
                                   created: manifest.created, modified: manifest.modified,
                                   appVersion: manifest.appVersion, coreVersion: manifest.coreVersion)
            if let m = try? dec.decode(ScanMeta.self,
                    from: Data(contentsOf: url.appendingPathComponent("meta.json"))) {
                doc.meta = m
            }
            return Loaded(doc: doc, frames: [], measurements: [], defects: [],
                          url: url, newerSchema: true)
        }
        var doc = ScanDocument(schemaVersion: manifest.schemaVersion, docId: manifest.docId,
                               created: manifest.created, modified: manifest.modified,
                               appVersion: manifest.appVersion, coreVersion: manifest.coreVersion)
        doc.meta = (try? dec.decode(ScanMeta.self,
                from: Data(contentsOf: url.appendingPathComponent("meta.json")))) ?? ScanMeta()

        struct FrameMeta: Codable { var frame: FrameSnapshot; var sha256Temp: String }
        var frames = [FrameSnapshot]()
        for ref in manifest.frames {
            let dir = url.appendingPathComponent(ref.dir)
            guard let meta = try? dec.decode(FrameMeta.self,
                    from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
            else { continue }
            var f = meta.frame
            if let d = try? Data(contentsOf: dir.appendingPathComponent("temp.f64")) {
                f.temp = d.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
            }
            if let d = try? Data(contentsOf: dir.appendingPathComponent("signal.u16")) {
                f.signal = d.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            }
            if let img = NSImageNoUI(contentsOf: dir.appendingPathComponent("rgb.png")) {
                f.rgb = img
            }
            // проверка хеша оригинала (DOC-05)
            if let d = try? Data(contentsOf: dir.appendingPathComponent("temp.f64")) {
                let h = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
                if h != meta.sha256Temp { f.validityRule += "; HASH-MISMATCH" }
            }
            frames.append(f)
        }
        let meas = (try? dec.decode([Measurement].self,
            from: Data(contentsOf: url.appendingPathComponent("measurements.json")))) ?? []
        let defects = (try? dec.decode([Defect].self,
            from: Data(contentsOf: url.appendingPathComponent("defects.json")))) ?? []
        return Loaded(doc: doc, frames: frames, measurements: meas, defects: defects,
                      url: url, newerSchema: false)
    }

    // MARK: PNG рендера

    static func rgbPNG(_ rgb: [UInt8]) -> Data {
        RepKit.png(fromRGB: rgb, w: 320, h: 240)
    }
    static func rgb(fromPNG data: Data) -> [UInt8] {
        RepKit.rgb(fromPNG: data, w: 320, h: 240)
    }
}

/// PNG helpers без SwiftUI (AppKit допустим; Foundation-тесты их не зовут).
enum RepKit {
    static func png(fromRGB rgb: [UInt8], w: Int, h: Int) -> Data {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i*4] = rgb[i*3]; rgba[i*4+1] = rgb[i*3+1]; rgba[i*4+2] = rgb[i*3+2]
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
        memcpy(rep.bitmapData!, rgba, rgba.count)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
    static func rgb(fromPNG data: Data, w: Int, h: Int) -> [UInt8] {
        guard let rep = NSBitmapImageRep(data: data) else { return [] }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let i = (y * w + x) * 3
            out[i] = UInt8(c.redComponent * 255)
            out[i+1] = UInt8(c.greenComponent * 255)
            out[i+2] = UInt8(c.blueComponent * 255)
        }}
        return out
    }
}

import AppKit

private func NSImageNoUI(contentsOf url: URL) -> [UInt8]? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    let rgb = RepKit.rgb(fromPNG: d, w: 320, h: 240)
    return rgb.isEmpty ? nil : rgb
}
