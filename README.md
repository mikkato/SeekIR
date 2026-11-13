# SeekIR

Тепловизор-приложения для Seek Thermal CompactPRO FastFrame (`289d:0011`, PIR324, сенсор 320×240 VOx).

## Структура
- `docs/ТЗ.md` — **ТЗ v1.1 (главный документ)**: F1–F9, baseline фильтров, состояние E0, эксплуатационные правила, протокол (Приложение А), точка входа для E1
- `core/` — общее C-ядро: USB-протокол, FF/hotmap, радиометрия (Планк), палитры (E1)
- `macos/` — Swift/SwiftUI клиент, libusb (E2)
- `android/` — Kotlin/Compose клиент, USB Host API + JNI (E3)
- `tools/` — **работающий Python-прототип (E0 ✅)**:
  - `capture.py` — SeekPro: init/захват/reconnect/hotmap
  - `view.py` — GUI live-viewer: палитры 1–5, Space=freeze, S=снимок, A=auto-span, ползунки постобработки
  - `hotpixels.npy` — карта шума матрицы (0.65%, снята по 60 авто-FF)
  - `viewer_settings.json` — утверждённый baseline: smooth 0.75 / motion 440 / spatial 75
  - `samples/` — golden-кадры; `vendor-libseek/` — эталон протокола (C++)
- `assets/palettes/` — LUT палитр 256×1 RGB (заполняется на E1)

## Запуск
```
pip3 install pyusb numpy pillow   # libusb: brew install libusb (уже стоят)
cd ~/Desktop/SeekIR/tools && python3 view.py
```
⚠️ Камера только в прямой порт Mac. Остановка — закрыть окно или `kill -TERM` (НЕ `kill -9` — иначе power-cycle кабеля).


## macOS-приложение «Термография» (ТЗ macOS26, P0)
Сборка:
```
cd ~/Desktop/SeekIR && make -C core all usb && bash macos/build.sh
open macos/build/SeekIR.app        # точка входа InspectionApp (старый E2 SeekIRAppLegacy отключён)
```
Тесты (без камеры): `bash macos/run_tests.sh` — синтетическая матрица: измерения,
координаты zoom/pan (включая повороты 0/90/180/270), документ .seekscan round-trip, guard версии схемы
(51 проверка, 0 провалов).
Live-захват CLI (baseline): `./core/build/seekd --secs 8 --hotmap core/tests/hot.bin --dump /tmp/dump`

Возможности P0: live PIR324, палитры/диапазон, точка/область/линия/diff, таблица
измерений, undo/redo (⌘Z/⇧⌘Z, меню «Измерения»), снимок в документ (⌘3 / toolbar),
документ .seekscan (сохранить/открыть без камеры), условия обследования, ползунки
постобработки (F9: smooth/motion/spatial, UserDefaults `ru.mytolm.seekir`), дефекты,
PDF A4 (предпросмотр на странице «Отчёт») / PNG / CSV (UTF-8 BOM, `;`) / температурная матрица.
UI: название «Термография» (окно, меню, Dock), заголовок по центру строкой выше тулбара
(`titleVisibility = .visible`, `toolbarStyle = .expanded` — без капсулы), поворот кадра
270° (только отображение), пропорции канваса ровно 3:4/4:3 без растяжения,
пиктограмма в Dock (Resources/AppIcon.icns).
Ядро C не изменено; sandbox выключен (USB через libusb напрямую).
Скриншоты: `docs/screenshots/ui-final-thermography.png`, `docs/screenshots/dock-icon.png`.
Документация: `docs/core-audit.md`, `docs/baseline.md`, `docs/ui-architecture.md`,
`docs/implementation-plan.md`.

## Статус
- [x] E0: протокол, живые кадры, FF, карта шума, baseline фильтров (утверждён пользователем), F7 reconnect
- [ ] E1: C-ядро (цепочка F9 1-в-1 + async libusb) → E2: Mac-app → E3: Android → E4: видео/экспорт → E5: изотермы/отчёты

## Открытые вопросы
- Модель Android-телефона (критично для E3: OTG-питание)
- ~~Финальное имя приложения~~ — принято: UI «Термография» (bundle id `ru.mytolm.seekir`, binary SeekIR)
