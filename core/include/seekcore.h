/* seekcore.h — SeekIR E1: портативное C11-ядро (только libc).
 *
 * Цепочка кадра (ТЗ F9, зафиксирована 05.11.2026, порядок обязателен):
 *   raw(342x260 u16 LE) --validate--> ROI-кроп 320x240 += 0x4000 - FF
 *   -> hotmap: шумные пиксели <- медиана 5x5
 *   -> пространственная база медиана 3x3, детали возвращаются на границах
 *      (гейт |grad| > SPATIAL, ширина 4.6*SPATIAL)
 *   -> temporal: бинарный гейт dilate3x3(|delta|) > MOTION;
 *      вне движения cur = prev + (cur-prev)*SMOOTH
 *   -> span/level auto percentile 2..99.5 + EMA 0.85/0.15 -> uint8
 *   -> LUT-палитра -> RGB
 * Радиометрия: FLIR-стиль Планк (ТЗ §3) поверх FF-скорректированного сигнала.
 *
 * Все float32-этапы побитово совместимы с эталонной Python-реализацией
 * tools/ref_pipeline.py (тот же порядок операций, то же округление).
 */
#ifndef SEEKCORE_H
#define SEEKCORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- геометрия сырого трансфера (App. А ТЗ) ---- */
#define SK_RAW_W 342
#define SK_RAW_H 260
#define SK_RAW_WORDS (SK_RAW_W * SK_RAW_H)          /* 88920 слов */
#define SK_RAW_BYTES (SK_RAW_WORDS * 2)              /* 177840 B   */
#define SK_BULK_CHUNK 13680                          /* 6840 слов  */
#define SK_ROI_X 1
#define SK_ROI_Y 4
#define SK_W 320
#define SK_H 240
#define SK_OFFSET 0x4000
#define SK_FRAME_MAGIC 1401                          /* word[0]      */

/* типы кадра в word[2] */
#define SK_FID_FF 1
#define SK_FID_IMAGE 3
#define SK_FID_OFFSET 6
#define SK_FID_GAIN 20

/* ---- утверждённый baseline F9 ---- */
#define SK_SMOOTH_DEFAULT 0.75f
#define SK_MOTION_DEFAULT 440
#define SK_SPATIAL_DEFAULT 75

typedef enum {
    SK_OK = 0,
    SK_ERR_SIZE = -1,       /* буфер не 342x260 слов            */
    SK_ERR_MAGIC = -2,      /* нет маркера 1401 в word[0]       */
    SK_ERR_FID = -3,        /* неожиданный тип кадра            */
    SK_ERR_STATE = -4,      /* неверная последовательность вызовов */
    SK_ERR_RANGE = -5,
    SK_ERR_IO = -6,
    SK_ERR_PARSE = -7,
} sk_err_t;

/* ---- каркад: валидация + FF-коррекция ---- */

/* Разобрать сырой трансфер (SK_RAW_BYTES LE). Проверяет magic/тип,
 * возвращает word[1] (counter) в *counter и word[2] в *fid. */
sk_err_t sk_frame_validate(const uint16_t *raw, uint32_t *counter,
                           uint16_t *fid);

/* roi = clip(raw[ROI] + 0x4000 - ff[ROI], 0, 65535). raw/ff — 342x260. */
void sk_frame_apply_ff(const uint16_t *raw, const uint16_t *ff,
                       uint16_t *roi /* SK_W*SK_H */);

/* Замена пикселей hotmap (true = шумный) медианой 5x5, edge-pad, float32.
 * mask может быть NULL (тогда копия). in/out —SK_W*SK_H. */
void sk_hotmap_replace(const uint16_t *in, const bool *mask,
                       float *out /* SK_W*SK_H float32 */);

/* ---- денуаз F9 (stateful: держит prev) ----
 * Точный dtype-режим Python-этталона (view.py/ref_pipeline):
 *   frame 0: prev = пространственный результат (float32-точное)
 *   frame 1: diff = |cur32 - prev32| в FLOAT32, alpha — FLOAT64
 *            (np.where(bool, 1.0, 0.75) даёт float64), смешивание в float64
 *   frame >=2: prev float64 -> diff/смешивание в float64
 * hence prev хранится double, out кадра — double (в файл пишется (float) —
 * это тот же astype(float32), что у эталона). */
typedef struct {
    float smooth;           /* 0.05..1.0  (baseline 0.75)  */
    int motion;             /* 60..600    (baseline 440)   */
    int spatial;            /* 5..80      (baseline 75)    */
    double *prev;           /* internal, точная цепочка prev      */
    float *prev32;          /* internal, prev до первого смешивания */
    bool has_prev;
    bool prev_is_f32;       /* true ровно на frame 1 (diff в f32) */
} sk_denoise_t;

void sk_denoise_init(sk_denoise_t *d, float smooth, int motion, int spatial);
void sk_denoise_free(sk_denoise_t *d);
void sk_denoise_reset(sk_denoise_t *d);
/* Один проход F9: hotmap уже применён к in (float32). prev/смешивание —
 * double (кроме diff frame 1, f32, как у numpy). out — кадр для тонмаппинга
 * (double). *out_from_f32 = true на frame 0 (ethalon держит там float32,
 * percentile/gray считаются в f32). */
void sk_denoise_frame(sk_denoise_t *d, const float *in, double *out,
                      bool *out_from_f32);

/* ---- span/level + тонмаппинг ---- */
typedef struct {
    bool automatic;         /* false = держать ручные lo/hi         */
    double lo, hi;          /* текущие границы (float64, как в Python) */
    bool seeded;            /* первый кадр авто-режима задаёт границы */
} sk_tonemap_t;

void sk_tonemap_init(sk_tonemap_t *t, bool automatic);
/* Авто: percentile 2..99.5 с numpy-точным lerp; dtype сортировки/lerp —
 * float32 если as_f32 (frame 0), иначе float64. EMA 0.85/0.15 в float64.
 * Картирование: float32-арифметика если as_f32, иначе float64. */
void sk_tonemap_apply(sk_tonemap_t *t, const double *frame, bool as_f32,
                      uint8_t *out);

/* ---- палитры ---- */
typedef enum {
    SK_PAL_IRONBOW = 0, SK_PAL_IRONBOW2, SK_PAL_RAINBOW, SK_PAL_ARCTIC,
    SK_PAL_WHITEHOT, SK_PAL_BLACKHOT, SK_PAL_LAVA, SK_PAL_JET,
    SK_PAL_MEDICAL, SK_PAL_COUNT
} sk_palette_t;

/* Заполнить LUT 256x3 RGB888 (truncation как у numpy-присваивания). */
void sk_palette_lut(sk_palette_t p, uint8_t lut[256][3]);
/* gray -> RGB по LUT. */
void sk_palette_map(const uint8_t lut[256][3], const uint8_t *gray,
                    uint8_t *rgb /* SK_W*SK_H*3 */);
const char *sk_palette_name(sk_palette_t p);
int sk_palette_by_name(const char *name); /* -> sk_palette_t или -1 */

/* ---- радиометрия (FLIR-стиль Планк, ТЗ §3) ---- */
typedef struct {
    double r1, b, f, o, r2; /* планковские константы (калибр-файл) */
} sk_planck_t;

typedef struct {
    double emissivity;      /* ε  (0.01..1.0)            */
    double t_refl_c;        /* отражённая, °C            */
    double t_atm_c;         /* воздух, °C                */
    double distance_m;      /* дистанция                 */
    double rel_humidity;    /* RH 0..100, для τ          */
} sk_scene_t;

void sk_scene_default(sk_scene_t *s); /* eps=0.95, refl=atm=20C, 1m, RH50 */

/* Атмосферное пропускание (упрощённая INO/FLIR-модель, в диапазоне 0..~30 м). */
double sk_atm_tau(double distance_m, double t_atm_c, double rel_humidity);

/* raw-сигнал (FF-скорр. счёт) -> °C по полной цепочке. */
double sk_signal_to_celsius(const sk_planck_t *p, const sk_scene_t *s,
                            double signal);
/* °C -> сигнал (обратная планка, для зондов/алиасинга) */
double sk_celsius_to_signal(const sk_planck_t *p, double celsius);

/* Калибровка по чёрному телу: две точки (сигнал,°C) -> r2,o при фикс. r1,b,f.
 * Возвращает false, если точки вырождены. */
bool sk_planck_fit2(const sk_planck_t *base, double s1, double c1,
                    double s2, double c2, sk_planck_t *out);

/* Калибр-файл "key = value" (utf-8, # комментарии). Ключи: planck_r1,
 * planck_b, planck_f, planck_o, planck_r2. */
sk_err_t sk_planck_load(sk_planck_t *p, const char *path);

/* Заполнить общесетевым дефолтом (перекрывается sk_planck_load). */
void sk_planck_default(sk_planck_t *p);

/* ---- утилиты ---- */
const char *sk_strerror(sk_err_t e);
/* Средний сигнал ROI кадра (для отладки/зонда по центру). */
double sk_roi_mean(const uint16_t *roi);

#ifdef __cplusplus
}
#endif
#endif /* SEEKCORE_H */
