/* seekd — CLI-обёртка над seekcap (транспорт+цепочка в usb/seekcap.c).
 *
 *   seekd --secs 10                живой прогон: FPS, °C центра
 *   seekd --secs 12 --dump DIR     + золотые дампы img/ff_NNNN.raw
 *   seekd --hotmap hot.bin         замена шумных пикселей медианой 5x5
 * Завершение штатное (SIGTERM/SIGINT): 60[00 00] x3 — не kill -9.
 */
#include "seekcap.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

static volatile sig_atomic_t g_quit = 0;
static void on_sig(int s) { (void)s; g_quit = 1; }

#ifdef _WIN32
/* K2: на Windows SIGTERM не доставляется, а закрытие окна консоли убивает
 * процесс без штатных 60[00 00]x3. Handler ставит g_quit; для CTRL_CLOSE
 * даём конвейеру ~2,5 с на корректное закрытие (лимит системы ~5 с). */
static BOOL WINAPI ctrl_handler(DWORD type) {
    switch (type) {
    case CTRL_C_EVENT:
    case CTRL_BREAK_EVENT:
        g_quit = 1;
        return TRUE;
    case CTRL_CLOSE_EVENT:
        g_quit = 1;
        Sleep(2500);
        return TRUE;
    default:
        return FALSE;
    }
}
#endif

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static void on_frame(void *user, const skcap_frame_t *f) {
    (void)user;
    static double t_last = 0;
    double t = now();
    if (t - t_last > 2.0) {
        t_last = t;
        size_t mid = (size_t)SK_W * SK_H / 2;
        fprintf(stderr, "  %.1f к/с (img=%ld ff=%ld err=%ld resync=%ld) "
                        "span=%.1f..%.1f Tцентр=%.1fC\n",
                f->fps, f->frames, f->ffs, f->errors, f->resyncs, f->lo,
                f->hi, f->temp[mid]);
    }
}

int main(int argc, char **argv) {
    double t_end = 1e18;
    const char *dumpdir = NULL, *hotmap = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--secs") && i + 1 < argc)
            t_end = now() + atof(argv[++i]);
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc)
            dumpdir = argv[++i];
        else if (!strcmp(argv[i], "--hotmap") && i + 1 < argc)
            hotmap = argv[++i];
        else {
            fprintf(stderr,
                    "usage: seekd [--secs N] [--dump DIR] [--hotmap hot.bin]\n");
            return 2;
        }
    }
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8); /* K3: кириллица в stderr */
    SetConsoleCtrlHandler(ctrl_handler, TRUE);
#endif

    skcap_t *cap = skcap_open(on_frame, NULL, hotmap);
    if (!cap) { fprintf(stderr, "камера недоступна\n"); return 1; }
    if (dumpdir) skcap_dump_dir(cap, dumpdir);

    while (!g_quit && now() < t_end) {
        struct timespec ts = {0, 100 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
    long fr, ff, er, rs;
    int conn;
    skcap_stats(cap, &fr, &ff, &er, &rs, &conn);
    skcap_close(cap);
    fprintf(stderr, "[seekd] img=%ld ff=%ld errors=%ld resync=%ld\n", fr, ff,
            er, rs);
    return 0;
}
