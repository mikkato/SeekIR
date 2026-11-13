/* seekproc — golden-харнес E1: прогоняет F9-цепочку core/ по дампу
 * сырых трансферов и пишет промежуточные буферы для побайтовой сверки
 * с Python-эталоном (tools/ref_pipeline.py).
 *
 * seekproc --dumpdir DIR --hotmap hot.bin --out OUTDIR [--pal ironbow]
 *          [--probe x,y] [--calib file]
 * hot.bin — 320*240 uint8 (0/1). Вход: DIR/img_NNNN.raw + DIR/ff_NNNN.raw.
 */
#include "seekcore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NPIX (SK_W *SK_H)

static unsigned char *read_file(const char *path, size_t *n) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    unsigned char *b = (unsigned char *)malloc((size_t)sz);
    if (fread(b, 1, (size_t)sz, fp) != (size_t)sz) {
        fclose(fp);
        free(b);
        return NULL;
    }
    fclose(fp);
    *n = (size_t)sz;
    return b;
}

static int write_file(const char *path, const void *b, size_t n) {
    FILE *fp = fopen(path, "wb");
    if (!fp) return -1;
    size_t w = fwrite(b, 1, n, fp);
    fclose(fp);
    return w == n ? 0 : -1;
}

int main(int argc, char **argv) {
    const char *dumpdir = NULL, *hotmap = NULL, *outdir = NULL;
    const char *palname = "ironbow", *calib = NULL;
    int probe_x = -1, probe_y = -1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dumpdir") && i + 1 < argc) dumpdir = argv[++i];
        else if (!strcmp(argv[i], "--hotmap") && i + 1 < argc) hotmap = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) outdir = argv[++i];
        else if (!strcmp(argv[i], "--pal") && i + 1 < argc) palname = argv[++i];
        else if (!strcmp(argv[i], "--calib") && i + 1 < argc) calib = argv[++i];
        else if (!strcmp(argv[i], "--probe") && i + 1 < argc) {
            if (sscanf(argv[++i], "%d,%d", &probe_x, &probe_y) != 2) {
                fprintf(stderr, "--probe x,y\n");
                return 2;
            }
        } else {
            fprintf(stderr,
                    "usage: seekproc --dumpdir D --hotmap h.bin --out O "
                    "[--pal P] [--probe x,y] [--calib f]\n");
            return 2;
        }
    }
    if (!dumpdir || !outdir) { fprintf(stderr, "нужны --dumpdir и --out\n"); return 2; }

    bool *mask = NULL;
    if (hotmap) {
        size_t n = 0;
        unsigned char *hb = read_file(hotmap, &n);
        if (!hb || n != NPIX) {
            fprintf(stderr, "hotmap: жду %d B (%s)\n", NPIX, hotmap);
            return 2;
        }
        mask = (bool *)malloc(NPIX);
        for (size_t i = 0; i < NPIX; i++) mask[i] = hb[i] != 0;
        free(hb);
    }

    int pal = sk_palette_by_name(palname);
    if (pal < 0) { fprintf(stderr, "палитра? %s\n", palname); return 2; }
    uint8_t lut[256][3];
    sk_palette_lut((sk_palette_t)pal, lut);

    sk_planck_t planck;
    sk_planck_default(&planck);
    if (calib && sk_planck_load(&planck, calib) != SK_OK) {
        fprintf(stderr, "calib: не открыт %s\n", calib);
        return 2;
    }
    sk_scene_t scene;
    sk_scene_default(&scene);

    sk_denoise_t den;
    sk_denoise_init(&den, SK_SMOOTH_DEFAULT, SK_MOTION_DEFAULT,
                    SK_SPATIAL_DEFAULT);
    sk_tonemap_t tm;
    sk_tonemap_init(&tm, true);

    static uint16_t raw[SK_RAW_WORDS], ff[SK_RAW_WORDS], roi[NPIX];
    static float hotbuf[NPIX];
    static double denbuf[NPIX];
    static float den32[NPIX];
    static uint8_t gray[NPIX], rgb[NPIX * 3];

    char path[512];
    int nframes = 0;
    for (int idx = 0;; idx++) {
        snprintf(path, sizeof(path), "%s/img_%04d.raw", dumpdir, idx);
        size_t n = 0;
        unsigned char *b = read_file(path, &n);
        if (!b) break;
        if (n != SK_RAW_BYTES) { fprintf(stderr, "%s: размер %zu\n", path, n); return 2; }
        memcpy(raw, b, n);
        free(b);
        snprintf(path, sizeof(path), "%s/ff_%04d.raw", dumpdir, idx);
        b = read_file(path, &n);
        if (!b || n != SK_RAW_BYTES) { fprintf(stderr, "нет FF к %d\n", idx); return 2; }
        memcpy(ff, b, n);
        free(b);

        uint32_t counter;
        uint16_t fid;
        sk_err_t e = sk_frame_validate(raw, &counter, &fid);
        if (e != SK_OK) { fprintf(stderr, "frame %d: %s\n", idx, sk_strerror(e)); return 2; }
        if (fid != SK_FID_IMAGE) { fprintf(stderr, "frame %d: fid=%d не image\n", idx, fid); return 2; }

        sk_frame_apply_ff(raw, ff, roi);
        sk_hotmap_replace(roi, mask, hotbuf);
        bool from_f32 = false;
        sk_denoise_frame(&den, hotbuf, denbuf, &from_f32);
        for (size_t i = 0; i < NPIX; i++) den32[i] = (float)denbuf[i];
        sk_tonemap_apply(&tm, denbuf, from_f32, gray);
        sk_palette_map(lut, gray, rgb);

        char base[64];
        snprintf(base, sizeof(base), "frame_%04d", idx);
        char p[512];
        snprintf(p, sizeof(p), "%s/%s.roi.u16", outdir, base);
        if (write_file(p, roi, NPIX * 2)) { perror(p); return 2; }
        snprintf(p, sizeof(p), "%s/%s.den.f32", outdir, base);
        if (write_file(p, den32, NPIX * 4)) { perror(p); return 2; }
        snprintf(p, sizeof(p), "%s/%s.den.f64", outdir, base);
        if (write_file(p, denbuf, NPIX * 8)) { perror(p); return 2; }
        snprintf(p, sizeof(p), "%s/%s.gray.u8", outdir, base);
        if (write_file(p, gray, NPIX)) { perror(p); return 2; }
        snprintf(p, sizeof(p), "%s/%s.rgb", outdir, base);
        if (write_file(p, rgb, NPIX * 3)) { perror(p); return 2; }

        double tmin = 1e30, tmax = -1e30, tsum = 0;
        static double tmap[NPIX];
        int px_ok = probe_x >= 0 && probe_x < SK_W && probe_y < SK_H;
        double tprobe = 0;
        for (int y = 0; y < SK_H; y++)
            for (int x = 0; x < SK_W; x++) {
                double t = sk_signal_to_celsius(&planck, &scene, roi[y * SK_W + x]);
                tmap[y * SK_W + x] = t;
                if (t < tmin) tmin = t;
                if (t > tmax) tmax = t;
                tsum += t;
                if (px_ok && x == probe_x && y == probe_y) tprobe = t;
            }
        snprintf(p, sizeof(p), "%s/%s.temp.f64", outdir, base);
        if (write_file(p, tmap, NPIX * 8)) { perror(p); return 2; }
        printf("frame %d: counter=%u mean=%.1f | T min/max/mean = %6.1f/%6.1f/%6.1f C | span=%.1f..%.1f [%.17g %.17g]",
               idx, counter, sk_roi_mean(roi), tmin, tmax, tsum / NPIX, tm.lo, tm.hi,
               tm.lo, tm.hi);
        if (px_ok) printf(" | probe(%d,%d)=%.1f C", probe_x, probe_y, tprobe);
        printf("\n");
        nframes++;
    }
    printf("[OK] %d кадров, финальный span %.2f..%.2f\n", nframes, tm.lo, tm.hi);
    sk_denoise_free(&den);
    free(mask);
    return nframes > 0 ? 0 : 1;
}
