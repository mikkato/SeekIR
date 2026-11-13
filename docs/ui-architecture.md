# Архитектура UI (ARC/UI/NAV/DOC контракты)

## Слои (ARC-02)

```
Application/Scenes/Commands   InspectionApp.swift (App, меню, Settings-сцена)
Presentation Models           InspectionModel (ObservableObject): режимы, selection,
                              состояние камеры (CAM), undo/redo, dirty
Application Services          MeasurementService (чистые функции), ProjectStore (.seekscan),
                              ReportService (PDF/PNG/CSV), L10n
ThermalCoreAdapter            Engine.swift (мост skcap, E2) + captureSnapshot()/frameID
Существующее ядро (НЕ ТРОГАНО) core/libseekcore.a + libseekcap.a + libusb
```

Ядро C не изменено ни на байт; в Engine.swift добавлены только: latestFrameID/stamp и
`captureSnapshot()` — независимый атомарный снимок rgb+temp+signal+span+planck под NSLock (ARC-07).
Live-рендер — текущий путь E2 (CoreGraphics-битмап, NEAREST-апскейл), Metal не вводится (ARC-08: рабочий рендер есть).

## Окно (NAV-01/05, UI-05)

NavigationSplitView: sidebar ≈220pt (Источник: Камера/Импорт; Обследование: Сведения,
Снимки, Оборудование, Дефекты, Отчёт) · центр: термограмма + colorbar в общей рамке (E2-спека) ·
trailing inspector ≈300pt · bottom панель: таблица измерений (скрывается). Мин. 1000×680,
стартовый 1440×900. Toolbar: режим (камера/анализ/отчёт), инструменты измерений, снимок,
заморозка, палитра, экспорт, inspector-toggle; все команды дублированы в menu bar.
Liquid Glass — только через системные компоненты (toolbar/split view), без самописного blur (UI-02).
Термограмма и подписи шкалы непрозрачны (UI-04); HOT/COLD — цветные риски на colorbar (E2-спека, значения не только цветом — UI-07).

## Состояния камеры (CAM-01…CAM-07)

AcquisitionState: notConnected → connecting → initializing → streaming ⇄ error(desc);断开 disconnecting→notConnected.
Управление: одна сессия (CAM-03: open/idempotent guard), повторное подключение доступно из error (CAM-05).
Заморозка — отдельный viewer-state (CAM-02), поток продолжает считываться. FPS отображения = кадр/с доставки
(colбэк), аппаратный потолок 15 Гц не заявляется выше факта (CAM-07).

## Координаты (VIEW-03)

FrameGeometry — единый источник преобразование view↔матрица (fit→zoom→pan, flipped-y-вниз =
row-major матрицы). Canvas и экспорт и тесты используют один struct. Retina не влияет (всё в points).

## Измерения (MEAS)

Геометрия хранится в координатах матрицы 320×240. Правила (MEAS-03, зафиксированы и покрыты тестами):
- rect: включаются все целочисленные пиксели x0≤x≤x1, y0≤y≤y1 (рамка включительно, нормализация x0≤x1);
- line: целочисленный Bresenham (детерминирован, без субпиксельной точности);
- point: 1 пиксель, индекс и температура;
- diff(A,B): ΔTmean, ΔTmax, ΔTmin для областей; для точек ΔT; смешивание кадров запрещено — измерения снимка привязаны к frameID (MEAS-07).
Невалидное значение: t ≤ −270 °C или NaN (аудит AUD-04). Пустая выборка → «Нет данных», не 0 (MEAS-06).

## Документ .seekscan (DOC)

Каталог-пакет `Имя.seekscan/`:
```
manifest.json     schemaVersion:1, docId, appVersion, coreVersion, created/modified, счётчики
frames/<id>/      meta.json, temp.f64 (f64 LE, 320×240), signal.u16 (u16 LE), rgb.png, sha256 в meta
measurements.json defects.json attachments/ reports/
```
Атомарная запись (tmp-каталог → replace), неизвестная schemaVersion → открытие без
перезаписи, оригинал не портится (DOC-07, TEST-09). Единицы ядра (°C f64, counts u16 LE)
сохраняются как есть; перевод единиц — только отображение (DATA-05).

## Отчёт (REP)

PDF A4 (Core Graphics): титул → объект/условия → прибор/калибровка → карточка на кадр
(термограмма с оформлением + colorbar + таблица измерений + применённые параметры + комментарий)
→ дефекты/рекомендации → ограничения. Переносы слов, повтор заголовков таблиц на разрыве,
footer с exportId/датой/версией. PNG — 1600×1200 NEAREST + оформление. CSV — UTF-8 BOM,
`;` разделитель, точка как десятичная (проверено против рус. Excel), заголовки и единицы.
Видимой камеры нет — фото-плейсхолдеров нет (REP-05); вложения — только явно добавленные файлы.

## Ошибки (ERR)

AppError{kind: cameraAbsent/busy/initFailed/streamLost/noTemperature/writeFailed/docCorrupt/docVersionNew,
userText(RU), savedDataText, actionText, technical}. Alert с раскрытием «Подробности» (ERR-02).
Диагностика: `[SeekIR]`-лог с timestamp+sessionId в памяти (кольцевой 2000) + os_log; экспорт — только по команде (ERR-04).

## Локализация (UI-08)

Строки через L10n.t(key) → ru.lproj/Localizable.strings (дефолт) / en.lproj. Русский — базовый язык разработки.
