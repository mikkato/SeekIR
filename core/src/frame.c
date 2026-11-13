/* frame.c — каркад: валидация raw-трансфера, ROI+FF, hotmap-замена. */
#include "seekcore.h"

#include <stdlib.h>
#include <string.h>

static int cmp_f32(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

sk_err_t sk_frame_validate(const uint16_t *raw, uint32_t *counter,
                           uint16_t *fid) {
    if (!raw) return SK_ERR_SIZE;
    if (raw[0] != SK_FRAME_MAGIC) return SK_ERR_MAGIC;
    if (counter) *counter = ((uint32_t)raw[1]) & 0xFFFFu;
    if (fid) *fid = raw[2];
    return SK_OK;
}

void sk_frame_apply_ff(const uint16_t *raw, const uint16_t *ff,
                       uint16_t *roi) {
    for (int y = 0; y < SK_H; y++) {
        const uint16_t *r = raw + (y + SK_ROI_Y) * SK_RAW_W + SK_ROI_X;
        const uint16_t *f = ff + (y + SK_ROI_Y) * SK_RAW_W + SK_ROI_X;
        uint16_t *o = roi + y * SK_W;
        for (int x = 0; x < SK_W; x++) {
            int v = (int)r[x] + SK_OFFSET - (int)f[x];
            if (v < 0) v = 0;
            if (v > 65535) v = 65535;
            o[x] = (uint16_t)v;
        }
    }
}

/* 5x5 медиана с edge-pad (как np.pad(sd,2,mode='edge')+median 25 значений). */
static float median5_at(const float *p, int stride, int W, int H, int cy,
                        int cx) {
    float win[25];
    int n = 0;
    for (int j = -2; j <= 2; j++) {
        int sy = cy + j;
        if (sy < 0) sy = 0;
        if (sy >= H) sy = H - 1;
        for (int i = -2; i <= 2; i++) {
            int sx = cx + i;
            if (sx < 0) sx = 0;
            if (sx >= W) sx = W - 1;
            win[n++] = p[sy * stride + sx];
        }
    }
    qsort(win, 25, sizeof(float), cmp_f32);
    return win[12];
}

void sk_hotmap_replace(const uint16_t *in, const bool *mask, float *out) {
    static const int W = SK_W, H = SK_H;
    if (!mask) {
        for (size_t i = 0; i < (size_t)W * H; i++) out[i] = (float)in[i];
        return;
    }
    /* медиана считается по исходному полю (как в view.py: median5(cur)[hot]) */
    float *base = (float *)malloc((size_t)W * H * sizeof(float));
    for (size_t i = 0; i < (size_t)W * H; i++) base[i] = (float)in[i];
    memcpy(out, base, (size_t)W * H * sizeof(float));
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            size_t i = (size_t)y * W + x;
            if (mask[i]) out[i] = median5_at(base, W, W, H, y, x);
        }
    free(base);
}

double sk_roi_mean(const uint16_t *roi) {
    double s = 0;
    for (size_t i = 0; i < (size_t)SK_W * SK_H; i++) s += roi[i];
    return s / ((double)SK_W * SK_H);
}

const char *sk_strerror(sk_err_t e) {
    switch (e) {
    case SK_OK: return "ok";
    case SK_ERR_SIZE: return "wrong buffer size";
    case SK_ERR_MAGIC: return "missing frame magic 1401";
    case SK_ERR_FID: return "unexpected frame type";
    case SK_ERR_STATE: return "bad call sequence";
    case SK_ERR_RANGE: return "value out of range";
    case SK_ERR_IO: return "io error";
    case SK_ERR_PARSE: return "parse error";
    }
    return "unknown";
}
