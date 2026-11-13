// ReportPanel.swift — страница «Отчёт»: сводка, экспорт PDF/PNG/CSV/матрица, PDF-превью.
import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct ReportPanel: View {
    @EnvironmentObject var model: InspectionModel
    @State private var busy = false
    @State private var lastPDF: URL?
    @State private var previewURL: URL?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Сводка обследования") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Объект", model.doc.meta.title.isEmpty ? "—" : model.doc.meta.title)
                        row("Площадка", model.doc.meta.site)
                        row("Исполнитель", model.doc.meta.inspector)
                        row("Снимков", "\(model.frames.count)")
                        row("Измерений", "\(model.measurements.count)")
                        row("Дефектов", "\(model.defects.count)")
                        row("Единицы отчёта", model.units.suffix)
                        row("PDF-кадры", "видимой камеры нет — фотоснимков не будет (REP-05)")
                    }
                    .padding(6)
                }
                HStack {
                    Button("Сформировать PDF…") { export(.pdf) }
                        .keyboardShortcut("e", modifiers: .command)
                        .disabled(model.frames.isEmpty || busy)
                    Button("PNG текущего кадра…") { export(.png) }
                        .disabled(currentFrame == nil || busy)
                    Button("CSV измерений…") { export(.csv) }
                        .disabled(model.measurements.isEmpty || busy)
                    Button("Матрица °C (.f64)…") { export(.matrix) }
                        .disabled(currentFrame == nil || busy)
                }
                if busy { ProgressView("Экспорт…").controlSize(.small) }
                if let u = lastPDF {
                    HStack {
                        Text("Последний PDF: \(u.lastPathComponent)")
                            .font(.caption).textSelection(.enabled)
                        Button("Открыть") { NSWorkspace.shared.open(u) }.controlSize(.mini)
                    }
                }
                Text("PDF фиксирует данные на момент экспорта; повторный экспорт создаёт новый документ (REP-06).")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
            }
            .padding(12)
            .frame(minWidth: 360)
            .frame(maxWidth: 480)

            Group {
                if let u = lastPDF ?? previewURL, let doc = PDFDocument(url: u) {
                    PDFPreview(document: doc)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.richtext").font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Сформируйте PDF — предпросмотр появится здесь")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onAppear { if previewURL == nil { refreshPreview() } }
        .onChange(of: model.frames.count) { _, _ in refreshPreview() }
        .onChange(of: model.measurements.count) { _, _ in refreshPreview() }
        .onChange(of: model.defects.count) { _, _ in refreshPreview() }
    }

    /// Предпросмотр строится в temp из ТЕКУЩИХ данных; экспорт в файл — отдельная операция (REP-06).
    private func refreshPreview() {
        guard !model.frames.isEmpty, !busy else { return }
        busy = true
        let dd = collectReportData(model)
        let e = model.engine
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seekir_preview_\(UUID().uuidString.prefix(8)).pdf")
        Task.detached(priority: .utility) {
            do {
                try ReportService.exportPDF(data: dd, engine: e, to: url)
                await MainActor.run { previewURL = url; busy = false }
            } catch {
                await MainActor.run { busy = false }   // превью не блокирует работу
            }
        }
    }

    private var currentFrame: FrameSnapshot? {
        model.selectedFrame ?? model.frames.last
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).foregroundColor(.secondary)
            Text(v.isEmpty ? "—" : v).textSelection(.enabled)
            Spacer()
        }.font(.system(size: 11))
    }

    private enum Kind { case pdf, png, csv, matrix }

    private func export(_ kind: Kind) {
        busy = true
        let name: String
        switch kind {
        case .pdf: name = (model.doc.meta.title.isEmpty ? "Отчёт" : model.doc.meta.title) + ".pdf"
        case .png: name = (model.doc.meta.title.isEmpty ? "Термограмма" : model.doc.meta.title) + ".png"
        case .csv: name = (model.doc.meta.title.isEmpty ? "Измерения" : model.doc.meta.title) + ".csv"
        case .matrix: name = (model.doc.meta.title.isEmpty ? "Матрица" : model.doc.meta.title) + ".f64"
        }
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        if let t = UTType(filenameExtension: name.split(separator: ".").last.map(String.init) ?? "bin") {
            p.allowedContentTypes = [t]
        }
        guard p.runModal() == .OK, let url = p.url else { busy = false; return }
        let dd = collectReportData(model)
        let e = model.engine
        let frame = currentFrame
        Task.detached(priority: .userInitiated) { [weak model] in
            do {
                switch kind {
                case .pdf: try ReportService.exportPDF(data: dd, engine: e, to: url)
                case .png:
                    guard let f = frame else { throw ReportError.noFrame }
                    try ReportService.exportPNG(data: dd, engine: e, frame: f, to: url)
                case .csv: try ReportService.exportCSV(data: dd, to: url)
                case .matrix:
                    guard let f = frame else { throw ReportError.noFrame }
                    try ReportService.exportTempMatrix(frame: f, to: url)
                }
                await MainActor.run {
                    if kind == .pdf { lastPDF = url }
                    busy = false
                    NSSound.beep()
                }
            } catch let er as AppError {
                await MainActor.run { busy = false; model?.lastError = er }
            } catch {
                await MainActor.run {
                    busy = false
                    model?.lastError = AppError(kind: .writeFailed,
                                                userText: "Экспорт не выполнен.",
                                                savedDataText: "Документ обследования не изменён.",
                                                actionText: "Повторите экспорт.",
                                                technical: String(describing: error))
                }
            }
        }
    }
    enum ReportError: Error { case noFrame }
}

struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = document
        v.displayMode = .singlePageContinuous
        v.autoScales = true
        v.backgroundColor = .underPageBackgroundColor
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) { v.document = document }
}
