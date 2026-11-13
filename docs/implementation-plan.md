# План реализации и статус (ТЗ П0, раздел 16)

| Итерация | Объём | Статус |
|---|---|---|
| 0 | Аудит, baseline, архитектура | ✅ docs/core-audit.md, docs/baseline.md, docs/ui-architecture.md |
| 1 | Окно, sidebar, inspector, меню, настройки, пустые состояния | ✅ SeekIR.app: NavigationSplitView, toolbar, menu bar (без дублей), Настройки (⌘,), пустые состояния |
| 2 | Адаптер, live, палитры, диапазон, отключение, атомарный снимок | ✅ live PIR324 6.9 к/с в UI, Engine.captureSnapshot() (NSLock), палитры/авто-ручной диапазон; проверено скриншотами |
| 3 | Координаты, измерения, таблица, профиль, undo/redo | ✅ точка/область/линия/diff, таблица+синхрон selection, undo/redo; TEST-02/03: 42 проверок 0 провалов |
| 4 | Документ .seekscan, сохранение/открытие, метаданные | ✅ round-trip тест: f64 побитово, геометрия, sha256, newerSchema guard (TEST-04/09) |
| 5 | Дефекты, PDF, PNG, CSV | ✅ PDF A4 титул/кадры/таблицы, PNG с оверлеями, CSV UTF-8 BOM `;`, матрица .f64 |
| 6 | Аппаратные тесты, accessibility, документация | 🔄 baseline+autotests (51/0), RSS-монитор пройден (~212–260 МБ, без роста); сон/пробуждение, VoiceOver — требуется прогон на стенде |
| 7 | Правки приёмки пользователя | ✅ переименование UI в «Термография» + заголовок по центру без капсулы (`toolbarStyle = .expanded`, principal-капсула убрана); рамка просмотра точно по видео+шкале; пропорции 3:4 проверены попиксельно (0.758≈0.75); фикс краша удаления (bindings по id вместо индекса); ⌘Z/⇧⌘Z+удаление в меню; снимок ⌘3; статистика на стр. «Отчёт» по frameId; иконка Dock (lsregister+killall Dock) |

## Известный дефект среды и обход (фикс в коде)
SwiftUI-окно иногда регистрируется в AppKit (видно в меню «Окно»), но не попадает в
WindowServer — приложение запускается без окна. Обход: `ForceFrontWindow.bring()`
(activate + makeKeyAndOrderFront + orderFrontRegardless + titleVisibility=.hidden)
в `onAppear` корневой сцены (`InspectionApp.swift`).

## Состав поставки (plan)
- Исходники: `macos/Sources/Inspection/*`, патчи `Engine.swift`/`ContentView.swift`, `macos/build.sh`
- Тесты: `macos/Tests/main.swift` + `macos/run_tests.sh` (TEST-02/03/04/09: 42 проверки, 0 провалов)
- Схема документа: docs/ui-architecture.md §.seekscan + manifest schema в коде
- Руководство запуска: README-секция в docs/baseline.md / README.md
- Разрешения: без sandbox (USB через libusb напрямую — как в working E2); ad-hoc подпись. Sandbox
  не включать ценой поломки камеры (ARC-09).

## Известные ограничения P0 (фиксирую честно)
- Полная локализация EN — каркас (.strings), покрытие строк может быть частичным.
- Сон/пробуждение mid-stream, два окна на одну камеру, 30-мин live — аппаратные сценарии,
  помечены «не проверено» до прогона на стенде (TEST-05/07).
- P1-функции (сравнение, эллипс/полигон, шаблоны отчётов) не включены.
