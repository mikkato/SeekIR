#!/usr/bin/env python3
"""run_golden.py — golden-тест E1: core(build/seekproc) против Python-эталона.

Порядок: конвертирует hotpixels.npy -> tests/hot.bin, гоняет ref_pipeline.py,
затем build/seekproc, затем побайтовое сравнение всех выходов.
"""
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)  # core/
TOOLS = os.path.join(os.path.dirname(ROOT), "tools")
DUMP = os.path.join(HERE, "dump")
OUT_C = os.path.join(HERE, "out_c")
OUT_REF = os.path.join(HERE, "out_ref")
HOT = os.path.join(HERE, "hot.bin")

SUFFIXES = [".roi.u16", ".den.f32", ".den.f64", ".gray.u8", ".rgb", ".temp.f64"]


def main():
    env = dict(os.environ, PYTHONPATH="")
    # hotmap -> raw u8
    hot = np.load(os.path.join(TOOLS, "hotpixels.npy"))
    hot.astype(np.uint8).tofile(HOT)
    os.makedirs(OUT_C, exist_ok=True)

    subprocess.run([sys.executable, os.path.join(HERE, "ref_pipeline.py")],
                   check=True, env=env)
    subprocess.run([os.path.join(ROOT, "build", "seekproc"),
                    "--dumpdir", DUMP, "--hotmap", HOT, "--out", OUT_C,
                    "--pal", "ironbow", "--probe", "160,120"], check=True)

    os.makedirs(OUT_C, exist_ok=True)
    total_bytes = 0
    bad = []
    n = 0
    while True:
        base = f"frame_{n:04d}"
        if not os.path.exists(os.path.join(OUT_REF, base + SUFFIXES[0])):
            break
        for suf in SUFFIXES:
            a = os.path.join(OUT_REF, base + suf)
            b = os.path.join(OUT_C, base + suf)
            da, db = open(a, "rb").read(), open(b, "rb").read()
            total_bytes += len(da)
            if da != db:
                va = np.frombuffer(da, dtype=np.float32 if suf == ".den.f32" else np.uint8)
                vb = np.frombuffer(db, dtype=np.float32 if suf == ".den.f32" else np.uint8)
                nbad = int((va != vb).sum()) if len(va) == len(vb) else -1
                bad.append((base, suf, nbad, len(va)))
        n += 1
    if bad:
        print("MISMATCH:")
        for base, suf, nb, ln in bad[:20]:
            print(f"  {base}{suf}: {nb}/{ln} различий")
        return 1
    print(f"[GOLDEN OK] {n} кадров, {total_bytes} Б идентичны побайтово")
    return 0


if __name__ == "__main__":
    sys.exit(main())
