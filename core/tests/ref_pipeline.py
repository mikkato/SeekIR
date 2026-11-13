#!/usr/bin/env python3
"""ref_pipeline.py — Python-эталон F9-цепочки для побитовой сверки с core/.

Дублирует view.py denoise()/render() и capture.py FF-коррекцию, повторяя
dtype'ы и порядок операций: float32 для полевых вычислений, float64 для
percentile/EMA/радиометрии. Харнес core (build/seekproc) обязан дать
побитово идентичные выходы.

Выход: core/tests/out_ref/frame_NNNN.{roi.u16,den.f32,gray.u8,rgb,temp.f64}
"""
import json
import math
import os
import sys

import numpy as np

W, H = 320, 240
RAW_W, RAW_H = 342, 260
ROI = (1, 4, 320, 240)
OFFSET = 0x4000

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.environ.get("SK_DUMP", os.path.join(HERE, "dump"))
OUTREF = os.environ.get("SK_OUTREF", os.path.join(HERE, "out_ref"))

SMOOTH, MOTION, SPATIAL = 0.75, 440, 75

# ---- палитры (те же stops, что core/src/palettes.c) ----
STOPS = {
    "ironbow": [(0.00,(0,0,30)),(0.15,(20,10,120)),(0.35,(120,20,150)),
                (0.55,(220,60,60)),(0.75,(255,160,0)),(0.90,(255,240,120)),
                (1.00,(255,255,255))],
}

def make_lut(stops):
    lut = np.zeros((256, 3), dtype=np.uint8)
    for c in range(3):
        xs = [s[0] for s in stops]
        ys = [s[1][c] for s in stops]
        lut[:, c] = np.interp(np.linspace(0, 1, 256), xs, ys)
    return lut

def median(img, r):
    p = np.pad(img, r, mode="edge")
    stack = np.stack([p[j:j+img.shape[0], i:i+img.shape[1]]
                      for j in range(2*r+1) for i in range(2*r+1)])
    return np.median(stack, axis=0)

def dilate3(diff):
    pd = np.pad(diff, 1, mode="edge")
    stack = np.stack([pd[j:j+diff.shape[0], i:i+diff.shape[1]]
                      for j in range(3) for i in range(3)])
    return stack.max(axis=0)

# ---- радиометрия (те же константы/формулы, что core/src/radiometric.c) ----
PLANCK = dict(r1=21106.77, b=1501.0, f=1.0, o=-7340.0, r2=0.012545258)
SCENE = dict(eps=0.95, t_refl=20.0, t_atm=20.0, dist=1.0, rh=50.0)
ABS_ZERO = 273.15
ATA1, ATB1 = 0.006569, -0.002276

def L_of_T(T_c):
    tk = max(T_c + ABS_ZERO, 1.0)
    return PLANCK["r1"] / (PLANCK["r2"] * (math.exp(PLANCK["b"] / tk) - PLANCK["f"])) - PLANCK["o"]

def atm_tau(d, t_atm, rh):
    alpha = ATA1 + ATB1 * math.sqrt(max(0.0, min(100.0, rh)))
    return math.exp(-math.sqrt(max(0.0, d)) * alpha)

_T_LREFL = None
_T_LATM = None
_TAU = None

def signal_to_c_vec(signal):
    global _T_LREFL, _T_LATM, _TAU
    if _TAU is None:
        _TAU = atm_tau(SCENE["dist"], SCENE["t_atm"], SCENE["rh"])
        _T_LREFL = L_of_T(SCENE["t_refl"])
        _T_LATM = L_of_T(SCENE["t_atm"])
    eps, tau = SCENE["eps"], _TAU
    r_obj = (signal / (eps * tau) - ((1 - eps) / eps) * _T_LREFL
             - ((1 - tau) / (eps * tau)) * _T_LATM)
    with np.errstate(all="ignore"):
        arg = PLANCK["r1"] / (PLANCK["r2"] * (r_obj + PLANCK["o"])) + PLANCK["f"]
        t = PLANCK["b"] / np.log(arg) - ABS_ZERO
    return np.where((arg > 1.0) & np.isfinite(t), t, -273.15)


def main():
    os.makedirs(OUTREF, exist_ok=True)
    hot = np.load(os.path.join(HERE, "..", "..", "tools", "hotpixels.npy"))
    hot = hot.reshape(H, W).astype(bool)
    lut = make_lut(STOPS["ironbow"])

    prev = None
    seeded = False
    lo, hi = 14500.0, 17500.0
    n = 0
    while True:
        img_p = os.path.join(DUMP, f"img_{n:04d}.raw")
        if not os.path.exists(img_p):
            break
        raw = np.fromfile(img_p, dtype="<u2").reshape(RAW_H, RAW_W)
        ff = np.fromfile(os.path.join(DUMP, f"ff_{n:04d}.raw"), dtype="<u2").reshape(RAW_H, RAW_W)
        assert int(raw[0, 0]) == 1401, f"frame {n}: magic"
        assert int(raw[0, 2]) == 3, f"frame {n}: fid"
        x, y, w, h = ROI
        roi = np.clip(raw[y:y+h, x:x+w].astype(np.int32) + OFFSET
                      - ff[y:y+h, x:x+w].astype(np.int32), 0, 65535).astype(np.uint16)
        cur = roi.astype(np.float32)
        cur[hot] = median(cur, 2)[hot]
        m3 = median(cur, 1)
        gx = np.abs(np.diff(m3, axis=1, prepend=m3[:, :1]))
        gy = np.abs(np.diff(m3, axis=0, prepend=m3[:1, :]))
        grad = np.maximum(gx, gy)
        gate = float(SPATIAL)
        wgt = np.clip((grad - gate) / (gate * 4.6 + 1e-6), 0.0, 1.0)
        cur = m3 + wgt * (cur - m3)
        if prev is not None:
            dmax = dilate3(np.abs(cur - prev))
            alpha = np.where(dmax > float(MOTION), 1.0, float(SMOOTH))
            cur = prev + (cur - prev) * alpha
        prev = cur

        p2, p99 = np.percentile(cur, [2, 99.5])
        if not seeded:
            lo, hi = float(p2), float(p99)
            seeded = True
        else:
            lo = 0.85 * lo + 0.15 * float(p2)
            hi = 0.85 * hi + 0.15 * float(p99)
        gray = np.clip((cur - lo) / max(hi - lo, 1) * 255, 0, 255).astype(np.uint8)
        rgb = lut[gray]

        temp = signal_to_c_vec(roi.astype(np.float64))

        base = os.path.join(OUTREF, f"frame_{n:04d}")
        roi.tofile(base + ".roi.u16")
        cur.astype(np.float32).tofile(base + ".den.f32")
        np.ascontiguousarray(cur, dtype=np.float64).tofile(base + ".den.f64")
        gray.tofile(base + ".gray.u8")
        rgb.tofile(base + ".rgb")
        temp.astype(np.float64).tofile(base + ".temp.f64")
        print(f"frame {n}: span {lo:.1f}..{hi:.1f} [{lo!r} {hi!r}]  "
              f"Tmean={temp.mean():.1f}C")
        n += 1
    print(f"[ref] {n} кадров -> {OUTREF}")
    return 0 if n else 1


if __name__ == "__main__":
    sys.exit(main())
