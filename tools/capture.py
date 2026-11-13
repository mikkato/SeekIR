#!/usr/bin/env python3
"""SeekIR E0 — live capture для Seek Thermal CompactPRO (289d:0011).

Протокол: vendor control transfer команды 54..89 (libseek-thermal),
raw-кадр: 13 bulk IN трансферов x 13680 B = 342x260 uint16 LE,
кроп ROI [x=1,y=4 -> 320x240], FF-коррекция: raw += 0x4000 - ff_frame.

Использование:
  python3 capture.py --frames 30 --out samples/          # снять 30 кадров
  python3 capture.py --video 30                          # 30 сек стрим, FPS
  python3 capture.py --probe                             # диагностика сырых трансферов
"""
import argparse, os, sys, time, struct
import usb.core, usb.util
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

VID, PID = 0x289D, 0x0011
RAW_W, RAW_H = 342, 260
ROI = (1, 4, 320, 240)  # x, y, w, h
REQ = 13680
OFFSET = 0x4000

# DeviceCommand (из SeekDevice.h)
CMD_TOGGLE_SHUTTER = 55
CMD_SET_OPERATION_MODE = 60
CMD_SET_IMAGE_PROCESSING_MODE = 62
CMD_READ_CHIP_ID = 54
CMD_GET_FACTORY_SETTINGS = 88
CMD_SET_FACTORY_SETTINGS_FEATURES = 86
CMD_GET_FIRMWARE_INFO = 78
CMD_SET_FIRMWARE_INFO_FEATURES = 85
CMD_START_GET_IMAGE_TRANSFER = 83
CMD_TARGET_PLATFORM = 84
CMD_RESET_DEVICE = 89

BMREQ_OUT = 0x41  # host->dev, vendor, interface
BMREQ_IN = 0xC1   # dev->host, vendor, interface


class SeekPro:
    def __init__(self):
        self.dev = usb.core.find(idVendor=VID, idProduct=PID)
        if self.dev is None:
            raise RuntimeError(f"Камера {VID:04x}:{PID:04x} не найдена")
        try:
            self.dev.detach_kernel_driver(0)
        except (NotImplementedError, usb.core.USBError):
            pass
        try:
            self.dev.set_configuration(1)
        except usb.core.USBError:
            pass
        usb.util.claim_interface(self.dev, 0)
        self.ff = None  # flat field кадр

    def set(self, cmd, data):
        self.dev.ctrl_transfer(BMREQ_OUT, cmd, 0, 0, bytes(data), 500)

    def get(self, cmd, n):
        return self.dev.ctrl_transfer(BMREQ_IN, cmd, 0, 0, n, 500)

    def _reopen(self):
        try:
            usb.util.release_interface(self.dev, 0)
        except usb.core.USBError:
            pass
        usb.util.dispose_resources(self.dev)
        time.sleep(1.5)
        self.dev = usb.core.find(idVendor=VID, idProduct=PID)
        if self.dev is None:
            raise RuntimeError("камера пропала с шины после сброса")
        try:
            self.dev.detach_kernel_driver(0)
        except (NotImplementedError, usb.core.USBError):
            pass
        try:
            self.dev.set_configuration(1)
        except usb.core.USBError:
            pass
        usb.util.claim_interface(self.dev, 0)

    def _drain_pipe(self):
        """Считать/выбросить всё, что камера настримила без хоста
        (освобождает зависший bulk-пайп после kill/краха)."""
        deadline = time.time() + 1.0
        while time.time() < deadline:
            try:
                self.dev.read(0x81, 4096, 150)
            except usb.core.USBError:
                return

    def init(self):
        self._drain_pipe()
        for attempt in range(4):
            try:
                self.set(CMD_TARGET_PLATFORM, [0x01])
                break
            except usb.core.USBError as ex:
                if ex.errno != 32:
                    raise
                # reset шины эту прошивку ЗАСТАВЛЯЕТ зависать (наблюдалось
                # дважды) — сначала мягкий перезахват без reset, reset в самый конец
                print(f"  pipe busy, мягкий перезахват (попытка {attempt+1})...")
                if attempt < 2:
                    try:
                        usb.util.dispose_resources(self.dev)
                    except Exception:
                        pass
                    time.sleep(2.0)
                    self.dev = usb.core.find(idVendor=VID, idProduct=PID)
                    if self.dev is None:
                        time.sleep(1.0)
                        continue
                    try:
                        self.dev.set_configuration(1)
                    except usb.core.USBError:
                        pass
                    usb.util.claim_interface(self.dev, 0)
                else:
                    try:
                        self.dev.reset()
                    except usb.core.USBError:
                        pass
                    self._reopen()
        self.set(CMD_SET_OPERATION_MODE, [0x00, 0x00])
        fw = self.get(CMD_GET_FIRMWARE_INFO, 4)
        chip = self.get(CMD_READ_CHIP_ID, 12)
        print(f"  firmware={bytes(fw).hex()}  chip_id={bytes(chip).hex()}")
        self.set(CMD_SET_FACTORY_SETTINGS_FEATURES, [0x06, 0x00, 0x08, 0x00, 0x00, 0x00])
        self.get(CMD_GET_FACTORY_SETTINGS, 12)
        self.set(CMD_SET_FIRMWARE_INFO_FEATURES, [0x17, 0x00])
        self.get(CMD_GET_FIRMWARE_INFO, 64)
        self.set(CMD_SET_FACTORY_SETTINGS_FEATURES, [0x01, 0x00, 0x00, 0x06, 0x00, 0x00])
        self.get(CMD_GET_FACTORY_SETTINGS, 2)
        self.set(CMD_SET_FACTORY_SETTINGS_FEATURES, [0x01, 0x00, 0x01, 0x06, 0x00, 0x00])
        self.get(CMD_GET_FACTORY_SETTINGS, 2)
        for addr in range(0, 2560, 32):
            self.set(CMD_SET_FACTORY_SETTINGS_FEATURES,
                     [0x20, 0x00, addr & 0xFF, addr >> 8, 0x00, 0x00])
            self.get(CMD_GET_FACTORY_SETTINGS, 64)
        self.set(CMD_SET_FIRMWARE_INFO_FEATURES, [0x15, 0x00])
        self.get(CMD_GET_FIRMWARE_INFO, 64)
        self.set(CMD_SET_IMAGE_PROCESSING_MODE, [0x08, 0x00])
        self.set(CMD_SET_OPERATION_MODE, [0x01, 0x00])
        print("  камера инициализирована (streaming mode)")

    def fetch_raw(self):
        n_words = RAW_W * RAW_H
        # без этого запроса камера ничего в bulk IN не отдаёт
        self.set(CMD_START_GET_IMAGE_TRANSFER,
                 [n_words & 0xFF, (n_words >> 8) & 0xFF,
                  (n_words >> 16) & 0xFF, (n_words >> 24) & 0xFF])
        buf = bytearray(n_words * 2)
        done = 0
        retries = 0
        while done < len(buf):
            try:
                data = self.dev.read(0x81, REQ, 2000)
            except usb.core.USBError as ex:
                # pipe halt / I/O stall — лечение: clear_halt, потом перезахват
                if ex.errno in (5, 32, 60) and retries < 8:
                    retries += 1
                    time.sleep(0.3)
                    if retries > 3:
                        self._reopen()
                        buf = bytearray(n_words * 2)
                        done = 0
                    else:
                        try:
                            self.dev.clear_halt(0x81)
                        except usb.core.USBError:
                            pass
                    self.set(CMD_START_GET_IMAGE_TRANSFER,
                             [n_words & 0xFF, (n_words >> 8) & 0xFF,
                              (n_words >> 16) & 0xFF, (n_words >> 24) & 0xFF])
                    continue
                raise
            data = bytes(data)
            buf[done:done + len(data)] = data
            done += len(data)
        frame = np.frombuffer(bytes(buf), dtype='<u2')
        # синхронизация: первый word кадра — маркер 1401; после реконнектов
        # буфер может начаться с хвоста прошлого трансфера
        if len(frame) == RAW_W * RAW_H and int(frame[0]) == 1401:
            return frame.reshape(RAW_H, RAW_W)
        idx = np.nonzero(frame == 1401)[0]
        for i in idx:
            if i + RAW_W * RAW_H <= len(frame):
                cand = frame[i:i + RAW_W * RAW_H].reshape(RAW_H, RAW_W)
                if int(cand[0, 2]) in (1, 3, 6, 20) and int(cand[0, 1]) < 65536:
                    return cand
        raise RuntimeError("кадр без маркера — потерян при пересылке")

    def grab(self, wait_ff=True, max_attempts=60):
        """Возвращает (roi_16bit, meta). Кэширует FF-кадр (frame_id==1)."""
        for _ in range(max_attempts):
            raw = self.fetch_raw()
            counter = int(raw[0, 1])
            fid = int(raw[0, 2])
            if fid == 1:
                self.ff = raw.copy()
                if not wait_ff:
                    continue
            if fid == 3 and self.ff is not None:
                roi_x, roi_y, roi_w, roi_h = ROI
                img = raw[roi_y:roi_y+roi_h, roi_x:roi_x+roi_w].astype(np.int32)
                ff_roi = self.ff[roi_y:roi_y+roi_h, roi_x:roi_x+roi_w].astype(np.int32)
                img = np.clip(img + OFFSET - ff_roi, 0, 65535).astype(np.uint16)
                meta = {"counter": counter, "frame_id": fid,
                        "raw_head": raw[0, :8].astype(int).tolist()}
                return img, meta
        raise RuntimeError("не удалось получить кадр с FF (проверьте подключение)")

    def shutter_closed(self):
        """Закрыть затвор (щелчок). Снимается после FF-кадра автоматически."""
        self.set(CMD_TOGGLE_SHUTTER, [0x01, 0x00])

    def reconnect(self, wait_s=20.0):
        """Ждём возврата камеры на шину и перенициализируем (F7 reconnect)."""
        try:
            usb.util.dispose_resources(self.dev)
        except Exception:
            pass
        t0 = time.time()
        while time.time() - t0 < wait_s:
            self.dev = usb.core.find(idVendor=VID, idProduct=PID)
            if self.dev is not None:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("камера не появилась за %.0f с" % wait_s)
        try:
            self.dev.detach_kernel_driver(0)
        except (NotImplementedError, usb.core.USBError):
            pass
        try:
            self.dev.set_configuration(1)
        except usb.core.USBError:
            pass
        usb.util.claim_interface(self.dev, 0)
        self.ff = None
        self.init()

    def close(self):
        try:
            self.set(CMD_SET_OPERATION_MODE, [0x00, 0x00])
        except Exception:
            pass
        usb.util.release_interface(self.dev, 0)
        usb.util.dispose_resources(self.dev)


def dead_pixel_filter(img):
    """Замена выбросов (битые/горячие пиксели) медианой 3x3 соседей."""
    import numpy as np
    p = np.pad(img.astype(np.int32), 1, mode="edge")
    stack = np.stack([p[j:j+img.shape[0], i:i+img.shape[1]]
                      for j in range(3) for i in range(3)])
    med = np.median(stack, axis=0)
    out = img.astype(np.int32)
    bad = np.abs(out - med) > 512
    out[bad] = med[bad].astype(np.int32)
    return np.clip(out, 0, 65535).astype(np.uint16)


def load_hotmap(path):
    if os.path.exists(path):
        return np.load(path)
    return None


def apply_hotmap(img, mask):
    """Замена помеченных шумных пикселей медианой 3x3."""
    if mask is None or not mask.any():
        return img
    return replace_masked_median(img, mask)


def replace_masked_median(img, mask):
    p = np.pad(img.astype(np.float32), 1, mode="edge")
    stack = np.stack([p[j:j+img.shape[0], i:i+img.shape[1]]
                      for j in range(3) for i in range(3)])
    med = np.median(stack, axis=0)
    out = img.astype(np.float32).copy()
    out[mask] = med[mask]
    return out


def build_hotmap(cam, n_frames=60, path=None, sigma_factor=3.0, floor=40.0, shutter=True):
    """Карта шума по FF-кадрам (затвор закрыт, однородное поле).
    Ручной toggle не используем (неверифицированный payload вешает pipe) —
    собираем автоматические FF-кадры (frame_id==1), которые FastFrame
    выдаёт каждые ~2 с. `shutter` параметр оставлен для совместимости."""
    frames = []
    attempts = 0
    while len(frames) < n_frames and attempts < n_frames * 30:
        attempts += 1
        raw = cam.fetch_raw()
        if int(raw[0, 2]) != 1:
            continue
        x, y, w, h = ROI
        ff = raw[y:y+h, x:x+w].astype(np.float32)
        if cam.ff is None:
            cam.ff = raw.copy()
        frames.append(ff)
        if len(frames) % 10 == 0:
            print(f"  hotmap: FF {len(frames)}/{n_frames}")
    if len(frames) < 10:
        raise RuntimeError(f"мало FF-кадров ({len(frames)}) — камера не калибруется?")
    st = np.stack(frames)
    sd = st.std(axis=0)
    # локальная медиана σ в окне 5x5 (без самого пикселя — грубо ок, окно большое)
    p = np.pad(sd, 2, mode="edge")
    from numpy.lib.stride_tricks import sliding_window_view
    win = sliding_window_view(p, (5, 5))
    local_med = np.median(win, axis=(2, 3))
    thr = np.maximum(sigma_factor * local_med, floor)
    mask = sd > thr
    if path:
        np.save(path, mask)
    pct = 100.0 * mask.mean()
    print(f"  шумных пикселей: {mask.sum()} ({pct:.2f}%), "
          f"медиана σ={np.median(sd):.0f}")
    return mask


def save_pair(img16, meta, outdir, idx, denoise=True):
    if denoise:
        img16 = dead_pixel_filter(img16)
    np.save(os.path.join(outdir, f"frame_{idx:04d}.npy"), img16)
    lo, hi = np.percentile(img16, [0.5, 99.5])
    g = np.clip((img16 - lo) / max(hi - lo, 1) * 255, 0, 255).astype(np.uint8)
    try:
        from PIL import Image
        Image.fromarray(g).save(os.path.join(outdir, f"frame_{idx:04d}.png"))
    except ImportError:
        # fallback: PGM без Pillow
        with open(os.path.join(outdir, f"frame_{idx:04d}.pgm"), "wb") as f:
            f.write(f"P5\n{img16.shape[1]} {img16.shape[0]}\n255\n".encode())
            f.write(g.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=10)
    ap.add_argument("--video", type=float, default=0, help="секунд стрима, считает FPS")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "samples"))
    ap.add_argument("--probe", action="store_true", help="диагностика: hexdump первых трансферов")
    ap.add_argument("--shutter", action="store_true", help="шарнирно закрыть затвор перед serией")
    ap.add_argument("--hotmap", type=int, default=0,
                    help="построить карту шума по N кадрам (затвор закрыт — сцена не важна)")
    ap.add_argument("--no-shutter", action="store_true",
                    help="строить карту на открытой сцене (она должна быть неподвижна)")
    args = ap.parse_args()

    cam = SeekPro()
    print("[1] устройство открыто")
    cam.init()
    print("[2] init завершён")

    if args.probe:
        print("[probe] первые сырые трансферы:")
        for i in range(5):
            raw = cam.fetch_raw()
            head = raw[0, :10].astype(int).tolist()
            print(f"  raw#{i}: head={head}  min={raw.min()} max={raw.max()} mean={raw.mean():.1f}")
        cam.close()
        return

    if args.hotmap:
        path = os.path.join(os.path.dirname(__file__), "hotpixels.npy")
        print(f"[hotmap] строю карту по {args.hotmap} кадрам — НЕ двигайте камеру и сцену")
        build_hotmap(cam, args.hotmap, path=path, shutter=not args.no_shutter)
        cam.close()
        return

    if args.shutter:
        cam.shutter_closed()
        time.sleep(1.5)

    os.makedirs(args.out, exist_ok=True)
    print(f"[3] захват → {args.out}")

    if args.video:
        t0 = time.time()
        n = 0
        while time.time() - t0 < args.video:
            img, meta = cam.grab()
            n += 1
            dt = time.time() - t0
            if n % 10 == 0:
                print(f"  {n} кадров, {n/dt:.1f} FPS, counter={meta['counter']}")
        print(f"[OK] {n} кадров за {time.time()-t0:.1f} c = {n/(time.time()-t0):.2f} FPS")
    else:
        for i in range(args.frames):
            img, meta = cam.grab()
            save_pair(img, meta, args.out, i)
            print(f"  кадр {i}: counter={meta['counter']} min={img.min()} "
                  f"max={img.max()} mean={img.mean():.0f} head={meta['raw_head'][:4]}")
        print(f"[OK] {args.frames} кадров в {args.out}")

    cam.close()
    print("[4] закрыто")


if __name__ == "__main__":
    main()
