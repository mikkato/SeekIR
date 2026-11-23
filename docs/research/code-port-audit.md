# Аудит портируемости: C-ядро SeekIR → рабочий захват на Windows

Дата: 23.11.2026. Роль: кодовый аудит пути `core/` (seekcap/seekd/seekproc) под mingw-w64.
Проверено фактически (не на глаз): `gcc 16.2 (MSYS2 ucrt64)` компилирует **все** TU `core/`
без единого предупреждения при штатных `CFLAGS` (`-std=c11 -O2 -Wall -Wextra -Wconversion
-Wno-sign-conversion -ffp-contract=off`); `seekd.exe` линкуется (`-lusb-1.0 -lm -lpthread`).
`objdump -p build/win/seekd.exe`: внешние зависимости — `libusb-1.0.dll`, `libwinpthread-1.dll`,
KERNEL32 + api-ms-win-crt-* (UCRT — в системе). `seekproc.exe` — только UCRT, DLL не нужны.
Инструментальная база: libusb-1.0 **1.0.30** из `D:\LSDF\toolchains\msys2\ucrt64`; исходники
windows-бэкенда libusb 1.0.30/master изучены по факту (os/windows_winusb.c, os/windows_common.c).

Вывод-заголовок: **код уже практически переносим** — критичных blocker'ов компиляции нет
(минимальный набор правок ниже). Основные риски — не компиляция, а семантика WinUSB-бэкенда
(статусы, таймауты, cancel), мягкая остановка по Ctrl+C и упаковка DLL при дистрибуции.

---

## 1. Портативность: полный перечень мест

Что **уже** работает на mingw-w64 без правок (проверено компиляцией):

| Место | Конструкция | Статус на MinGW-w64 ucrt64 |
|---|---|---|
| seekcap.c:15, 545–549 | `sys/stat.h`, `mkdir(dir)` / `mkdir(dir,0755)` | починено ранее; корректно |
| seekcap.c:84–88, seekd.c:19–23 | `clock_gettime(CLOCK_MONOTONIC)` | есть: UCRT (Win10+) даёт `clock_gettime`, winpthreads `pthread_time.h` даёт `CLOCK_MONOTONIC` |
| seekcap.c:339,347,370; seekd.c:64 | `nanosleep` | winpthreads `pthread_unistd.h` |
| seekcap.c:11 и весь pthread-слой | `pthread_create/join/mutex` | winpthreads (`libwinpthread-1.dll` — линкуется, в DLL-импортах подтверждено) |
| src/palettes.c:6,108 | `#include <strings.h>`, `strcasecmp` | MinGW-w64 поставляет `strings.h`; OK |
| везде | `usleep`, `unistd.h`, `fork/exec`, `dirent`, `select/poll` | **не используются** — ничего чинить не надо |
| seekcap.c:160–165 | пути дампов через `/` | WinAPI принимает `/` в путях — OK |
| seekd.c:55 | `signal(SIGINT,…)` | работает: CRT конвертирует Ctrl+C в SIGINT |

Оставшиеся правки (полный список; вне компилятора — рантайм-семантика):

| # | Файл:строки | Проблема | Правка |
|---|---|---|---|
| P1 | seekd.c:55–56 | `SIGTERM` на Windows не доставляется никогда (только собственный `raise`); закрытие окна консоли (CTRL_CLOSE_EVENT) убивает процесс без штатного `60[00 00]×3` | `#ifdef _WIN32` добавить `SetConsoleCtrlHandler` (CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT → `g_quit=1`; для CLOSE дать ~3 с на `skcap_close`). `signal(SIGINT)` оставить как кросс-платформенный путь |
| P2 | seekd.c:32–35, 50–51, 70–71 | кириллица в stderr: на консоли cmd/CP866 — mojibake (в git-bash с UTF-8 — нормально) | в `main()`: `#ifdef _WIN32 SetConsoleOutputCP(CP_UTF8);` (нужен `windows.h`, либо изолировать в compat-блок) |
| P3 | seekcap.c:342 | `libusb_detach_kernel_driver` на Windows всегда `LIBUSB_ERROR_NOT_SUPPORTED` | безвредно (код возврата игнорируется), но добавить `(void)`-каст и комментарий либо `#ifndef _WIN32` |
| P4 | seekcap.c:545–549 | `_mkdir` не создаёт вложенные пути (`--dump a/b/c` падает молча — реткод не проверен) | минимально: пройтись по сепараторам и создать сегменты; либо документировать «плоский путь» |
| P5 | seekcap.c:259–279 | на каждом chunk — `libusb_alloc_transfer`+`malloc` (13 пар alloc/free на кадр); на Windows heap медленнее, чем на macOS, и это на горячем пути | пул из N `libusb_transfer*`+буферов (см. §4, там же и чинится) |
| P6 | seekcap.c:84–88 | `clock_gettime` — только для MinGW/UCRT; при переносе на MSVC исчезнет | не блокер для mingw-билда; при нужде — compat-шапка с `QueryPerformanceCounter` |
| P7 | palettes.c:6,108 | `strings.h/strcasecmp` — нет в MSVC | не блокер для mingw-билда; зафиксировать в документации: «Windows-билд = mingw-w64, MSVC не поддерживается» |
| P8 | Makefile:2,7–8 | `CC ?= clang`; pkg-config-fallback на `/opt/homebrew` | для mingw не годится → отдельный `Makefile.win` (§5) |

Итог по §1: минимальный набор для «рабочего захвата» — **P1+P2** (поведение), остальное — гигиена.
Ни один из пунктов не меняет golden-путь (битовая совместимость `-ffp-contract=off` сохраняется).

---

## 2. libusb на Windows: WinUSB-бэкенд, асинхронные bulk

Дизайн seekcap.c (async bulk + `libusb_handle_events_timeout_completed` в worker-потоке,
control только из pump) **корректен и для WinUSB-бэкенда**. Факты по исходникам os/windows_*:

**Требования бэкенда.** Нужен WinUSB-драйвер на интерфейс (ставится; INF в
`driver/winusb-seek/`, DeviceInterfaceGUID `{3bc8a9c6-…}` — пригодится для точного открытия
устройства через `WinUsb`/`libusb_open` по пути вместо `open_device_with_vid_pid`, если появится
второе устройство). `libusb_set_configuration(h,1)` (seekcap.c:282) при уже активной конфиг.
1 на WinUSB — no-op с синтетическим завершением в бэкенде (спец-путь SET_CONFIGURATION), не ошибка.

**Размер control-трансфера.** WinUSB-бэкенд режет control-пакеты > 4096 B
(`MAX_CTRL_BUFFER_LENGTH`, windows_winusb.h:35). У нас максимум 64 B — с запасом.

**Bulk.** `winusbx_submit_bulk_transfer` → `WinUsb_ReadPipe` overlapped; URB любого размера
(лимитов на 13680/45600 B нет; дробление на max-packet-size делает xhci-стек). Completion:
`GetOverlappedResult` в контексте `libusb_handle_events*`, маппинг ошибок
(windows_common.c, `windows_transfer_completion`):

| Win32 GetLastError | libusb status |
|---|---|
| NO_ERROR | COMPLETED |
| ERROR_GEN_FAILURE | **STALL** |
| ERROR_SEM_TIMEOUT | TIMED_OUT |
| ERROR_OPERATION_ABORTED (AbortPipe) | CANCELLED |
| ERROR_FILE_NOT_FOUND / ERROR_DEVICE_NOT_CONNECTED / ERROR_NO_SUCH_DEVICE | NO_DEVICE |
| прочее | ERROR |

**Отличия от macOS, важные для seekcap.c:**

1. **STALL шире по смыслу.** `ERROR_GEN_FAILURE` WinUSB возвращает и при реальном halt
   пайпа, и при общих сбоях стека (устройство «не отвечает»). На darwin STALL — почти всегда
   настоящий halt. Лечение у нас (clear_halt + request заново, seekcap.c:219–224) — правильное,
   но нужен ограничитель: после N (например 5) подряд STALL без успешных данных — эскалация в
   reconnect (`need_request=-1`). Иначе возможна гонка clear-halt по живому пайпу.
2. **Таймаут = AbortPipe = волна CANCELLED.** При истечении `timeout` (у нас 1000 мс,
   seekcap.c:270) бэкенд отменяет трансфер через `WinUsb_AbortPipe`; незавершённые чтения
   того же пайпа получают `ERROR_OPERATION_ABORTED`. Часть из них доходит до callback со
   статусом TIMED_OUT, но при гонке отмены возможен CANCELLED **не** при закрытии. Текущий код
   (seekcap.c:211–212) трактует CANCELLED только как «штатное закрытие» и молча прекращает
   конвейер → на Windows pipeline может встать навсегда (нет in-flight URB, pump не вызывает
   submit, т.к. `need_request==0` и chunk не падал). Правка (см. §5, K1): `CANCELLED && !quit`
   → `need_request=1` (resync). Альтернатива/дополнение — `timeout=0` (без таймера) плюс
   собственный watchdog в worker по `now()-t_last_chunk`; это ещё и снимает abort-штормы при
   пайплайне из нескольких URB (§4).
3. **NO_DEVICE при выдёргивании.** Одинаково с macOS: pending-трансферы завершаются
   NO_DEVICE → `need_request=-1` → worker закрывает handle, пересоздаёт через
   `libusb_open_device_with_vid_pid`, 1 с retry (seekcap.c:333–371). На Windows корректно;
   учести, что PnP-пересборка (re-enumeration драйвера) может дать handle на «полумёртвое»
   устройство — `init_cam` (claim_interface) это ловит, путь reconnect уже годный.
4. **Корректный resync при разрыве** (закрепить как инвариант): (а) при NO_DEVICE/ERROR —
   только закрыть handle и пересоздать (не пытаться clear_halt на мёртвом); (б) при STALL —
   `libusb_clear_halt` (на WinUSB → `WinUsb_ResetPipe`, работает) + сброс `fill/req_bytes` +
   заново `CMD_START_GET_IMAGE_TRANSFER`; (в) всегда пересобирать кадровую синхронизацию по
   magic 1401 (`find_magic`, seekcap.c:182–192) — это уже есть; (г) слать `60[00 00]×3` только
   на живом handle (в `close_cam` добавить guard `if (!c->h) return;` — сейчас вызывается
   только с живым, но guard дешевле, чем будущий баг).
5. **Тайминг worker-цикла**: `handle_events_timeout 20 мс` + pump — на Windows events крутят
   IOCP-поток бэкенда, polling дешёв. Оставляет latency ≤20 мс на pump-итерацию; при
   FPS-бюджете 145 мс/кадр незаметно.

## 3. Control-трансферы из callback на Windows

- **Синхронный** `libusb_control_transfer` из bulk-callback **запрещён на всех бэкендах,
  включая Windows**: callback выполняется внутри `libusb_handle_events_*` того самого потока,
  который должен доставить completion синхронного вызова → взаимоблокировка. Это не про
  darwin-специфику, это про однопоточный event-loop.
- **Асинхронный** `libusb_submit_transfer` (control) из callback на Windows **допустим**:
  BUSY-проблема darwin (usb_host_libbug pipe serialization) у WinUSB-бэкенда отсутствует.
  Тем не менее текущая архитектура (control только из pump, seekcap.c:198–199) остаётся
  правильной и переносимой — менять её ради Windows не нужно; в комментарии уместно уточнить,
  что ограничение darwin-специфично, а синхронный вызов из callback запрещён всюду.

## 4. Производительность: 320×240 u16 @ ~7 fps

Бюджет: 177 840 B/кадр, 6.9 к/с ⇒ ~1.23 МБ/с — ниже пропускной способности USB2 HS на два
порядка. Узкое место — не пропускная способность и не размер chunk, а **последовательность
«1 URB в полёте + round-trip»**: `chunk_inflight` (seekcap.c:53) держит ровно один bulk-URB;
каждые 13680 B — completion → pump → submit. ~13 последовательных RTT/кадр (~10 мс каждый на
macOS). Что менять, по убыванию эффекта:

1. **Пайплайн N URB вместо 1** (N=4…13). Изменить `chunk_inflight:int` на счётчик; pump
   добирает очередь до N. Device отдаёт данные только после `CMD_START_GET_IMAGE_TRANSFER`,
   лишние pending-read просто ждут на пайпе — безопасно и на WinUSB, и на darwin. Ожидание:
   6.9 → 15–25 fps (упрётся в реальную скорость датчика/прошивки). Обязательные спутники:
   пул трансферов (см. P5) и обработка CANCELLED (K1), иначе Windows-таймауты будут рвать очередь.
2. **Размер chunk** `SK_BULK_CHUNK` (include/seekcore.h:33, 13680 B = 1/13 кадра). Сам по себе
   рост 13680→45600 (1/4 кадра) экономит ~10 URB-инициализаций/кадр — эффект единицы процентов;
   при пайплайне менять нет необходимости. Если менять — оставить делителем SK_RAW_BYTES,
   кратно 2 (magic ищется по чётным смещениям, seekcap.c:185).
3. **Контрольный request между кадрами** — синхронный `request_frame` в pump
   (seekcap.c:245–252, timeout 500 мс) — второй по величине serialization-шаг между кадрами.
   Вариант: слать request следующего кадра заранее (за ~2 chunk до конца текущего) только после
   проверки, что прошивка принимает вложенные request'ы (на железе; см. §6).
4. **Лишние memcpy**: chunk_cb memcpy → asm_buf, pump memmove → компакция (seekcap.c:207,
   235–243). При пайплайне — кольцевой буфер с read-указателем вместо memmove.
5. **Дампы** пишутся 2 файла/кадр из worker-потока (seekcap.c:158–167) — при включённом
   dumpdir FPS проседает на IO; вынести в отдельный поток-очередь (или отключать в проде).

## 5. Чеклист изменений core/ для Windows-билда

Кодовые правки (приоритет: B=блокирует корректность на Windows, H=высокий, L=гигиена):

| # | Пр. | Файл:строки | Изменение |
|---|---|---|---|
| K1 | B | usb/seekcap.c:211–212 | `CANCELLED && !c->quit` → считать сбоем: `c->fill=0; c->req_bytes=0; c->need_request=1;` (сейчас молча глушит таймаут-отмены WinUSB → зависание конвейера) |
| K2 | B | usb/seekd.c:55–56 | `#ifdef _WIN32` `SetConsoleCtrlHandler` на CTRL_C/BREAK/CLOSE → `g_quit=1` (+ краткий guard на CTRL_CLOSE); SIGINT/SIGTERM оставить |
| K3 | H | usb/seekd.c main() | `#ifdef _WIN32` `SetConsoleOutputCP(CP_UTF8)` (кириллица в stderr) |
| K4 | H | usb/seekcap.c:219–224 | счётчик подряд идущих ошибок STALL/ERROR; >5 без успешного chunk → `need_request=-1` (эскалация в reconnect) |
| K5 | H | usb/seekcap.c:53,253–279 | `chunk_inflight` → счётчик; держать N=4 pending URB; пул трансферов вместо alloc/free на chunk |
| K6 | M | usb/seekcap.c:269–270 | `timeout` 1000 → 0 для pайплайна + watchdog в worker (`t_last_chunk`), ЛИБО оставить 1000 и обязательно K1 |
| K7 | M | usb/seekcap.c:325–329 | `close_cam`: ранний выход при `!c->h`/не-подключено |
| K8 | L | usb/seekcap.c:342 | `(void)libusb_detach_kernel_driver(...)` + комментарий (на Win — NOT_SUPPORTED) |
| K9 | L | usb/seekcap.c:545–549 | рекурсивный mkdir (или зафиксировать требование плоского пути) |
| K10 | L | usb/seekcap.c:4–5,8, seekcap.h:8–9 | комментарий: запрет синхронного control из callback — общий (deadlock), запрет submit — darwin-специфичный |

Сборка. Текущий `core/Makefile` ориентирован на clang/brew (Makefile:2 `CC ?= clang`;
:7–8 fallback на `/opt/homebrew`), поэтому для mingw — отдельный `core/Makefile.win`
(CMake оправдан только если планируется MSVC/IDE; для одного тулчейна проще make):

```make
# core/Makefile.win — mingw-w64 ucrt64. make -f Makefile.win [usb test dist]
TC      ?= D:/LSDF/toolchains/msys2/ucrt64
CC      := $(TC)/bin/gcc.exe
AR      := $(TC)/bin/ar.exe
CFLAGS  := -std=c11 -O2 -Wall -Wextra -Wconversion -Wno-sign-conversion \
           -ffp-contract=off -Iinclude -Iusb -D_WIN32_WINNT=0x0A00
LDLIBS  := -L$(TC)/lib -lusb-1.0 -lm -lpthread
OBJDIR  := build/win
SRCS    := src/frame.c src/denoise.c src/tonemap.c src/palettes.c src/radiometric.c
OBJS    := $(addprefix $(OBJDIR)/,$(notdir $(SRCS:.c=.o)))
…
$(OBJDIR)/seekd.exe: $(OBJDIR)/seekd.o $(OBJDIR)/libseekcap.a $(OBJDIR)/libseekcore.a
	$(CC) $^ -o $@ $(LDLIBS) -static-libgcc
dist:  # плоский каталог для распространения
	mkdir -p dist && cp $(OBJDIR)/seekd.exe dist/ \
	  && cp $(TC)/bin/libusb-1.0.dll $(TC)/bin/libwinpthread-1.dll dist/
```

Замечания по дистрибуции DLL (проверено objdump по существующим seekd.exe):
минимальный комплект — `seekd.exe + libusb-1.0.dll + libwinpthread-1.dll` (UCRT системная,
libgcc можно убрать линковкой `-static-libgcc`; сейчас libgcc в импортах не виден — статически).
Альтернатива — статическая линковка: в тулчейне есть `libusb-1.0.a` (проверено), `gcc -static`
упакует winpthread и libusb в exe; останутся только системные DLL (kernel32, winusb.dll — inbox).
Минус статики libusb: обновления бэкенда требуют пересборки; для одного бинарника это оправдано. Для golden-теста:
`test:` цель — `D:/LSDF/runtimes/python313/python.exe tests/run_golden.py` (в git-bash уже
проходило). Все артефакты писать в `OBJDIR`, не рядом с исходниками (сейчас `usb/seekcap.o`
лежит в usb/ — в mingw-билде пачкает дерево; в Makefile.win правится через `$(OBJDIR)`).

## 6. Чем питать golden-тест: без железа / только на железе

Уже есть: `build/seekproc.exe` vs `ref_pipeline.py` — побайтовая сверка 6 буферов × N кадров,
проход на Windows подтверждён.

**Добавить без железа** (по ценности):
1. **Replay-бэкенд seekcap**: режим `skcap_open_replay(dir)` (или env), читающий
   `tests/dump/{img,ff}_NNNN.raw` через тот же pump/process_frame/колбэк — покрывает конвейер,
   тонмаппинг-состояние и hotmap без USB; сверка с golden-выходами seekproc.
2. **Юнит-тест resync-логики**: синтетический поток — конкатенация raw-файлов, нарезка
   произвольными чанками (не только 13680), вставка мусора/разрывов; прогон через `find_magic`
   + `pump`-эквивалент (вынести pump/find_magic в тестируемую функцию); инвариант: каждый
   валидный кадр извлечён ровно один раз, `resyncs` монотонен.
3. **Mock libusb**: заглушка `libusb-1.0.a` (submit/ callbacks вручную) для прогона chunk_cb
   по матрице COMPLETED/STALL/NO_DEVICE/CANCELLED/TIMED_OUT × quit → проверка переходов
   `need_request`, отсутствия зависаний (ловит класс багов K1/K4 на macOS-машинах CI).
4. Инвариант счётчика: дампы с monotonic `word[1]` — после resync-инъекций кадры не дублируются.

**Только на железе (после установки WinUSB):**
- реальная связка WinUSB: claim/set_configuration/`init_cam`-последовательность (27 control);
- FPS-профиль: 1 vs 4 vs 13 URB в полёте; тайминги request→first-chunk (решает K6/пайплайн);
- маппинг ошибок вживую: выдёргивание (ожидаем NO_DEVICE), STALL-поведение прошивки,
  идемпотентность `CMD_START_GET_IMAGE_TRANSFER` (вложенные request'ы);
- reconnect-цикл после re-enumeration PnP (zadig-перестановка драйвера);
- Ctrl+C / закрытие консоли → штатные `60[00 00]×3` (проверка K2 на живом устройстве).

## 7. Библиотеки для будущего Windows-клиента

| Кандидат | Оценка |
|---|---|
| **C-либа + P/Invoke из .NET (рекомендация для продукта)** | seekcap.h — почти готовый flat API (`extern "C"`, POD-структуры, callback). Добавить `seekcap_export.h` с `__declspec(dllexport)` и стабильным stdcall-не-нужно (cdecl + `UnmanagedFunctionPointer(Cdecl)` работает). Кадры — `IntPtr` + `Marshal.Copy` (rgb 230 КБ/кадр @7fps — копейки). GUI: WPF/WinUI3 WriteableBitmap. Вся golden-цепочка сохраняется без портирования |
| Прямой C++ (Win32/DXGI или Qt) | Нулевой interop-налог, единая кодовая база с core; цена — второй GUI-код, вне macOS-линии. Оправдано при требовании <60-fps-гарантий/низких задержек |
| **pyusb-прототип (быстрая проверка железа уже сейчас)** | `tools/capture.py` работает на Windows почти как есть: pyusb сам найдёт `libusb-1.0.dll` (из тулчейна в PATH или `find_backend`), `detach_kernel_driver` уже обёрнут в `except NotImplementedError` (capture.py:47–49); синхронные `dev.read(0x81,13680,2000)` дадут ~те же ~7 fps. Годится для железных экспериментов §6, не для продукта |
| LibUsbDotNet (чистый C#) | Транспорт хорош, но пришлось бы портировать F9-цепочку/Планка на C# → потеря побитовой golden-совместимости. Не рекомендуется |

---

## Резюме

Компиляционная готовность 100% (проверено); рантайм-готовность — минус две правки
(K1 CANCELLED-resync, K2 Ctrl+C-обработчик) плюс UTF-8 консоль (K3). Производительность
упирается не в размер chunk, а в один pending-URB и синхронный request между кадрами;
пайплайн N URB (K5+K6+K1) — единственный содержательный резерв. Дистрибуция:
seekd.exe + libusb-1.0.dll + libwinpthread-1.dll, флаг `-ffp-contract=off` неприкосновенен.
