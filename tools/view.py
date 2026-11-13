#!/usr/bin/env python3
"""SeekIR live viewer — прототип UI поверх E0-пайплайна (tkinter, без тяжёлых зависимостей).

Управление:
  Space      freeze/unfreeze (на паузе — пиксель под курсором в °T-значениях)
  1..5       палитры: ironbow / rainbow / white hot / black hot / arctic
  S          снимок кадра (PNG + npy в samples/live_*)
  A          вкл/выкл авто span-level (иначе — по последним границам)
  Q / Esc    выход

Требует: Pillow (brew install python-pillow или pip3 install pillow)
"""
import time, os, sys, threading
import numpy as np
import tkinter as tk
from PIL import Image, ImageTk
from capture import (SeekPro, dead_pixel_filter, load_hotmap,
                     replace_masked_median)

PALETTES = {}

def _mk_lut(name, stops):
    import colorsys
    lut = np.zeros((256, 3), dtype=np.uint8)
    for c in range(3):
        xs = [s[0] for s in stops]
        ys = [s[1][c] for s in stops]
        lut[:, c] = np.interp(np.linspace(0, 1, 256), xs, ys)
    PALETTES[name] = lut

def build_palettes():
    ironbow = [(0.00,(0,0,30)),(0.15,(20,10,120)),(0.35,(120,20,150)),
               (0.55,(220,60,60)),(0.75,(255,160,0)),(0.90,(255,240,120)),
               (1.00,(255,255,255))]
    rainbow = [(0.00,(40,0,80)),(0.25,(0,80,255)),(0.5,(0,220,120)),
               (0.75,(255,230,0)),(1.0,(255,255,255))]
    white = [(0,(0,0,0)),(1,(255,255,255))]
    black = [(0,(255,255,255)),(1,(0,0,0))]
    arctic = [(0.0,(0,10,40)),(0.3,(0,120,160)),(0.6,(200,255,255)),
              (0.85,(255,255,210)),(1.0,(255,160,40))]
    _mk_lut("ironbow", ironbow); _mk_lut("rainbow", rainbow)
    _mk_lut("whitehot", white); _mk_lut("blackhot", black)
    _mk_lut("arctic", arctic)

SCALE = 2  # апскейл окна

class Viewer:
    def __init__(self):
        build_palettes()
        self.cam = SeekPro()
        self.cam.init()
        self.hot = load_hotmap(os.path.join(os.path.dirname(__file__), "hotpixels.npy"))
        self.prev = None          # кадр после temporal-фильтра (float32)
        self.paused = False
        self._stop = False
        self._lock = threading.Lock()
        self.fps_live = 0.0
        self._cap_t = time.time(); self._cap_n = 0
        self.auto = True
        self.palette = "ironbow"
        self.lo, self.hi = 14500, 17500
        self.frame = None
        self.n = 0; self.t0 = time.time()
        self.root = tk.Tk(); self.root.title("SeekIR preview (E0)")
        self.canvas = tk.Canvas(self.root, width=320*SCALE, height=240*SCALE+24, bg="black")
        self.canvas.pack()
        self.status = self.canvas.create_text(6, 240*SCALE+12, fill="#0f0",
                                              anchor="w", font=("Menlo", 11))
        # --- панель настроек фильтра (конфиг — viewer_settings.json) ---
        cfg = {}
        cfg_path = os.path.join(os.path.dirname(__file__), "viewer_settings.json")
        try:
            import json
            with open(cfg_path) as fs: cfg = json.load(fs)
        except Exception: pass
        self._cfg_path = cfg_path
        self.var_smooth = tk.DoubleVar(value=float(cfg.get("smooth", 0.75)))
        self.var_motion = tk.IntVar(value=int(cfg.get("motion", 440)))
        self.var_spatial = tk.IntVar(value=int(cfg.get("spatial", 75)))
        panel = tk.Frame(self.root, bg="#1a1a1a")
        panel.pack(fill="x")
        def slider(row, label, var, frm, to, fmt="{:.2f}"):
            tk.Label(panel, text=label, bg="#1a1a1a", fg="#aaa",
                     font=("Menlo", 10)).grid(row=row, column=0, sticky="w", padx=(8, 4))
            s = tk.Scale(panel, from_=frm, to=to, orient="horizontal", variable=var,
                         showvalue=True, resolution=(0.05 if isinstance(var, tk.DoubleVar) else 10),
                         bg="#1a1a1a", fg="#0f0", troughcolor="#333",
                         highlightthickness=0, length=200)
            s.grid(row=row, column=1, sticky="w")
        slider(0, "сглаживание (↔шлейф)", self.var_smooth, 0.05, 1.0)
        slider(1, "чувств. движения", self.var_motion, 60, 600)
        slider(2, "зачистка шума", self.var_spatial, 5, 80)
        self.canvas.bind("<Motion>", self.on_motion)
        self.root.bind("<KeyPress>", self.on_key)
        self._shown = None
        self.thread = threading.Thread(target=self.capture_loop, daemon=True)
        self.thread.start()
        self.root.after(0, self.tick)

    def on_key(self, e):
        k = e.keysym.lower()
        if k == "space": self.paused = not self.paused
        elif k in ("q", "escape"): self.quit()
        elif k == "a": self.auto = not self.auto
        elif k == "s": self.snapshot()
        elif k.isdigit() and 1 <= int(k) <= 5:
            self.palette = list(PALETTES)[int(k)-1]

    def snapshot(self):
        if self.frame is None: return
        os.makedirs("samples", exist_ok=True)
        ts = time.strftime("%H%M%S")
        np.save(f"samples/live_{ts}.npy", self.frame)
        Image.fromarray(self.render()).save(f"samples/live_{ts}.png")

    def on_motion(self, e):
        if self.frame is None: return
        x, y = e.x // SCALE, e.y // SCALE
        if 0 <= x < 320 and 0 <= y < 240:
            v = int(self.frame[y, x])
            self.canvas.itemconfig(self.status,
                text=f"x={x:3d} y={y:3d}  raw={v:5d}  ({self.palette}, span {self.lo}-{self.hi})")

    def _median(self, img, r):
        p = np.pad(img, r, mode="edge")
        stack = np.stack([p[j:j+img.shape[0], i:i+img.shape[1]]
                          for j in range(2*r+1) for i in range(2*r+1)])
        return np.median(stack, axis=0)

    def median3(self, img):
        return self._median(img, 1)

    def median5(self, img):
        return self._median(img, 2)

    def denoise(self, img):
        """Двухступенная очистка (схема пром. тепловизоров):
        1) пространственная с сохранением краёв — россыпь гасится ВНУТРИ кадра,
           шлейфу взяться неоткуда; 2) лёгкий temporal со стаbilизацией остатка.
        """
        cur = img.astype(np.float32)
        if self.hot is not None and self.hot.any():      # карта битых/шумных
            cur[self.hot] = self.median5(cur)[self.hot]
        m3 = self.median3(cur)                            # пространственная база
        gx = np.abs(np.diff(m3, axis=1, prepend=m3[:, :1]))
        gy = np.abs(np.diff(m3, axis=0, prepend=m3[:1, :]))
        grad = np.maximum(gx, gy)                         # карта границ
        gate = float(self.var_spatial.get())              # слайдер «зачистка шума»
        w = np.clip((grad - gate) / (gate * 4.6 + 1e-6), 0.0, 1.0)
        cur = m3 + w * (cur - m3)                         # детали только на краях
        if self.prev is not None:
            diff = np.abs(cur - self.prev)
            # движение = дельта ЛЮБОГО соседнего пикселя (dilate 3x3):
            # край объекта проходит за 1 кадр (шлейфа нет), равнина без
            # движения усредняется жёстко (россыпь тонет), мелкий шум
            # сам по себе ниже порога и движение не имитирует
            pd = np.pad(diff, 1, mode="edge")
            stack = np.stack([pd[j:j+diff.shape[0], i:i+diff.shape[1]]
                              for j in range(3) for i in range(3)])
            dmax = stack.max(axis=0)
            floor = float(self.var_smooth.get())          # слайдер «сглаживание»
            motion_thr = float(self.var_motion.get())     # слайдер «чувств. движения»
            alpha = np.where(dmax > motion_thr, 1.0, floor)
            cur = self.prev + (cur - self.prev) * alpha
        self.prev = cur
        return cur

    def render(self):
        f = self.denoise(self.frame)
        if self.auto:
            lo, hi = np.percentile(f, [2, 99.5])
            if self.lo == self.hi:
                self.lo, self.hi = lo, hi
            else:  # EMA — границы не дёргаются от кадра к кадру
                self.lo = 0.85 * self.lo + 0.15 * lo
                self.hi = 0.85 * self.hi + 0.15 * hi
        g = np.clip((f - self.lo) / max(self.hi - self.lo, 1) * 255, 0, 255).astype(np.uint8)
        return np.asarray(Image.fromarray(g).resize((320*SCALE, 240*SCALE), Image.NEAREST))

    def capture_loop(self):
        """Поток захвата: жрёт ВСЕ raw-кадры, всегда держит свежайший image
        (id==3), обновляет FF (id==1). Никакого ожидания в UI-потоке."""
        while not self._stop:
            try:
                raw = self.cam.fetch_raw()
                fid = int(raw[0, 2])
                if fid == 1:
                    with self._lock:
                        self.cam.ff = raw.copy()
                    continue
                if fid != 3:
                    continue
                with self._lock:
                    ff = self.cam.ff
                if ff is None:
                    continue
                x, y, w, h = 1, 4, 320, 240
                img = (raw[y:y+h, x:x+w].astype(np.int32) + 0x4000
                       - ff[y:y+h, x:x+w].astype(np.int32))
                img = np.clip(img, 0, 65535).astype(np.uint16)
                with self._lock:
                    self.frame = img
                self._cap_n += 1
                dt = time.time() - self._cap_t
                if dt > 1.0:
                    self.fps_live = self._cap_n / dt
                    print(f"[cap] {self.fps_live:.1f} к/с", flush=True)
                    self._cap_t, self._cap_n = time.time(), 0
            except Exception as ex:
                if self._stop:
                    return
                print(f"[cap] ошибка: {ex!r} — реконнект…", flush=True)
                try:
                    self.cam.reconnect()
                    self.prev = None
                except Exception as ex2:
                    print(f"[cap] жду камеру: {ex2}", flush=True)
                    time.sleep(0.5)

    def tick(self):
        try:
            if not self.paused:
                with self._lock:
                    f = self.frame
                if f is not None and (self._shown is None or f is not self._shown):
                    self._shown = f
                    self.frame = f
                    self.n += 1
            if self.frame is not None:
                img = Image.fromarray(self.render())
                self.photo = ImageTk.PhotoImage(img)
                self.canvas.create_image(0, 0, image=self.photo, anchor="nw")
            fps = self.fps_live
            self.canvas.itemconfig(self.status,
                text=f"{fps:4.1f} fps | {self.palette:8s} | {'AUTO' if self.auto else 'MANUAL'}"
                     f" | {'PAUSED' if self.paused else 'LIVE'} | курсор — пиксель")
        except Exception as ex:
            self.canvas.itemconfig(self.status, text=f"render: {ex}")
        self.root.after(16, self.tick)

    def save_settings(self):
        try:
            import json
            with open(self._cfg_path, "w") as fs:
                json.dump({"smooth": self.var_smooth.get(),
                           "motion": self.var_motion.get(),
                           "spatial": self.var_spatial.get()}, fs)
        except Exception: pass

    def quit(self):
        self._stop = True
        self.save_settings()
        try: self.cam.close()
        except Exception: pass
        self.root.destroy()

if __name__ == "__main__":
    import signal
    v = Viewer()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *a: (v.quit(), sys.exit(0)))
    v.root.mainloop()
