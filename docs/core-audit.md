# Аудит ядра SeekIR (AUD-01…AUD-05)

Дата: 05.11.2026. Проведён по фактическому коду `~/Desktop/SeekIR`, не по публичным спецификациям Seek.

## AUD-01. Сборка, точки входа, языки, архитектуры

| Компонент | Путь | Язык | Сборка |
|---|---|---|---|
| Ядро обработки | `core/src/{frame,denoise,tonemap,palettes,radiometric}.c` | C11 (только libc) | `make -C core all` → `core/libseekcore.a`, CLI `core/build/seekproc` |
| Захват USB | `core/usb/{seekcap.c,seekd.c}` | C11 + libusb-1.0 (brew) | `make -C core usb` → `core/libseekcap.a`, CLI `core/build/seekd` |
| GUI E2 | `macos/Sources/{Engine,ContentView}.swift`, `bridging.h` | Swift (swiftc, без Xcode-проекта) | `bash macos/build.sh` → `macos/build/SeekIR.app` |
| Python-эталон | `tools/capture.py`, `tools/view.py`, `core/tests/ref_pipeline.py` | Python + numpy | не входит в поставку приложения |

Обязательный флаг ядра: `-ffp-contract=off` (FMA ломает побитовую совместимость с эталоном).
Архитектура сборки: нативная (arm64 на этой машине, Xcode 27.2 / macOS 27.2 SDK). Минимальная ОС в Info.plist: 13.0.

## AUD-02. Реальные API подключения / кадра / калибровки / настроек

Все символы — `core/usb/seekcap.h` (продуктовый API E2, обёртка над URB-конвейером seekd):

- `skcap_open(cb, user, hotmap_path) -> skcap_t*` — поиск `289d:0011`, инициализация (последовательность команд прошивки в `seekcap.c`), запуск потока+обработки в собственном потоке; `NULL` при недоступности камеры. `hotmap_path` — `core/tests/hot.bin` (320×240 u8 mask) или NULL.
- `skcap_close(skcap_t*)` — остановка, освобождение (60 OUT [00 00] ×3).
- Сеттеры (потокобезопасны, из любого потока): `skcap_set_palette`, `skcap_set_denoise(smooth, motion, spatial, reset)`, `skcap_set_span_manual(on, lo, hi)`, `skcap_set_scene(eps, t_refl_c, t_atm_c, distance_m, rel_humidity)`.
- Калибровка Планка: `skcap_planck_load(path|NULL)`, `skcap_planck_fit(s1,c1,s2,c2)`, `skcap_planck_save(path)`, `skcap_planck_get(&sk_planck_t)`. Файл `key = value` (`planck_r1,b,f,o,r2`), парсер `sk_planck_load_file` в `core/src/radiometric.c`.
- Диагностика: `skcap_stats(&frames,&ffs,&errors,&resyncs,&connected)`; `skcap_dump_dir(dir)` — дампы raw-дампов `img/ff_NNNN.raw`.

Ядро обработки (`core/include/seekcore.h`): `sk_parse_frame`, `sk_apply_ff` (ROI-кроп += 0x4000−FF), `sk_hotmap_median` (mask), `sk_denoise_*` (F9: SMOOTH 0.75 / MOTION 440 / SPATIAL 75, stateful prev), `sk_tonemap_*` (авто percentile 2..99.5 + EMA), палитры `sk_palette_lut/build/name_from` (9 палитр), радиометрия `sk_signal_to_celsius` / `sk_celsius_to_signal` / `sk_planck_fit2` / `sk_atm_tau`.

Отсутствует в API: явная команда ручной калибровки (FF/FFC). Камера шлёт FF-кадры (fid=1) автоматически ~каждые 2 с, ядро кэширует последний — отдельная калибровка UI не запускается (CAM-05/CORE-05 соблюдается штатно).

## AUD-03. Буферы кадра

`skcap_frame_t` (валиден только внутри колбэка; указатели переиспользуются — ARC-07 требует немедленного копирования, так и делает `Engine.onFrame` под `NSLock`):

| Поле | Тип/размер | Единицы | Примечание |
|---|---|---|---|
| `rgb` | u8, 320×240×3, row-major, stride 960 B | sRGB-подобныеcounts LUT | финальный тонмаппинг+палитра |
| `temp` | float64, 320×240, row-major | °C | Планк по FF-скорр. сигналу |
| `signal` | uint16 LE, 320×240 | счётчики АЦП (raw counts) | ROI-кроп x=1,y=4 из 342×260 |
| `lo, hi` | double | сигнал counts | текущий span (авто/ручной) |
| `mean_signal` | double | counts | для калибровки по чёрному телу |
| `fps` | double | Гц | скользящее по хост-часам |
| `frames, ffs, errors, resyncs` | long | счётчики сессии | `frames` — монотонный номер кадра |

Транспортный raw-кадр: 342×260 u16 LE = 177 840 B (`SK_RAW_*`), chunk 13 680 B, magic word[0]=1401, counter word[1], тип word[2] (1=FF, 3=image, 6=offset, 20=gain). Время доставки: поток захвата → колбэк; UI-обновления диспатчатся на main.

## AUD-04. Температуры

Ядро предоставляет ПОЛНУЮ температурную матрицу float64 °C (не только визуализацию): цепочка Планка FLIR-стиля `sk_signal_to_celsius(planck, scene, signal)` над FF-скорректированным сигналом.

- Без калибровки используются общесетевые дефолты (`sk_planck_default`) — ошибка порядка ±5 °C (зафиксировано в E2 статусе).
- Формат недействительных значений: значения вне физ. области Планка дают ≈ −273 °C / NaN; принятый и покрываемый тестамиrule исключения: **`t ≤ −270.0 °C или NaN` → невалиден** (совпадает с проверкой E2 `t < -270`).
- Кадровый счётчик устройства (`word[1]`) НЕ экспортируется в `skcap_frame_t`; доступен `frames` (счётчик сессии) — frameID сборки приложения: `(sessionFrames: Int, hostTimestamp)`. Хост-время: `Date()` при приёме; время устройства недоступно — не маскируется.

## AUD-05. Baseline (аппарат подтверждён, см. baseline.md)

## AUD-06. Capabilities (из реального ядра)

| Capability | Значение | Основание |
|---|---|---|
| supportsTemperature | true | temp f64 °C в кадре (с точностью калибровки) |
| supportsManualCalibration | true | `skcap_planck_fit` (2 точки, ⌘⇧K) |
| supportsEmissivityAdjustment | true | `skcap_set_scene` (ε, T_refl, T_atm, дистанция, RH) — работает, влияет на temp |
| supportsRecording | true (прил. уровень) | MP4/H.264 в E2 `Engine.toggleRecording` |
| supportsRawExport | true | PNG16 сигнала (E2 snapshot) + f64 матрица |
| supportsTemperatureExport | true | temp.f64 (формат golden-тестов) |
| supportsVisibleImage | false | видимой камеры нет → фото-плейсхолдеры запрещены (REP-05) |
| supportsFrameCounter(device) | false | word[1] не в API |

## Известные ограничения ядра (непроверенное/риски)

- Поведение при сне/пробуждении: seekcap имеет мягкий reconnect, но полный цикл sleep→wake на железе в этом baseline не гонялся (TEST-05 — частично).
- `libusb_reset_device` на этой прошивке+хабе клинит control pipe — восстановление без reset (уже в код-базе seekcap).
- `kill -9` оставляет камеру стримящей → нужно переподключение питания; штатный close чист.
- Прошивка: `0409010f`, chip_id `10001500aa00b3002a00d700` (из прошлых сессий dumps).
