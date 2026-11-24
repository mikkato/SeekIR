/* seekcap.c — продуктовый API захвата (E2). Конвейер перенесён из seekd.c
 * (E1, проверен на железе 05.11.2026: 6.9 к/с, 0 ошибок, reconnect-устойчив).
 *
 * Поток рабочий: libusb-события + pump. Callback-доставка готового кадра.
 *darwin-правило: control-трансферы только из рабочего потока (см. skill).
 */
#include "seekcap.h"

#include <libusb-1.0/libusb.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#define VID 0x289D
#define PID 0x0011
#define EP_IN 0x81
#define BMREQ_OUT 0x41
#define BMREQ_IN 0xC1

#define CMD_SET_OPERATION_MODE 60
#define CMD_SET_IMAGE_PROCESSING_MODE 62
#define CMD_READ_CHIP_ID 54
#define CMD_GET_FACTORY_SETTINGS 88
#define CMD_SET_FACTORY_SETTINGS_FEATURES 86
#define CMD_GET_FIRMWARE_INFO 78
#define CMD_SET_FIRMWARE_INFO_FEATURES 85
#define CMD_START_GET_IMAGE_TRANSFER 83
#define CMD_TARGET_PLATFORM 84

struct skcap {
    /* внешний API */
    skcap_cb cb;
    void *user;
    skcap_cb ff_cb;    /* доп. канал FF-кадров (карта шума), необязательный */
    void *ff_user;
    bool *hot;

    pthread_t th;
    volatile int quit;
    int connected;
    pthread_mutex_t mtx;   /* защита рантайм-настроек от рабочего потока */

    libusb_context *ctx;
    libusb_device_handle *h;

    /* конвейер */
    uint8_t *asm_buf;
    size_t fill;
    size_t req_bytes;
    int need_request;      /* 1 = pump должен сделать request; -1 = reconnect */
    volatile int chunk_inflight; /* ровно один chunk-URB в полёте           */
    int err_streak;        /* K4: подряд неудач chunk без успешных данных    */
    uint16_t *ff;
    float *gain;         /* NUC-карта попиксельного усиления из кадра ID4 (PRO):
                          * avg/g; мёртвые пиксели (g<100) — 0 -> заполнение
                          * соседями. Приходит на старте один раз. */
    int gain_ready;
    long images, ffs, errors, resyncs;
    long fid_hist[64];   /* счётчик всех типов кадров (диагностика калибрации) */
    double t_fps_start;
    int n_fps;
    double fps;
    double t_dev_c;        /* внутр. термистор FPA, °C */

    /* настройки (под mtx) */
    sk_palette_t pal;
    float smooth; int motion, spatial; int den_reset;
    bool span_manual; double man_lo, man_hi;
    sk_scene_t scene;
    sk_planck_t planck; bool planck_set;
    double lin_k, lin_off, lin_ref; /* AUD-R2: fit ЛИНЕЙНОЙ модели по 2 телам;
                                     * lin_k=0 => некалибровано (58.6, off=0) */
    double mean_d;       /* AUD-R2: средний gain-корр. D кадра (для лин. фита) */
    double dref_ema;     /* скользящая медиана gain-корр. D (самопривязка 0 °C) */

    /* дампы */
    char dumpdir[512];
    char gainpath[512];  /* кэш gain-карты ID4 (приходит только при подаче питания) */
    int frame_idx;

    /* core-состояние (только рабочий поток) */
    sk_denoise_t den;
    sk_tonemap_t tm;
    uint8_t lut[256][3];

    /* кадры для колбэка */
    uint8_t rgb[SK_W * SK_H * 3];
    double temp[SK_W * SK_H];
    uint16_t roi[SK_W * SK_H];
};

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static int cmd_out(skcap_t *c, int cmd, const uint8_t *data, int len) {
    int r = libusb_control_transfer(c->h, BMREQ_OUT, (uint8_t)cmd, 0, 0,
                                    (unsigned char *)data, (uint16_t)len, 500);
    return r < 0 ? r : 0;
}
static int cmd_in(skcap_t *c, int cmd, uint8_t *buf, int len) {
    int r = libusb_control_transfer(c->h, BMREQ_IN, (uint8_t)cmd, 0, 0,
                                    buf, (uint16_t)len, 500);
    return r < 0 ? r : 0;
}
static int request_frame(skcap_t *c) {
    uint32_t words = SK_RAW_WORDS;
    uint8_t p[4] = {(uint8_t)(words & 0xFF), (uint8_t)((words >> 8) & 0xFF),
                    (uint8_t)((words >> 16) & 0xFF),
                    (uint8_t)((words >> 24) & 0xFF)};
    return cmd_out(c, CMD_START_GET_IMAGE_TRANSFER, p, 4);
}

static void submit_chunk(skcap_t *c);

static void process_frame(skcap_t *c, uint16_t *raw) {
    /* AUD-R2: снапшот рантайм-настроек под мьютексом. Раньше den.*, dumpdir,
     * gainpath, ff_cb читались вне лока, куда писали API-сеттеры — гонки. */
    float den_smooth; int den_motion, den_spatial;
    char dumpdir[512], gainpath[512];
    skcap_cb ff_cb; void *ff_user;
    pthread_mutex_lock(&c->mtx);
    den_smooth = c->den.smooth; den_motion = c->den.motion; den_spatial = c->den.spatial;
    snprintf(dumpdir, sizeof(dumpdir), "%s", c->dumpdir);
    snprintf(gainpath, sizeof(gainpath), "%s", c->gainpath);
    ff_cb = c->ff_cb; ff_user = c->ff_user;
    pthread_mutex_unlock(&c->mtx);
    /* c->den — состояние только рабочего потока; параметры применим локально */
    c->den.smooth = den_smooth; c->den.motion = den_motion; c->den.spatial = den_spatial;

    uint32_t counter;
    uint16_t fid;
    if (sk_frame_validate(raw, &counter, &fid) != SK_OK) {
        c->resyncs++;
        return;
    }
    /* диагностика калибровочного потока: гистограмма всех типов кадров
     * (PRO на старте шлёт 4/7/8/9/14 — раньше молча отбрасывались) */
    if (fid < 64) c->fid_hist[fid]++;
    if (fid != SK_FID_FF && fid != SK_FID_IMAGE && dumpdir[0]) {
        char cp[600];
        snprintf(cp, sizeof(cp), "%s/cal_%02u.raw", dumpdir, fid);
        FILE *cf = fopen(cp, "wb"); /* перезапись: нужен последний экземпляр */
        if (cf) { fwrite(raw, 1, SK_RAW_BYTES, cf); fclose(cf); }
    }
    if (fid == 4) {
        /* NUC-карта попиксельного усиления (PRO, приходит на старте):
         * gain = avg(g)/g, мёртвые пиксели (g<100) -> 1.0 (нейтрально).
         * Проверено на дампе: убирает фикс. узор 292->56 counts,
         * временной FPN 915->119. Сохраняем на диск: камера шлёт её
         * только при подаче питания. */
        pthread_mutex_lock(&c->mtx); /* AUD-R2: race with gain_path */
        if (!c->gain) c->gain = (float *)malloc(sizeof(float) * SK_W * SK_H);
        pthread_mutex_unlock(&c->mtx);
        if (c->gain) {
            double sum = 0.0;
            int nvalid = 0;
            static uint16_t gtmp[SK_W * SK_H];
            for (int y = 0; y < SK_H; y++)
                for (int x = 0; x < SK_W; x++) {
                    uint16_t g = raw[(y + SK_ROI_Y) * SK_RAW_W + (x + SK_ROI_X)];
                    gtmp[y * SK_W + x] = g;
                    if (g >= 100) { sum += g; nvalid++; }
                }
            if (nvalid > SK_W * SK_H / 2) {
                float avg = (float)(sum / nvalid);
                for (int i = 0; i < SK_W * SK_H; i++) {
                    float g = (gtmp[i] >= 100) ? avg / (float)gtmp[i] : 1.0f;
                    if (g < 0.5f) g = 0.5f;
                    if (g > 2.0f) g = 2.0f;
                    if (gtmp[i] < 100) g = 1.0f;
                    c->gain[i] = g;
                }
                c->gain_ready = 1;
                if (gainpath[0]) {
                    char tmpg[600];
                    snprintf(tmpg, sizeof(tmpg), "%s.tmp", gainpath);
                    FILE *gf = fopen(tmpg, "wb");
                    if (gf) {
                        fwrite(c->gain, sizeof(float), (size_t)SK_W * SK_H, gf);
                        fclose(gf);
                        remove(gainpath);
                        rename(tmpg, gainpath); /* AUD-R2: atomic cache swap */
                    }
                }
            }
        }
        return;
    }
    if (fid == SK_FID_FF) {
        if (!c->ff) c->ff = (uint16_t *)malloc(SK_RAW_BYTES);
        if (c->ff) memcpy(c->ff, raw, SK_RAW_BYTES);
        c->ffs++;
        /* доп. доставка FF-ROI для построения карты шума (win/HotmapBuilder);
         * канал опциональный, macOS-Swift им не пользуется */
        if (ff_cb) {
            static uint16_t ffroi[SK_W * SK_H];
            for (int y = 0; y < SK_H; y++)
                for (int x = 0; x < SK_W; x++)
                    ffroi[y * SK_W + x] = raw[(y + SK_ROI_Y) * SK_RAW_W + (x + SK_ROI_X)];
            skcap_frame_t f = {0};
            f.rgb = c->rgb; f.temp = c->temp; f.signal = ffroi;
            f.ffs = c->ffs;
            ff_cb(ff_user, &f);
        }
        return;
    }
    if (fid != SK_FID_IMAGE || !c->ff) return;

    /* внутр. термистор FPA: raw[5] (PRO), бетта-кривая sfalexrog, ref
     * поданкорен на наш экземпляр: raw[5]=7222 при холодном старте =
     * комната ~20.5 C (ref=7167, B=200). */
    {
        double x = (double)raw[5];
        c->t_dev_c = (x > 0.0) ? (1.0 / (log(x / 7167.0) / 200.0 + 1.0 / 297.0) - 273.15) : 0.0;
    }

    static float hot[SK_W * SK_H];
    static double den64[SK_W * SK_H];
    static uint8_t gray[SK_W * SK_H];
    bool from_f32 = false;
    pthread_mutex_lock(&c->mtx);
    if (c->den_reset) { sk_denoise_reset(&c->den); c->den_reset = 0; }
    if (c->span_manual) {
        c->tm.automatic = false; c->tm.lo = c->man_lo; c->tm.hi = c->man_hi;
    } else {
        c->tm.automatic = true;
    }
    sk_scene_t scene = c->scene;
    sk_planck_t planck = c->planck;
    pthread_mutex_unlock(&c->mtx);

    sk_frame_apply_ff(raw, c->ff, c->roi);
    sk_hotmap_replace(c->roi, c->hot, hot);
    sk_denoise_frame(&c->den, hot, den64, &from_f32);
    sk_tonemap_apply(&c->tm, den64, from_f32, gray);
    sk_palette_map(c->lut, gray, c->rgb);

    /* === радиометрия PRO: gain-NUC (ID4) + линейная шкала с самопривязкой ===
     * D = (den − 16384) * gain — скорр. по шторке и по попикс. усилению.
     * Абсолют: Dref = EMA медианы D (сцена~равновесие с FPA, аналог
     * environment_temperature SDK) -> T = T_dev + (D − Dref)/k.
     * Golden не затронут: seekproc гоняет свой путь без gain-карты. */
    if (c->gain_ready) {
        double sum = 0.0;
        for (size_t i = 0; i < (size_t)SK_W * SK_H; i++)
            sum += (den64[i] - 16384.0) * (double)c->gain[i];
        double dmed = sum / ((double)SK_W * SK_H);
        if (c->dref_ema < -1e8) c->dref_ema = dmed;
        else c->dref_ema += 0.02 * (dmed - c->dref_ema);
        c->mean_d = dmed; /* AUD-R2: для skcap_linear_fit из UI */
        /* counts/°C: 58.6 по кривой ID9; после fit по 2 опорным телам —
         * свои k/off с опорой dref на момент калибровки (lin_ref) */
        const double k = (c->lin_k > 0.0) ? c->lin_k : 58.6;
        const double off = (c->lin_k > 0.0)
            ? c->lin_off + (c->lin_ref - c->dref_ema) / k : 0.0;
        for (size_t i = 0; i < (size_t)SK_W * SK_H; i++) {
            double d = (den64[i] - 16384.0) * (double)c->gain[i];
            c->temp[i] = c->t_dev_c + (d - c->dref_ema) / k + off;
        }
    } else {
        for (size_t i = 0; i < (size_t)SK_W * SK_H; i++)
            c->temp[i] = sk_signal_to_celsius(&planck, &scene, den64[i]);
    }

    c->images++;
    c->n_fps++;
    double t = now();
    if (t - c->t_fps_start > 2.0) {
        c->fps = c->n_fps / (t - c->t_fps_start);
        c->t_fps_start = t;
        c->n_fps = 0;
    }

    if (dumpdir[0]) {
        char p[600];
        snprintf(p, sizeof(p), "%s/img_%04d.raw", dumpdir, c->frame_idx);
        FILE *f = fopen(p, "wb");
        if (f) { fwrite(raw, 1, SK_RAW_BYTES, f); fclose(f); }
        snprintf(p, sizeof(p), "%s/ff_%04d.raw", dumpdir, c->frame_idx);
        f = fopen(p, "wb");
        if (f) { fwrite(c->ff, 1, SK_RAW_BYTES, f); fclose(f); }
        c->frame_idx++;
    }

    if (c->cb) {
        skcap_frame_t fr = {
            .rgb = c->rgb, .temp = c->temp, .signal = c->roi,
            .lo = c->tm.lo, .hi = c->tm.hi,
            .mean_signal = sk_roi_mean(c->roi),
            .mean_d = c->mean_d,
            .fps = c->fps,
            .t_dev_c = c->t_dev_c,
            .frames = c->images, .ffs = c->ffs,
            .errors = c->errors, .resyncs = c->resyncs,
        };
        c->cb(c->user, &fr);
    }
}

static size_t find_magic(const uint8_t *b, size_t n) {
    if (n < (size_t)SK_RAW_BYTES) return (size_t)-1;
    size_t last = n - (size_t)SK_RAW_BYTES;
    for (size_t i = 0; i <= last; i += 2) {
        uint16_t w0 = (uint16_t)(b[i] | (b[i + 1] << 8));
        if (w0 != SK_FRAME_MAGIC) continue;
        uint16_t fid = (uint16_t)(b[i + 4] | (b[i + 5] << 8));
        /* 1/3/6/20 — наши; 4/7/8/9/14 — калибровочные кадры PRO (gain/
         * thermistor-кривая/flash), принимаем чтобы не сбивать синхрон */
        if (fid <= 14 || fid == 20) return i;
    }
    return (size_t)-1;
}

static void LIBUSB_CALL chunk_cb(struct libusb_transfer *t) {
    skcap_t *c = (skcap_t *)t->user_data;
    c->chunk_inflight = 0;
    if (t->status == LIBUSB_TRANSFER_COMPLETED && t->actual_length > 0) {
        c->err_streak = 0;
        /* только буферизация + submit: control-трансферы из callback на
         * darwin вешают pipe (LIBUSB_ERROR_BUSY) */
        if (c->fill + (size_t)t->actual_length > 2 * (size_t)SK_RAW_BYTES) {
            size_t drop = c->fill / 2;
            drop &= ~(size_t)1;
            memmove(c->asm_buf, c->asm_buf + drop, c->fill - drop);
            c->fill -= drop;
            c->resyncs++;
        }
        memcpy(c->asm_buf + c->fill, t->buffer, (size_t)t->actual_length);
        c->fill += (size_t)t->actual_length;
        c->req_bytes += (size_t)t->actual_length;
        if (!c->quit) submit_chunk(c);
    } else if (t->status == LIBUSB_TRANSFER_CANCELLED) {
        /* K1: на Windows таймаут бэкенда отменяет URB через AbortPipe, и
         * CANCELLED приходит НЕ только при закрытии. Молча глушить его —
         * гарантированный стоп конвейера. Считаем сбоем, если не quit. */
        if (!c->quit) {
            c->fill = 0;
            c->req_bytes = 0;
            c->need_request = 1;
        }
    } else {
        c->errors++;
        if (!c->quit) {
            if (t->status == LIBUSB_TRANSFER_NO_DEVICE ||
                t->status == LIBUSB_TRANSFER_ERROR) {
                c->need_request = -1; /* рабочий поток переподключится */
                c->err_streak++;
            } else {
                libusb_clear_halt(c->h, EP_IN);
                c->fill = 0;
                c->req_bytes = 0;
                c->need_request = 1; /* pump сделает request + submit */
                c->err_streak++;
            }
            /* K4: эскалация — >5 подряд неудач без успешных данных → reconnect
             * (WinUSB возвращает ERROR_GEN_FAILURE→STALL и при общих сбоях
             * стека, а не только при реальном halt пайпа) */
            if (c->err_streak > 5) {
                c->need_request = -1;
                c->err_streak = 0;
            }
        }
    }
}

static void pump(skcap_t *c) {
    while (c->fill >= (size_t)SK_RAW_BYTES) {
        size_t p = find_magic(c->asm_buf, c->fill);
        if (p == (size_t)-1) {
            size_t drop = c->fill - SK_BULK_CHUNK;
            drop &= ~(size_t)1;
            memmove(c->asm_buf, c->asm_buf + drop, c->fill - drop);
            c->fill -= drop;
            c->resyncs++;
            break;
        }
        process_frame(c, (uint16_t *)(c->asm_buf + p));
        size_t used = p + SK_RAW_BYTES;
        memmove(c->asm_buf, c->asm_buf + used, c->fill - used);
        c->fill -= used;
    }
    if (c->need_request == 1 || c->req_bytes >= (size_t)SK_RAW_BYTES) {
        if (request_frame(c) == 0) {
            c->need_request = 0;
            c->req_bytes = 0;
        } else {
            c->errors++;
        }
    }
    /* единственный URB в полёте: после request (или сбоя) гарантированно
     * держим конвейер живым */
    if (!c->chunk_inflight && !c->need_request && c->connected)
        submit_chunk(c);
}

static void submit_chunk(skcap_t *c) {
    if (c->quit || !c->h) return;
    struct libusb_transfer *t = libusb_alloc_transfer(0);
    unsigned char *b = (unsigned char *)malloc(SK_BULK_CHUNK);
    if (!t || !b) {
        c->errors++;
        free(b);
        if (t) libusb_free_transfer(t);
        return;
    }
    libusb_fill_bulk_transfer(t, c->h, EP_IN, b, SK_BULK_CHUNK, chunk_cb, c,
                              1000);
    t->flags = LIBUSB_TRANSFER_FREE_BUFFER | LIBUSB_TRANSFER_FREE_TRANSFER;
    if (libusb_submit_transfer(t) < 0) {
        c->errors++;
        free(b);
        libusb_free_transfer(t);
    } else {
        c->chunk_inflight = 1;
    }
}

static int init_cam(skcap_t *c) {
    libusb_set_configuration(c->h, 1);
    if (libusb_claim_interface(c->h, 0) < 0) return -1;
    unsigned char tmp[4096];
    for (int i = 0; i < 8; i++)
        libusb_bulk_transfer(c->h, EP_IN, tmp, sizeof(tmp), NULL, 100);

    uint8_t one = 1;
    cmd_out(c, CMD_TARGET_PLATFORM, &one, 1);
    uint8_t z2[2] = {0, 0};
    cmd_out(c, CMD_SET_OPERATION_MODE, z2, 2);
    uint8_t fw[4], chip[12], b64[64];
    cmd_in(c, CMD_GET_FIRMWARE_INFO, fw, 4);
    cmd_in(c, CMD_READ_CHIP_ID, chip, 12);

    uint8_t fs6[6] = {6, 0, 8, 0, 0, 0};
    cmd_out(c, CMD_SET_FACTORY_SETTINGS_FEATURES, fs6, 6);
    uint8_t b12[12];
    cmd_in(c, CMD_GET_FACTORY_SETTINGS, b12, 12);
    uint8_t f2[2] = {0x17, 0};
    cmd_out(c, CMD_SET_FIRMWARE_INFO_FEATURES, f2, 2);
    cmd_in(c, CMD_GET_FIRMWARE_INFO, b64, 64);
    uint8_t f1a[6] = {1, 0, 0, 6, 0, 0};
    cmd_out(c, CMD_SET_FACTORY_SETTINGS_FEATURES, f1a, 6);
    cmd_in(c, CMD_GET_FACTORY_SETTINGS, b64, 2);
    uint8_t f1b[6] = {1, 0, 1, 6, 0, 0};
    cmd_out(c, CMD_SET_FACTORY_SETTINGS_FEATURES, f1b, 6);
    cmd_in(c, CMD_GET_FACTORY_SETTINGS, b64, 2);
    for (int addr = 0; addr < 2560; addr += 32) {
        uint8_t fa[6] = {0x20, 0, (uint8_t)(addr & 0xFF),
                        (uint8_t)(addr >> 8), 0, 0};
        cmd_out(c, CMD_SET_FACTORY_SETTINGS_FEATURES, fa, 6);
        cmd_in(c, CMD_GET_FACTORY_SETTINGS, b64, 64);
    }
    uint8_t f15[2] = {0x15, 0};
    cmd_out(c, CMD_SET_FIRMWARE_INFO_FEATURES, f15, 2);
    cmd_in(c, CMD_GET_FIRMWARE_INFO, b64, 64);
    uint8_t im[2] = {8, 0};
    cmd_out(c, CMD_SET_IMAGE_PROCESSING_MODE, im, 2);
    uint8_t s1[2] = {1, 0};
    cmd_out(c, CMD_SET_OPERATION_MODE, s1, 2);
    return 0;
}

static void close_cam(skcap_t *c) {
    if (!c->h) return; /* K7: guard — слать 60[00 00] только на живом handle */
    uint8_t z2[2] = {0, 0};
    for (int i = 0; i < 3; i++) cmd_out(c, CMD_SET_OPERATION_MODE, z2, 2);
    libusb_release_interface(c->h, 0);
}

static void *worker(void *arg) {
    skcap_t *c = (skcap_t *)arg;
    while (!c->quit) {
        if (!c->h) {
            c->h = libusb_open_device_with_vid_pid(c->ctx, VID, PID);
            if (!c->h) {
                c->connected = 0;
                struct timespec ts = {1, 0};
                nanosleep(&ts, NULL);
                continue;
            }
            /* на Windows всегда NOT_SUPPORTED — безвредно (K8) */
            (void)libusb_detach_kernel_driver(c->h, 0);
            if (init_cam(c) < 0) {
                libusb_close(c->h);
                c->h = NULL;
                struct timespec ts = {1, 0};
                nanosleep(&ts, NULL);
                continue;
            }
            c->connected = 1;
            c->fill = 0;
            c->req_bytes = 0;
            c->need_request = 0;
            sk_denoise_reset(&c->den);
            c->dref_ema = -1e30; /* AUD-R2: new session = new anchor */
            if (request_frame(c) == 0) submit_chunk(c);
        }
        struct timeval tv = {0, 20 * 1000};
        int r = libusb_handle_events_timeout_completed(c->ctx, &tv, NULL);
        if (r == LIBUSB_SUCCESS) pump(c);
        /* переподключение при гибели устройства/handle */
        if (c->need_request == -1 || r < 0) {
            close_cam(c);
            libusb_close(c->h);
            c->h = NULL;
            c->connected = 0;
            c->need_request = 0;
            c->fill = 0;
            c->req_bytes = 0;
            struct timespec ts = {1, 0};
            nanosleep(&ts, NULL);
        }
    }
    if (c->h) {
        for (int i = 0; i < 20; i++) {
            struct timeval tv = {0, 20 * 1000};
            libusb_handle_events_timeout_completed(c->ctx, &tv, NULL);
        }
        close_cam(c);
        libusb_close(c->h);
        c->h = NULL;
    }
    return NULL;
}

skcap_t *skcap_open(skcap_cb cb, void *user, const char *hotmap_path) {
    skcap_t *c = (skcap_t *)calloc(1, sizeof(skcap_t));
    if (c) c->dref_ema = -1e30; /* «не задано»: первая медиана D задаёт анкор */
    if (!c) return NULL;
    c->cb = cb;
    c->user = user;
    pthread_mutex_init(&c->mtx, NULL);
    c->pal = SK_PAL_IRONBOW;
    c->smooth = SK_SMOOTH_DEFAULT;
    c->motion = SK_MOTION_DEFAULT;
    c->spatial = SK_SPATIAL_DEFAULT;
    sk_scene_default(&c->scene);
    sk_planck_default(&c->planck);
    if (hotmap_path) {
        FILE *f = fopen(hotmap_path, "rb");
        if (f) {
            c->hot = (bool *)malloc((size_t)SK_W * SK_H);
            if (fread(c->hot, 1, (size_t)SK_W * SK_H, f) !=
                (size_t)SK_W * SK_H) {
                free(c->hot);
                c->hot = NULL;
            }
            fclose(f);
        }
    }
    c->asm_buf = (uint8_t *)malloc(2 * (size_t)SK_RAW_BYTES);
    sk_denoise_init(&c->den, c->smooth, c->motion, c->spatial);
    sk_tonemap_init(&c->tm, true);
    sk_palette_lut(c->pal, c->lut);
    c->t_fps_start = now();
    if (libusb_init(&c->ctx) < 0) {
        free(c->asm_buf);
        pthread_mutex_destroy(&c->mtx);
        free(c);
        return NULL;
    }
    if (pthread_create(&c->th, NULL, worker, c) != 0) {
        libusb_exit(c->ctx);
        free(c->asm_buf);
        pthread_mutex_destroy(&c->mtx);
        free(c);
        return NULL;
    }
    return c;
}

void skcap_close(skcap_t *c) {
    if (!c) return;
    c->quit = 1;
    pthread_join(c->th, NULL);
    sk_denoise_free(&c->den);
    free(c->asm_buf);
    free(c->hot);
    free(c->ff);
    free(c->gain);
    libusb_exit(c->ctx);
    pthread_mutex_destroy(&c->mtx);
    free(c);
}

void skcap_set_palette(skcap_t *c, sk_palette_t pal) {
    if (!c) return;
    pthread_mutex_lock(&c->mtx);
    c->pal = pal;
    sk_palette_lut(pal, c->lut);
    pthread_mutex_unlock(&c->mtx);
}

void skcap_set_denoise(skcap_t *c, float smooth, int motion, int spatial,
                       bool reset) {
    if (!c) return;
    pthread_mutex_lock(&c->mtx);
    c->smooth = smooth;
    c->motion = motion;
    c->spatial = spatial;
    /* рабочие копии den.* process_frame снимает под этим же локом в начале
     * кадра (AUD-R2); здесь обновляем исходные поля и целевой den */
    c->den.smooth = smooth;
    c->den.motion = motion;
    c->den.spatial = spatial;
    if (reset) c->den_reset = 1;
    pthread_mutex_unlock(&c->mtx);
}

void skcap_set_span_manual(skcap_t *c, bool on, double lo, double hi) {
    if (!c) return;
    pthread_mutex_lock(&c->mtx);
    c->span_manual = on;
    c->man_lo = lo;
    c->man_hi = hi;
    pthread_mutex_unlock(&c->mtx);
}

void skcap_set_scene(skcap_t *c, double eps, double t_refl_c, double t_atm_c,
                     double distance_m, double rel_humidity) {
    if (!c) return;
    pthread_mutex_lock(&c->mtx);
    c->scene.emissivity = eps;
    c->scene.t_refl_c = t_refl_c;
    c->scene.t_atm_c = t_atm_c;
    c->scene.distance_m = distance_m;
    c->scene.rel_humidity = rel_humidity;
    pthread_mutex_unlock(&c->mtx);
}

int skcap_planck_load(skcap_t *c, const char *path) {
    if (!c) return (int)SK_ERR_STATE;
    pthread_mutex_lock(&c->mtx);
    if (!path) {
        sk_planck_default(&c->planck);
        c->planck_set = false;
        pthread_mutex_unlock(&c->mtx);
        return 0;
    }
    sk_err_t e = sk_planck_load(&c->planck, path);
    c->planck_set = (e == SK_OK);
    pthread_mutex_unlock(&c->mtx);
    return (int)e;
}

/* Сохранить/загрузить фит ЛИНЕЙНОЙ модели (lin_k/off/ref) в текстовый файл. */
sk_err_t skcap_linear_save(skcap_t *c, const char *path) {
    if (!c || !path) return SK_ERR_STATE;
    pthread_mutex_lock(&c->mtx);
    double k = c->lin_k, off = c->lin_off, ref = c->lin_ref;
    pthread_mutex_unlock(&c->mtx);
    if (k <= 0.0) return SK_ERR_STATE;
    FILE *f = fopen(path, "wb");
    if (!f) return SK_ERR_IO;
    fprintf(f, "# SeekIR линейная калибровка (2 опорных тела, gain-путь)\n");
    fprintf(f, "lin_k = %.10g\nlin_off = %.10g\nlin_ref = %.10g\n", k, off, ref);
    fclose(f);
    return SK_OK;
}

bool skcap_linear_load(skcap_t *c, const char *path) {
    if (!c || !path) return false;
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    double k = 0, off = 0, ref = 0; int got = 0;
    char line[128];
    while (fgets(line, sizeof line, f)) {
        char k2[32]; double v;
        if (sscanf(line, " %31[a-zA-Z_] = %lg", k2, &v) == 2) {
            if (!strcmp(k2, "lin_k")) { k = v; got |= 1; }
            else if (!strcmp(k2, "lin_off")) { off = v; got |= 2; }
            else if (!strcmp(k2, "lin_ref")) { ref = v; got |= 4; }
        }
    }
    fclose(f);
    if (got != 7 || k < 5.0 || k > 600.0) return false;
    pthread_mutex_lock(&c->mtx);
    c->lin_k = k; c->lin_off = off; c->lin_ref = ref;
    pthread_mutex_unlock(&c->mtx);
    return true;
}

bool skcap_linear_fit(skcap_t *c, double tc1, double t1, double tc2, double t2) {
    /* tc1,tc2 — измеренные камерой °C центра на телах (по текущей модели);
     * t1,t2 — контактные °C. Ядро переводит tc в D через текущие k/off
     * (D = dref + (tc - t_dev - off)*k) и решает новую прямую. */
    if (!c) return false;
    if (!(fabs(t2 - t1) > 0.5) || !(fabs(tc2 - tc1) > 0.25)) return false;
    pthread_mutex_lock(&c->mtx);
    double k0 = (c->lin_k > 0.0) ? c->lin_k : 58.6;
    double off0 = (c->lin_k > 0.0)
        ? c->lin_off + (c->lin_ref - c->dref_ema) / c->lin_k : 0.0;
    double d1 = c->dref_ema + (tc1 - c->t_dev_c - off0) * k0;
    double d2 = c->dref_ema + (tc2 - c->t_dev_c - off0) * k0;
    double k = (d2 - d1) / (t2 - t1);
    if (k < 5.0 || k > 600.0) { pthread_mutex_unlock(&c->mtx); return false; }
    double off = (t1 - c->t_dev_c) - (d1 - c->dref_ema) / k;
    double ref = c->dref_ema;
    c->lin_k = k; c->lin_off = off; c->lin_ref = ref;
    pthread_mutex_unlock(&c->mtx);
    return true;
}

bool skcap_planck_fit(skcap_t *c, double s1, double c1, double s2, double c2) {
    if (!c) return false;
    pthread_mutex_lock(&c->mtx);
    sk_planck_t out;
    bool ok = sk_planck_fit2(&c->planck, s1, c1, s2, c2, &out);
    if (ok) {
        c->planck = out;
        c->planck_set = true;
    }
    pthread_mutex_unlock(&c->mtx);
    return ok;
}

sk_err_t skcap_planck_save(skcap_t *c, const char *path) {
    if (!c) return SK_ERR_STATE;
    pthread_mutex_lock(&c->mtx);
    sk_planck_t p = c->planck;
    pthread_mutex_unlock(&c->mtx);
    FILE *f = fopen(path, "wb");
    if (!f) return SK_ERR_IO;
    fprintf(f, "# SeekIR планк-калибровка (fit по 2 чёрным телам)\n");
    fprintf(f, "planck_r1 = %.10g\n", p.r1);
    fprintf(f, "planck_b = %.10g\n", p.b);
    fprintf(f, "planck_f = %.10g\n", p.f);
    fprintf(f, "planck_o = %.10g\n", p.o);
    fprintf(f, "planck_r2 = %.10g\n", p.r2);
    fclose(f);
    return SK_OK;
}

void skcap_planck_get(skcap_t *c, sk_planck_t *out) {
    if (!c || !out) return;
    pthread_mutex_lock(&c->mtx);
    *out = c->planck;
    pthread_mutex_unlock(&c->mtx);
}

void skcap_dump_dir(skcap_t *c, const char *dir) {
    if (!c) return;
    pthread_mutex_lock(&c->mtx);
    if (dir) {
        snprintf(c->dumpdir, sizeof(c->dumpdir), "%s", dir);
#ifdef _WIN32
        mkdir(c->dumpdir);
#else
        mkdir(c->dumpdir, 0755);
#endif
    } else {
        c->dumpdir[0] = 0;
    }
    pthread_mutex_unlock(&c->mtx);
}

void skcap_set_ff_cb(skcap_t *c, skcap_cb cb, void *user) {
    if (!c) return;
    pthread_mutex_lock(&c->mtx); /* AUD-R2: writes happen mid-stream */
    c->ff_cb = cb;
    c->ff_user = user;
    pthread_mutex_unlock(&c->mtx);
}

void skcap_stats(skcap_t *c, long *frames, long *ffs, long *errors,
                 long *resyncs, int *connected) {
    if (!c) return;
    if (frames) *frames = c->images;
    if (ffs) *ffs = c->ffs;
    if (errors) *errors = c->errors;
    if (resyncs) *resyncs = c->resyncs;
    if (connected) *connected = c->connected;
}

void skcap_fid_hist(skcap_t *c, long *out64) {
    if (!c || !out64) return;
    for (int i = 0; i < 64; i++) out64[i] = c->fid_hist[i];
}

/* Путь кэша gain-карты ID4. Если файл существует и валиден по размеру —
 * карта загружается немедленно (камера шлёт ID4 только при подаче питания).
 * При приёме свежей карты она перезаписывается (см. process_frame). */
void skcap_gain_path(skcap_t *c, const char *path) {
    if (!c) return;
    pthread_mutex_lock(&c->mtx);
    if (path) snprintf(c->gainpath, sizeof(c->gainpath), "%s", path);
    else c->gainpath[0] = 0;
    pthread_mutex_unlock(&c->mtx);
    if (!path) return;
    pthread_mutex_lock(&c->mtx); /* AUD-R2: race with process_frame (ID4) */
    if (!c->gain) c->gain = (float *)malloc(sizeof(float) * SK_W * SK_H);
    pthread_mutex_unlock(&c->mtx);
    if (!c->gain) return;
    FILE *f = fopen(path, "rb");
    if (f) {
        size_t n = fread(c->gain, sizeof(float), (size_t)SK_W * SK_H, f);
        fclose(f);
        if (n == (size_t)SK_W * SK_H) {
            int ok = 1;
            for (int i = 0; i < SK_W * SK_H; i++) {
                float g = c->gain[i];
                if (!(g > 0.1f && g < 10.0f)) { ok = 0; break; }
            }
            if (ok) c->gain_ready = 1;
        }
    }
}
