/* palettes.c — LUT 256x3 RGB888. Интерполяция повтором np.interp по
 * np.linspace(0,1,256) в float64, усечение при записи в uint8
 * (truncation toward zero — то же, что numpy-каст). */
#include "seekcore.h"

#include <strings.h>

typedef struct {
    double x;
    unsigned char r, g, b;
} stop_t;

typedef struct {
    const char *name;
    stop_t stops[8];
    int n;
} palette_def_t;

#define P(name, ...)                                                             \
    { #name, {__VA_ARGS__}, sizeof((stop_t[]){__VA_ARGS__}) / sizeof(stop_t) }

static const palette_def_t DEFS[SK_PAL_COUNT] = {
    [SK_PAL_IRONBOW] = P(ironbow, (stop_t){0.00, 0, 0, 30},
                         (stop_t){0.15, 20, 10, 120},
                         (stop_t){0.35, 120, 20, 150},
                         (stop_t){0.55, 220, 60, 60},
                         (stop_t){0.75, 255, 160, 0},
                         (stop_t){0.90, 255, 240, 120},
                         (stop_t){1.00, 255, 255, 255}),
    [SK_PAL_IRONBOW2] = P(ironbow2, (stop_t){0.00, 0, 0, 20},
                          (stop_t){0.12, 30, 10, 120},
                          (stop_t){0.30, 110, 0, 160},
                          (stop_t){0.50, 200, 30, 90},
                          (stop_t){0.70, 255, 120, 0},
                          (stop_t){0.85, 255, 220, 100},
                          (stop_t){1.00, 255, 255, 255}),
    [SK_PAL_RAINBOW] = P(rainbow, (stop_t){0.00, 40, 0, 80},
                         (stop_t){0.25, 0, 80, 255},
                         (stop_t){0.50, 0, 220, 120},
                         (stop_t){0.75, 255, 230, 0},
                         (stop_t){1.00, 255, 255, 255}),
    [SK_PAL_ARCTIC] = P(arctic, (stop_t){0.00, 0, 10, 40},
                        (stop_t){0.30, 0, 120, 160},
                        (stop_t){0.60, 200, 255, 255},
                        (stop_t){0.85, 255, 255, 210},
                        (stop_t){1.00, 255, 160, 40}),
    [SK_PAL_WHITEHOT] = P(whitehot, (stop_t){0.0, 0, 0, 0},
                          (stop_t){1.0, 255, 255, 255}),
    [SK_PAL_BLACKHOT] = P(blackhot, (stop_t){0.0, 255, 255, 255},
                          (stop_t){1.0, 0, 0, 0}),
    [SK_PAL_LAVA] = P(lava, (stop_t){0.00, 0, 0, 0},
                      (stop_t){0.30, 80, 0, 0}, (stop_t){0.55, 200, 40, 0},
                      (stop_t){0.75, 255, 140, 0},
                      (stop_t){0.90, 255, 230, 120},
                      (stop_t){1.00, 255, 255, 255}),
    [SK_PAL_JET] = P(jet, (stop_t){0.000, 0, 0, 128},
                     (stop_t){0.125, 0, 0, 255}, (stop_t){0.375, 0, 255, 255},
                     (stop_t){0.625, 255, 255, 0}, (stop_t){0.875, 255, 0, 0},
                     (stop_t){1.000, 128, 0, 0}),
    [SK_PAL_MEDICAL] = P(medical, (stop_t){0.00, 255, 255, 255},
                         (stop_t){0.25, 200, 180, 255},
                         (stop_t){0.40, 0, 100, 255}, (stop_t){0.50, 0, 0, 0},
                         (stop_t){0.60, 255, 100, 0},
                         (stop_t){0.80, 255, 220, 0},
                         (stop_t){1.00, 255, 255, 255}),
};

#undef P

static double interp1(const stop_t *s, int n, double x, int ch) {
    if (x <= s[0].x) return (&s[0].r)[ch];
    for (int i = 1; i < n; i++) {
        if (x <= s[i].x) {
            double t = (x - s[i - 1].x) / (s[i].x - s[i - 1].x);
            double a = (&s[i - 1].r)[ch], b = (&s[i].r)[ch];
            return a + (b - a) * t;
        }
    }
    return (&s[n - 1].r)[ch];
}

void sk_palette_lut(sk_palette_t p, uint8_t lut[256][3]) {
    const palette_def_t *d = &DEFS[p];
    const double step = 1.0 / 255.0; /* numpy linspace: arange*step */
    for (int i = 0; i < 256; i++) {
        double x = (i == 255) ? 1.0 : (double)i * step; /* y[-1]=stop */
        for (int c = 0; c < 3; c++)
            lut[i][c] = (unsigned char)interp1(d->stops, d->n, x, c);
    }
}

void sk_palette_map(const uint8_t lut[256][3], const uint8_t *gray,
                    uint8_t *rgb) {
    for (size_t i = 0; i < (size_t)SK_W * SK_H; i++) {
        rgb[i * 3 + 0] = lut[gray[i]][0];
        rgb[i * 3 + 1] = lut[gray[i]][1];
        rgb[i * 3 + 2] = lut[gray[i]][2];
    }
}

const char *sk_palette_name(sk_palette_t p) {
    if ((int)p < 0 || p >= SK_PAL_COUNT) return "?";
    return DEFS[p].name;
}

int sk_palette_by_name(const char *name) {
    for (int i = 0; i < SK_PAL_COUNT; i++)
        if (!strcasecmp(name, DEFS[i].name)) return i;
    return -1;
}
