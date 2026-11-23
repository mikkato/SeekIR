# Архитектура Windows-версии SeekIR («Термография» для Windows 11)

Документ: архитектурное исследование (ROLE: архитектор).
Дата: 23.11.2026. Статус: отчёт к решению; ничего не устанавливалось, код не изменялся.
Объект: Seek Thermal CompactPRO FastFrame (`USB\VID_289D&PID_0011`, сенсор PIR324, 320×240 VOx, ~7 к/с в текущем конвейере, bulk-эндпоинт 0x81, чанк 13 680 Б, кадр 342×260 u16 LE = 177 840 Б).
Основа: `docs/ТЗ.md` (F1–F9), `docs/core-audit.md` (AUD-01…06), `core/usb/seekcap.{h,c}` (асинхронный libusb-конвейер, проверен на macOS: 6.9 к/с, 0 ошибок), `core/include/seekcore.h` (побитовый эталон F9).

## 0. Резюме и рекомендации (одним разделом)

| # | Вопрос | Рекомендация |
|---|---|---|
| 1 | Транспорт | **libusb-1.0 (WinUSB-бэкенд поверх inbox winusb.sys)** с существующим INF `{3bc8a9c6-…}`. Отказ от libusb-win32. Нативный WinUSB API — только как план «Б» при упоре в лимиты libusb |
| 2 | UI-стек | **WPF (.NET 10, C#) + P/Invoke (`LibraryImport`) к нативной DLL-обёртке `seekcap.dll`**; рендер `WriteableBitmap` + векторные оверлеи. Альтернатива второго ряда — Avalonia |
| 3 | Слои | Сохранить macOS-раскладку 1-в-1: транспорт+поток (seekcap) / чистое C-ядро (seekcore) / рантайм-настройки (в seekcap под мьютексом) / UI-клиент. Новый слой только один — межъязыковой интероп-шлюз |
| 4 | Потоки | Один worker-поток: pump `libusb_handle_events_timeout_completed` + все control-трансферы. Control **никогда** из callback и из UI-потока. Очередь bulk поднять с 1 до 2–4 URB |
| 5 | Миграция | 6 этапов W0–W5 от сборки DLL до упаковки; ключевые риски — подпись INF, сон/пробуждение, поведение WinUSB-бэкенда при multi-thread control (см. §4) |

Обоснование — ниже по пунктам TASK.

## 1. Транспорт

### 1.1 Варианты

**A. libusb-1.0 поверх WinUSB (рекомендуется).**
Стек: `libusb-1.0.dll → winusb.dll → winusb.sys` (inbox, подписан Microsoft). Уже на машине: `D:\LSDF\toolchains\msys2\ucrt64\bin\libusb-1.0.dll`; `seekd.exe` собран и golden-тесты пройдены. Согласно FAQ libusb, если `libusbK.dll` не установлена рядом, Windows-бэкенд libusb говорит с драйвером WinUSB напрямую через WinUSB API ([libusb FAQ](https://github.com/libusb/libusb/wiki/FAQ)) — то есть это «нативный WinUSB» с переносимым API, без second source транспорта. Наш INF (`driver/winusb-seek/seek-thermal-winusb.inf`) — эквивалент генерируемого libwdi/Zadig: опирается на inbox `winusb.inf`, фиксирует Device Interface GUID `{3bc8a9c6-4581-4cd9-b325-f39bf0a95ee0}`. Фиксация GUID обязательна: libusb Windows-бэкенд перечисляет устройства по interface GUID, и для корректной работы он должен присутствовать в реестре ([libusb wiki Windows → Known Restrictions, пункт про composite/GUID](https://github.com/libusb/libusb/wiki/Windows); проблема «Zadig генерирует случайный GUID при переустановке» описана в [libwdi issue #219](https://github.com/pbatard/libwdi/issues/219) — наш INF этого недостатка лишён).

Практика сообщества подтверждает работоспособность связки именно для Seek: OpenThermal/libseek-thermal собирается под Windows на libusb-1.0, драйвер ставится Zadig'ом (WinUSB или libusb-win32 на интерфейсе «iAP Interface») ([README](https://github.com/OpenThermal/libseek-thermal)); yaqd-seek рекомендует WinUSB(libusb) через Zadig ([README](https://github.com/yaq-project/yaqd-seek)); PlusLib для CompactPRO требует «только WinUSB-драйвер» ([DeviceInfraredSeekCam.md](https://github.com/PlusToolkit/PlusLib/blob/master/docs/devices/DeviceInfraredSeekCam.md)). Наш протокол (init-последовательность vendor control + cmd 83 + 13×13680 bulk) уже верифицирован этим же C-кодом на железе — транспортная ветка минимальна.

**B. Нативный WinUSB API (WinUsb_ReadPipe/WritePipe + WinUsb_ControlTransfer).**
Даёт контроль над pipe-политикой (`RAW_IO`, `SHORT_PACKET_TERMINATION`, длина очереди `PIPE_TRANSFER_COUNT` через `WinUsb_SetPipePolicy` — см. [WinUsb_ReadPipe, overlapped-семантика](https://learn.microsoft.com/en-us/windows/win32/api/winusb/nf-winusb-winusb_readpipe)) и избавляет от слоя libusb. Но: (а) дублирование транспорта — теряется единый `seekcap.c` для macOS/Windows, а побитовая идентичность кадра — принятое проектное требование (ТЗ §5); (б) все известные преимущества (очередь, RAW_IO) в libusb-бэкенде для нашего профиля нагрузки не требуются — 177 840 Б/кадр × 7 к/с ≈ 1,2 МБ/с при пропускной способности USB 2.0 HS bulk ~35–40 МБ/с; (в) свой event-loop на IOCP вместо `libusb_handle_events`. Целесообразно только как план «Б», если обнаружится дефект WinUSB-бэкенда libusb на нашей прошивке.

**C. libusb-win32 (libusb0.sys) — отклонить.** Сам libusb-проект не рекомендует libusb0.sys («not recommended to be used due to multiple issues reported», плюс дефект control-трансферов с wLength=0 в 1.2.6.0 — [libusb wiki Windows]). Это же ядро проблем отмечено и в README libseek-thermal, где libusb-win32 указан лишь как исторический путь Zadig'а.

**D. libusbK / usbdk — отклонить.** libusbK требует свой подписанный драйвер (libusbk.sys) — лишает преимущества inbox-пакета; нужен лишь для многопроцессного доступа или изохронных. usbdk — сценарий разделения шины/отладки, лишний системный драйвер. Нас устраивает одновладельный доступ (см. §4.4).

### 1.2 Риски транспорта на Windows

| Риск | Суть | Митигция |
|---|---|---|
| Multi-thread control | На Windows зафиксированы краши при вызове `libusb_control_transfer()` из потока, отличного от pump-потока, пока тот обслуживает bulk ([libusb issue #186](https://github.com/libusb/libusb/issues/186)); официально многопоточная модель описана в [libusb MT/async guide](https://libusb.sourceforge.io/api-1.0/libusb_mtasync.html) | Сохранить действующее правило seekcap: **все control-команды только из worker-потока (pump)**; UI-сеттеры пишут только данные под мьютексом (уже так). Не вводить control-вызовы из UI до снятия риска тестом W2 (§5) |
| wIndex-interface | WinUSB-бэкенд принудительно подставляет младший байт `wIndex` = номер интерфейса при `RECIPIENT_INTERFACE` ([libusb wiki](https://github.com/libusb/libusb/wiki/Windows)) | Не влияет: наши vendor-команды идут с wIndex=0 (проверено по `cmd_out/cmd_in` в seekcap.c) |
| set_configuration | WinUSB/libusbK не могут выбрать конфигурацию, отличную от первой ([там же]) | Не влияет: у камеры одна конфигурация, `libusb_set_configuration(h, 1)` — совпадение с дефолтом |
| Ре- enumeration / GUID | переустановка драйвера (Zadig) поверх нашего INF может сменить GUID и «потерять» устройство из перечисления | В поставляемой инструкции — только наш `install.ps1`; диагностика «устройство видно в PnP, но не в перечислении libusb» с подсказкой переустановить наш INF |
| Подпись INF | Windows 11 с включённой целостностью загрузки может отказать в установке неподписанного INF класса USB через `pnputil` | См. §5 (W3): варианты — подпись каталога (EV-сертификат), либо инструктировать установку тем же путём, каким libwdi ставит self-signed (доверенный корень), либо на стенде — `bcdedit /set testsigning on`. Риск принять как единственный внешний блокер |
| Sleep/hibernate mid-stream | USB-стек гасит порт; handle становится протухшим | Штатный reconnect-цикл worker'а (1 с) уже это переживёт; добавить реакцию на `WM_WTSSESSION_CHANGE`/`CM_Register_Notification` (W4) — прогон TEST-05 на Windows-стенде |
| `kill -9` / зависший стрим | Прошивка остаётся в streaming, control pipe виснет (набеджено на macOS) | Корректное завершение приложения (close → 60[00]×3) + единственный экземпляр (см. 4.4); reset не использовать (запрет уже в код-базе) |

Асинхронные vs синхронные bulk: синхронный `libusb_bulk_transfer` (как в Python-прототипе, потолок 5–9 к/с) на Windows даст те же паузы между чанками; асинхронный конвейер с callback — единственный способ держать ровные ~7 к/с и корректный resync. Переносить следует именно URB-конвейер seekcap.c, с увеличением глубины (§4.2).

## 2. UI-стек для Windows

Профиль нагрузки: 320×240 RGB (921 600 Б/кадр) при ~7 к/с входящих, отрисовка «последним кадром» (ТЗ F1), зум/pan/поворот канваса, векторные оверлеи измерений (до 5 зондов, боксы, линии, гистограмма), плотный «инструментальный» UI, RU/EN.

Критерии оценки: латентность рендера, доступ к C-ядру, дистрибуция, стоимость поддержки.

| Критерий | WinUI 3 | **WPF (.NET)** | Qt 6 | Avalonia 11 | Win32+DirectX |
|---|---|---|---|---|---|
| Латентность (7 fps + оверлеи) | достаточно | достаточно (WriteableBitmap.WritePixels, 0.9 МБ — микросекунды-миллисекунды) | достаточно | достаточно (Skia) | избыточно |
| P/Invoke к C DLL | Marshalling, но UI-thread-модель Composition | **LibraryImport (source-gen), свободные callback-потоки** | C++/CLI или own wrapper (Qt — C++) | LibraryImport так же | прямой link |
| Зум/pan/поворот канваса | ScrollViewer+Transforms, сыровато | LayoutTransform/RenderTransform, NearestNeighbor-апскейл — отработано | QGraphicsView — хорошо | Skia-трансформации — хорошо | всё вручную |
| Плотный desktop-UI (таблицы, мастер калибровки, PDF-отчёт) | ограничения DataGrid/печати | **зрелые DataGrid, документы, печать** | мощный, но свой стиль не-Windows | покрывается сторонними либами | неприемлемо дорого |
| Дистрибуция | MSIX/bootstrapper, Runtime-зависимости | self-contained single-folder publish, анинсталлируемый exe | дедлайны LGPL + windeployqt, тяжело | self-contained, но менее зрелый packaging | — |
| Риск | Active development, API-дрейф | минимальный (15+ лет стабильности) | лицензионный + вес | средний | максимальный |

**Рекомендация: WPF на .NET 10** (SDK 10.0.403 и WindowsDesktop.App 10.0.14 на машине — см. `D:\LSDF\VERSIONS.txt`). 7 к/с — на два порядка ниже возможностей WPF-композитора; узкое место «камера→экран ≤150 мс» (ТЗ F1) выполняется с запасом: transport→callback→копирование в WriteableBitmap→composition ≈ единицы мс после USB-задержки.

Форма доступа к C-либе: **P/Invoke (`System.Runtime.InteropServices.LibraryImport`, .NET 7+ source-generated) к тонкой нативной DLL `seekcap.dll`** — экспорт `skcap_*` практически без изменений (см. §3). Сравнение альтернатив:
- C++/CLI — привязывает к MSVC-тулчейну и смешанной сборке, лишает переиспользования одной и той же DLL с другими клиентами; отклонить.
- pybind + Python — прототипная ветка, в продукт не принимается (сам ТЗ относит tools/ вне поставки).
- Чистый C# (переписать транспорт на WinUsbDotNet-подобный, как в историческом [winusbdotnet/TestSeek](https://github.com/sgstair/winusbdotnet) и списке клиентов [seek-thermal-documentation](https://github.com/lod/seek-thermal-documentation/wiki/Clients)) — означал бы вторую реализацию протокола и потерю побитовой совместимости с golden-тестами. Отклонить.

Пограничные детали интеропа: callback из нативного worker-потока → в C# копируем rgb/temp/signal в pinned-буферы (double/triple buffering) и публикуем кадр через `Dispatcher.BeginInvoke`/`CompositionTarget.Rendering` (аналог dispatch-on-main в macOS-клиенте). Буферы колбэка валидны только во время вызова (AUD-03) — немедленное копирование обязательно, как и в `Engine.onFrame` на macOS.

**Avalonia — принятая альтернатива второго ряда**, если позже потребуется Linux; архитектурно слой UI от этого не зависит (тот же P/Invoke-контракт).

## 3. Границы слоёв и сравнение с macOS-схой

Целевая раскладка (изменения против macOS — только слой L2'):

```
L4 UI           macos/: SwiftUI Inspection/*        →  win/: WPF Inspection/* (C#)
L3 интероп      bridging.h (прямые вызовы skcap_*)  →  seekcap.dll + LibraryImport + FrameChannel (копирование кадров)
L2 рантайм      skcap_set_* под pthread_mutex       →  без изменений (winpthread или Win32 critical section)
L1 ядро         libseekcore.a (чистый C11, libc)    →  идентичный код → seekcore.lib/dll; golden-тесты те же
L0 транспорт    seekcap worker: libusb pump + FF-map→ →  тот же код; libusb/WinUSB-бэкенд; mkdir()/clock_gettime через UCRT
```

Инварианты, которые должны пережить миграцию (нарушение = расхождение измерений между платформами):
1. **Побитовая цепочка F9** в L1: порядок операций и dtype-режим (`-ffp-contract=off` обязателен и под gcc/Windows; для MSVC-сборки — контракт отключается выбором gcc, см. W0).
2. **Единственный владелец кадрового состояния — worker-поток**; UI только читает скопированные кадры и пишет настройки атомарно (AUD-02: сеттеры потокобезопасны).
3. **API захвата не меняется**: `skcap_open/close`, 5 сеттеров, Planck-мастер, stats — интерфейс интероп-шлюза совпадает с `seekcap.h`, что даёт параллельное развитие mac/win без форка протокольной логики.
4. Зонды/документы/PDF — L4-логика поверх temp-матрицы f64 (L1 не знает про UI), как в macOS P0 (implementation-plan, итерации 3–5).

Отличия от macOS-схожи, которые надо заложить явно:
- на macOS sandbox выключен и libusb лежал в приложении; на Windows вместе с приложением ставятся `libusb-1.0.dll`, `libwinpthread-1.dll`, `seekcap.dll`, INF-пакет — состав поставки фиксируется в W5;
- macOS-Engine использовал NSLock; в C# копия кадра выполняется под тем же замком, что и публикация «latest frame» (замыкает гонку freeze/snapshot).

## 4. Потоковая модель на Windows

### 4.1 Схема (перенос с darwin с изменениями)

```
[worker-поток seekcap]
  цикл: open/reconnect → submit_chunk → libusb_handle_events_timeout(20 мс) → pump()
  pump(): сборка кадров по magic 1401 → process_frame (L1) → cb() → request_frame (control OUT 83)
  все control-трансферы (инициализация, cmd 83, close 60) — только здесь.
[callback chunk_cb]
  только буферизация + submit следующего URB (без control — правило darwin-BUSY сохраняется).
[UI-поток WPF]
  Dispatcher; рисует последний опубликованный кадр; настройки — сеттеры под мьютексом.
```

### 4.2 Отличия/настройки под Windows

1. **Глубина очереди bulk: 1 → 2–4 URB.** На macOS один URB в полёте дал 6.9 к/с; на Windows стоимость resubmit-раунда выше (WinUSB-пакет через IRP-очередь). Чанки одного эндпоинта обслуживаются хост-контроллером FIFO, порядок байт не нарушается; ресинк по magic уже устойчив к перекрытию. Проверить на W2 замером fps/errors при глубинах 1/2/4 (эталонное окно: ≥6.5 к/с, errors=0 за 30 мин).
2. **Control из чужого потока — не воспроизводить вслепую.** На darwin это давало LIBUSB_ERROR_BUSY; на Windows задокументирован более тяжёлый сценарий — краш при control из потока, отличного от event-handling ([issue #186](https://github.com/libusb/libusb/issues/186)), поэтому архитектура сознательно оставляет control однопоточным в worker'е; тест «UI-инициированная команда через очередь в worker» (постановка задачи через mutex + флаг, исполнение pump'ом) — штатный путь для будущих команд (FF manually, если payload cmd 55 будет верифицирован; пока запрещена эксплуатационным правилом).
3. **Нет poll()-дескриптора на Windows** (`libusb_get_pollfd` возвращает ошибку — [wiki Known Restrictions]): схема «таймаутный handle_events в своём потоке» — единственная верная, она же уже реализована.
4. **Hotplug/reconnect**: перечисление libusb на Windows опирается на interface GUID нашего INF; цикл «раз в 1 с открыть по VID:PID» (нынешний worker) работает без изменений. Дополнительно подписаться на WM_DEVICECHANGE в UI для мгновенной индикации отключения (F7, ≤3 с — выполняется текущим циклом).
5. **Завершение**: `skcap_close` остаётся штатным путём (quit→join→drain 20×20 мс→close_cam→libusb_close). WinUSB закрывает pipe при close handle — «осиротевший стрим» после crash всё равно возможен: единственный экземпляр приложения (§4.4) + запрет hard-kill снижают вероятность до уровня macOS-правил.

### 4.3 Тайминги

Кадр = 13 чанков; при depth≥2 конвейер непрерывен. Control cmd 83 (~<1 мс) выполняется pump'ом сразу после доставки последнего чанка — задержка на порядок меньше кадра (143 мс). Худший случай инициализации (80 × control-пар при open) ≈ несколько сотен мс — допустимо (первый кадр ≤ 2 с).

### 4.4 Одновладельность

WinUSB не поддерживает несколько одновременных приложений ([wiki Known Restrictions](https://github.com/libusb/libusb/wiki/Windows)). Именованное системное мьютекс-«ядро» (`Local\SeekIR.Camera`) в seekcap.dll на open + вежливая диагностика «камера занята другим процессом» — программная реализация эксплуатационного правила «один процесс = один владелец».

## 5. План миграции E1→Windows (этапы, выходы, риски)

Базовое состояние принято как есть: C-ядро компилируется под Windows (кроме mkdir, уже починено), seekd.exe и golden-тесты работают, INF собран.

| Этап | Содержание | Критерий выхода | Основные риски |
|---|---|---|---|
| **W0. Сборка** | CMake (или Makefile-win) для `seekcore`/`seekcap` → стат./динам. библиотека под UCRT gcc; pthread→winpthread линковка (или тонкий shim Win32 CRITICAL_SECTION/thread); флаги `-ffp-contract=off` зафиксировать в сборке | `seekd.exe` пересобран, golden-тесты: 29 952 000 Б выходов идентичны macOS-эталону | молчаливая FMA-оптимизация при смене тулчейна (митигция: CI-проверка флага + побитовый тест) |
| **W1. seekcap.dll** | Экспорт skcap_* через `__declspec(dllexport)`; ABI-контракт (cdecl, x64) зафиксировать заголовком `seekcap_exports.h`; именованный мьютекс одновладельности | DLL грузится из тестовой C#-консоли, 5-мин live, 0 errors | распад ABI при случайных правках (митигция: контрактный заголовок + версия API в stats) |
| **W2. Транспорт-стенд** | Live-захват на Windows: глубины URB 1/2/4, reconnect (выдернуть/воткнуть), сон/пробуждение, hub vs прямой порт; стресс 60 мин | ≥6.5 к/с стабильно; reconnect ≤3 с; dropped ≤2% (ТЗ §5); сбой WinUSB-бэкенда (issue #186-подобный) воспроизведён/исключён | **главный риск проекта**; план «Б» — нативный WinUSB-транспорт с тем же API L2 |
| **W3. Драйвер-UX** | Инсталлятор/скрипт: `install.ps1` (уже есть) + проверка подписи INF на чистом Win11, план подписи каталога либо документированная процедура | на чистой машине: подключение камеры → устройство в статусе OK с нашим GUID без ручных правок | отказ подписи при Secure Boot/политиках; временное решение — стендовый testsigning, продуктовое — EV-подпись |
| **W4. Интероп + live-viewer** | `LibraryImport`-обёртки; FrameChannel (pinned triple buffer); WPF-окно: WriteableBitmap NearestNeighbor, палитры, span, freeze, зонд; FPS-оверлей | parity с E0-прототипом: latency камера→экран ≤150 мс (замер высокоточным таймером по метке кадра) | гонки callback↔Dispatcher (митигция: публикуется только индекс готового слота) |
| **W5. Порт P0-функций + поставка** | Измерения/документ .seekscan (схема совместима с macOS), PDF/CSV/PNG-экспорт, ползунки F9, мастер Планка, RU/EN; self-contained publish + состав DLL + драйвер; автозапуск-тесты | все macOS-тесты перенесены (аналог run_tests.sh ≥51 проверка), RSS ≤500 МБ, 60-мин стресс | расхождение .seekscan-схемы (митигция: общий guard версии схемы из TEST-09) |

Порядок этапов жёсткий: W2 до начала UI — транспорт единственный непроверенный на этой связке Windows-подсистемы; UI — производная от стабильного L0/L1.

## 6. Источники

1. libusb wiki. Windows backend — ограничения WinUSB/libusbK/libusb0, GUID-требование, отсутствие pollfd: https://github.com/libusb/libusb/wiki/Windows
2. libusb wiki. FAQ — цепочка бэкендов (libusb→WinUSB напрямую без libusbK.dll): https://github.com/libusb/libusb/wiki/FAQ
3. libusb. Multi-threaded applications and asynchronous I/O (официальная MT-модель): https://libusb.sourceforge.io/api-1.0/libusb_mtasync.html
4. libusb issue #186 — краш control_transfer из чужого потока на Windows: https://github.com/libusb/libusb/issues/186
5. Microsoft Learn. WinUsb_ReadPipe (overlapped-семантика, pipe policy): https://learn.microsoft.com/en-us/windows/win32/api/winusb/nf-winusb-winusb_readpipe
6. libwdi/Zadig — генерация WinUSB-пакетов, Device Interface GUID; issue #219 (смена GUID при переустановке): https://github.com/pbatard/libwdi , https://github.com/pbatard/libwdi/issues/219
7. OpenThermal/libseek-thermal — сборка под Windows на libusb, Zadig (iAP Interface): https://github.com/OpenThermal/libseek-thermal
8. sgstair/winusbdotnet (TestSeek) — исторический C#/WinUSB клиент Seek: https://github.com/sgstair/winusbdotnet
9. seek-thermal-documentation wiki. Clients — обзор Windows-клиентов: https://github.com/lod/seek-thermal-documentation/wiki/Clients
10. yaqd-seek — установка WinUSB(libusb) через Zadig: https://github.com/yaq-project/yaqd-seek
11. PlusLib. DeviceInfraredSeekCam — «для Windows достаточно WinUSB-драйвера»: https://github.com/PlusToolkit/PlusLib/blob/master/docs/devices/DeviceInfraredSeekCam.md
12. Внутренние: docs/ТЗ.md (F1, F7, F9, §5, §6, Прил. А), docs/core-audit.md (AUD-02/03), docs/implementation-plan.md, core/usb/seekcap.c, driver/winusb-seek/*, D:\LSDF\VERSIONS.txt.
