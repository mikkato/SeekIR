/* tonemap.c — span/level auto (percentile 2..99.5 с numpy-точным lerp,
 * dtype как у входа: f32 на frame 0, f64 дальше) + EMA 0.85/0.15 float64
 * и картирование кадра в uint8 тем же dtype, что и numpy-эталон. */
#include "seekcore.h"

#include <stdlib.h>
#include <string.h>

#define NPIX (SK_W *SK_H)

/* numpy percentile method='linear' (numpy 2.x) в СПИСОЧНОЙ форме q
 * (как эталон: np.percentile(cur, [2, 99.5])): fraction — 0-d массив
 * float64 (strong по NEP 50) -> lerp считается в FLOAT64 независимо от
 * dtype данных, результат float64. idx = (q/100)*(n-1); ветка t>=0.5:
 * b - (b-a)*(1-t). Сортировка f64 от exact-промоутнутых значений. */
static int cmp_f64(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double percentile_f64(const double *frame, size_t n, double q) {
    static double *srt = NULL;
    static size_t cap = 0;
    if (cap < n) {
        free(srt);
        srt = (double *)malloc(n * sizeof(double));
        cap = n;
    }
    memcpy(srt, frame, n * sizeof(double));
    qsort(srt, n, sizeof(double), cmp_f64);
    double idx = (q / 100.0) * (double)(n - 1);
    size_t lo = (size_t)idx;
    if (lo >= n - 1) return srt[n - 1];
    double t = idx - (double)lo;
    double a = srt[lo], b = srt[lo + 1];
    double v = a + (b - a) * t;
    if (t >= 0.5) v = b - (b - a) * (1.0 - t);
    return v;
}

void sk_tonemap_init(sk_tonemap_t *t, bool automatic) {
    t->automatic = automatic;
    t->lo = 14500.0;
    t->hi = 17500.0;
    t->seeded = false;
}

void sk_tonemap_apply(sk_tonemap_t *t, const double *frame, bool as_f32,
                      uint8_t *out) {
    if (t->automatic) {
        /* dtype-независимо: lerp всегда float64 (см. комментарий percentile) */
        double p2 = percentile_f64(frame, NPIX, 2.0);
        double p99 = percentile_f64(frame, NPIX, 99.5);
        if (!t->seeded) {
            t->lo = p2;
            t->hi = p99;
            t->seeded = true;
        } else {
            t->lo = 0.85 * t->lo + 0.15 * p2;
            t->hi = 0.85 * t->hi + 0.15 * p99;
        }
    }
    double span = t->hi - t->lo;
    if (span < 1.0) span = 1.0; /* python max(hi-lo, 1) */
    if (as_f32) {
        float lo = (float)t->lo;
        float sp = (float)span;
        for (size_t i = 0; i < (size_t)NPIX; i++) {
            float g = ((float)frame[i] - lo) / sp * 255.0f;
            if (g < 0.f) g = 0.f;
            if (g > 255.f) g = 255.f;
            out[i] = (uint8_t)g;
        }
    } else {
        double lo = t->lo;
        for (size_t i = 0; i < (size_t)NPIX; i++) {
            double g = (frame[i] - lo) / span * 255.0;
            if (g < 0.0) g = 0.0;
            if (g > 255.0) g = 255.0;
            out[i] = (uint8_t)g;
        }
    }
}
