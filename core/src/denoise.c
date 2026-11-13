/* denoise.c — F9-цепочка: пространственная (медиана 3x3 + гейт границ) +
 * temporal (бинарный гейт dilate3x3). Побитово повторяет view.py denoise().
 * Все вычисления — float32 в том же порядке операций, что numpy. */
#include "seekcore.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define NPIX (SK_W *SK_H)

static int cmp_f32(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

static inline int cl(int v, int lo, int hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

/* медиана r..r окна с edge-pad (r=1 → 3x3, 9 значений, центр sorted[4]) */
static void median_filter(const float *in, float *out, int r) {
    int side = 2 * r + 1, n = side * side;
    float *win = (float *)malloc((size_t)n * sizeof(float));
    for (int y = 0; y < SK_H; y++) {
        for (int x = 0; x < SK_W; x++) {
            int k = 0;
            for (int j = -r; j <= r; j++) {
                int sy = cl(y + j, 0, SK_H - 1);
                for (int i = -r; i <= r; i++) {
                    int sx = cl(x + i, 0, SK_W - 1);
                    win[k++] = in[sy * SK_W + sx];
                }
            }
            qsort(win, (size_t)n, sizeof(float), cmp_f32);
            out[y * SK_W + x] = win[n / 2];
        }
    }
    free(win);
}

void sk_denoise_init(sk_denoise_t *d, float smooth, int motion, int spatial) {
    d->smooth = smooth;
    d->motion = motion;
    d->spatial = spatial;
    d->prev = (double *)malloc((size_t)NPIX * sizeof(double));
    d->prev32 = (float *)malloc((size_t)NPIX * sizeof(float));
    d->has_prev = false;
    d->prev_is_f32 = false;
}

void sk_denoise_free(sk_denoise_t *d) {
    free(d->prev);
    free(d->prev32);
    d->prev = NULL;
    d->prev32 = NULL;
    d->has_prev = false;
}

void sk_denoise_reset(sk_denoise_t *d) {
    d->has_prev = false;
    d->prev_is_f32 = false;
}

void sk_denoise_frame(sk_denoise_t *d, const float *in, double *out,
                      bool *out_from_f32) {
    static float *m3_buf = NULL, *sp_buf = NULL;
    if (!m3_buf) {
        m3_buf = (float *)malloc((size_t)NPIX * sizeof(float));
        sp_buf = (float *)malloc((size_t)NPIX * sizeof(float));
    }

    /* 1) пространственная база: медиана 3x3 */
    median_filter(in, m3_buf, 1);

    /* 2) гейт границ: w = clip((grad-SPATIAL)/(SPATIAL*4.6+1e-6),0,1);
     *    sp = m3 + w*(in-m3) — всё float32 (как numpy). grad читает m3,
     *    смешанное пишется в отдельный sp_buf. */
    float gate = (float)d->spatial;
    float den = (float)((double)d->spatial * 4.6 + 1e-6);
    for (int y = 0; y < SK_H; y++) {
        for (int x = 0; x < SK_W; x++) {
            size_t i = (size_t)y * SK_W + x;
            float m = m3_buf[i];
            float gx = fabsf(m - m3_buf[y * SK_W + (x > 0 ? x - 1 : 0)]);
            float gy = fabsf(m - m3_buf[(y > 0 ? y - 1 : 0) * SK_W + x]);
            float grad = gx > gy ? gx : gy;
            float w = (grad - gate) / den;
            if (w < 0.f) w = 0.f;
            if (w > 1.f) w = 1.f;
            sp_buf[i] = m + w * (in[i] - m);
        }
    }

    /* 3) temporal с точным dtype-режимом numpy. */
    double floor_a = (double)d->smooth;
    if (!d->has_prev) {
        /* frame 0: prev = sp (float32), кадр = sp (f32-происхождение) */
        for (size_t i = 0; i < (size_t)NPIX; i++) {
            d->prev32[i] = sp_buf[i];
            d->prev[i] = (double)sp_buf[i];
            out[i] = (double)sp_buf[i];
        }
        d->has_prev = true;
        d->prev_is_f32 = true;
        if (out_from_f32) *out_from_f32 = true;
        return;
    }
    if (out_from_f32) *out_from_f32 = false;

    /* dilate3x3(|cur - prev|): diff в f32 только на frame 1 (prev был f32),
     * дальше — double. Порог сравнивается в dtype diff (слабый скаляр 440.0). */
    static double *dm = NULL;
    if (!dm) dm = (double *)malloc((size_t)NPIX * sizeof(double));
    if (d->prev_is_f32) {
        static float *diff32 = NULL;
        if (!diff32) diff32 = (float *)malloc((size_t)NPIX * sizeof(float));
        for (size_t i = 0; i < (size_t)NPIX; i++)
            diff32[i] = fabsf(sp_buf[i] - d->prev32[i]);
        for (int y = 0; y < SK_H; y++)
            for (int x = 0; x < SK_W; x++) {
                float dmax = 0.f;
                for (int j = -1; j <= 1; j++) {
                    int sy = cl(y + j, 0, SK_H - 1);
                    for (int i = -1; i <= 1; i++) {
                        int sx = cl(x + i, 0, SK_W - 1);
                        float dv = diff32[(size_t)sy * SK_W + sx];
                        if (dv > dmax) dmax = dv;
                    }
                }
                dm[(size_t)y * SK_W + x] = (double)dmax;
            }
    } else {
        static double *diff64 = NULL;
        if (!diff64) diff64 = (double *)malloc((size_t)NPIX * sizeof(double));
        for (size_t i = 0; i < (size_t)NPIX; i++)
            diff64[i] = fabs((double)sp_buf[i] - d->prev[i]);
        for (int y = 0; y < SK_H; y++)
            for (int x = 0; x < SK_W; x++) {
                double dmax = 0.0;
                for (int j = -1; j <= 1; j++) {
                    int sy = cl(y + j, 0, SK_H - 1);
                    for (int i = -1; i <= 1; i++) {
                        int sx = cl(x + i, 0, SK_W - 1);
                        double dv = diff64[(size_t)sy * SK_W + sx];
                        if (dv > dmax) dmax = dv;
                    }
                }
                dm[(size_t)y * SK_W + x] = dmax;
            }
    }
    double thr = (double)d->motion;
    for (size_t i = 0; i < (size_t)NPIX; i++) {
        double alpha = dm[i] > thr ? 1.0 : floor_a;
        double prevv = d->prev[i];
        double curv = (double)sp_buf[i];
        double v = prevv + (curv - prevv) * alpha;
        d->prev[i] = v;
        out[i] = v;
    }
    d->prev_is_f32 = false;
}
