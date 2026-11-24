/* seekcap.h — продуктовый API захвата CompactPRO (E2).
 *
 * Обёртка над асинхронным URB-конвейером seekd (E1, проверен на железе):
 * собственный поток крутит libusb-события, мягкий reconnect при разрыве,
 * каждый готовый кадр прогоняется через цепочку core/ и доставляется
 * колбэком. Все сеттеры потокобезопасны.
 *
 * ВАЖНО (darwin): control-трансферы только из рабочего потока (pump),
 * никогда из USB-callback — иначе LIBUSB_ERROR_BUSY (см. skill).
 */
#ifndef SEEKCAP_H
#define SEEKCAP_H

#include "seekcore.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct skcap skcap_t;

typedef struct {
    const uint8_t *rgb;     /* SK_W*SK_H*3, валиден во время колбэка   */
    const double  *temp;    /* °C, SK_W*SK_H                            */
    const uint16_t *signal; /* FF-скорр. ROI-сигнал, SK_W*SK_H          */
    double lo, hi;          /* текущий span (авто или ручной)           */
    double mean_signal;     /* средний сигнал ROI (для калибровки)      */
    double fps;             /* скользящее значение                      */
    double t_dev_c;         /* температура FPA по внутр. термистору (raw[5],
                             * бетта-модель B=200 ref=6616@297K, sfalexrog) */
    long frames, ffs, errors, resyncs;
} skcap_frame_t;

typedef void (*skcap_cb)(void *user, const skcap_frame_t *f);

/* Открыть камеру, запустить поток+обработку. hotmap_path — hot.bin
 * (320*240 u8 0/1) или NULL. Возвращает NULL при недоступности камеры
 * (поток тем не менее продолжит переподключаться, если open удалось). */
skcap_t *skcap_open(skcap_cb cb, void *user, const char *hotmap_path);
void skcap_close(skcap_t *c);

/* --- рантайм-настройки (из любого потока) --- */
void skcap_set_palette(skcap_t *c, sk_palette_t pal);
/* reset=true сбрасывает temporal-состояние (при смене параметров UI) */
void skcap_set_denoise(skcap_t *c, float smooth, int motion, int spatial,
                       bool reset);
void skcap_set_span_manual(skcap_t *c, bool on, double lo, double hi);
void skcap_set_scene(skcap_t *c, double eps, double t_refl_c, double t_atm_c,
                     double distance_m, double rel_humidity);

/* Планк-калибровка (F8 ТЗ): загрузка override-файла, фит по 2 чёрным телам,
 * сохранение. fit возвращает false на вырожденных точках (константы тогда
 * не меняются). */
int skcap_planck_load(skcap_t *c, const char *path); /* NULL = дефолт */
bool skcap_planck_fit(skcap_t *c, double s1, double c1, double s2, double c2);
sk_err_t skcap_planck_save(skcap_t *c, const char *path);
void skcap_planck_get(skcap_t *c, sk_planck_t *out);

/* Золотые дампы img/ff_NNNN.raw в dir (NULL = выключить). */
void skcap_dump_dir(skcap_t *c, const char *dir);

/* Дополнительный канал FF-кадров для построения карты шума: колбэк
 * вызывается из рабочего потока в момент прихода FF (signal = ROI FF u16,
 * rgb/temp не валидны). NULL = выключить. */
void skcap_set_ff_cb(skcap_t *c, skcap_cb cb, void *user);

/* Диагностика для UI. */
void skcap_stats(skcap_t *c, long *frames, long *ffs, long *errors,
                 long *resyncs, int *connected);

/* Гистограмма типов кадров (fid 0..63 -> счётчик). Буфер у вызывающего,
 * size=64. Для диагностики калибровочного потока камеры. */
void skcap_fid_hist(skcap_t *c, long *out64);

#ifdef __cplusplus
}
#endif
#endif /* SEEKCAP_H */
