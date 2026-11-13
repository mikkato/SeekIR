#!/usr/bin/env python3
"""SeekIR E1 — сырые дампы для golden-тестов core/.

Пишет в core/tests/dump/:
  img_NNNN.raw   — сырой трансфер 342x260 uint16 LE (всё, что пришло по bulk)
  ff_NNNN.raw    — FF-кадр (тот же формат), применённый к img_NNNN
  calib_blob.bin — 5120 B заводских настроек (80×64, цикл 86/88 при init)
  meta.json      — счётчики/типы, firmware, chip_id

Камера: прямой порт, завершение только штатное (close(), не kill -9).
"""
import json
import os
import struct
import time

import numpy as np

from capture import (CMD_GET_FACTORY_SETTINGS, CMD_GET_FIRMWARE_INFO,
                     CMD_READ_CHIP_ID, CMD_SET_FACTORY_SETTINGS_FEATURES,
                     CMD_SET_FIRMWARE_INFO_FEATURES, CMD_SET_IMAGE_PROCESSING_MODE,
                     CMD_SET_OPERATION_MODE, CMD_TARGET_PLATFORM,
                     REQ, RAW_H, RAW_W, SeekPro)

OUT = os.path.join(os.path.dirname(__file__), "..", "core", "tests", "dump")


def init_dump_stream(cam):
    """cam.init() умеет мягкое восстановление после Errno 32 (наследие E0).
    Затем: стоп стрим → blob-цикл 86/88 (тот же, что в init) → снова стрим."""
    cam.init()
    cam.set(CMD_SET_OPERATION_MODE, [0x00, 0x00])
    import time as _t
    _t.sleep(0.3)
    dev = cam.dev
    fw = bytes(cam.get(CMD_GET_FIRMWARE_INFO, 4))
    chip = bytes(cam.get(CMD_READ_CHIP_ID, 12))
    blob = bytearray()
    for addr in range(0, 2560, 32):
        cam.set(CMD_SET_FACTORY_SETTINGS_FEATURES,
                [0x20, 0x00, addr & 0xFF, addr >> 8, 0x00, 0x00])
        blob += bytes(cam.get(CMD_GET_FACTORY_SETTINGS, 64))
    cam.set(CMD_SET_FIRMWARE_INFO_FEATURES, [0x15, 0x00])
    cam.get(CMD_GET_FIRMWARE_INFO, 64)
    cam.set(CMD_SET_IMAGE_PROCESSING_MODE, [0x08, 0x00])
    cam.set(CMD_SET_OPERATION_MODE, [0x01, 0x00])
    return fw, chip, bytes(blob)


def main(n_frames=12):
    os.makedirs(OUT, exist_ok=True)
    cam = SeekPro()
    print("[1] устройство открыто")
    fw, chip, blob = init_dump_stream(cam)
    print("[2] init завершён, blob собран")

    with open(os.path.join(OUT, "calib_blob.bin"), "wb") as f:
        f.write(blob)
    print(f"[3] calib blob: {len(blob)} B")

    meta = {"firmware": fw.hex(), "chip_id": chip.hex(), "frames": []}
    # дождаться свежего FF, чтобы пара img/ff была консистентна
    t0 = time.time()
    while cam.ff is None and time.time() - t0 < 10:
        raw = cam.fetch_raw()
        if int(raw[0, 2]) == 1:
            cam.ff = raw.copy()

    idx = 0
    while idx < n_frames:
        raw = cam.fetch_raw()
        fid = int(raw[0, 2])
        if fid == 1:
            with open(os.path.join(OUT, f"ff_{idx:04d}.raw"), "wb") as f:
                f.write(raw.astype("<u2").tobytes())
            cam.ff = raw.copy()
            continue
        if fid != 3 or cam.ff is None:
            continue
        with open(os.path.join(OUT, f"img_{idx:04d}.raw"), "wb") as f:
            f.write(raw.astype("<u2").tobytes())
        with open(os.path.join(OUT, f"ff_{idx:04d}.raw"), "wb") as f:
            f.write(cam.ff.astype("<u2").tobytes())
        meta["frames"].append({
            "idx": idx,
            "counter": int(raw[0, 1]),
            "head": raw[0, :8].astype(int).tolist(),
            "ff_counter": int(cam.ff[0, 1]),
        })
        print(f"  dump {idx}: counter={int(raw[0, 1])}")
        idx += 1

    with open(os.path.join(OUT, "meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    cam.close()
    print(f"[OK] {n_frames} пар img/ff в {os.path.abspath(OUT)}")


if __name__ == "__main__":
    main()
