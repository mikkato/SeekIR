/* radiometric.c — FLIR-стиль Планк (ТЗ §3) поверх FF-скорр. сигнала.
 *
 *   L(T)   = r1 / (r2*(exp(b/T_K) - f)) - o
 *   tau    = exp(-sqrt(d) * (ata1 + atb1*sqrt(RH)))   (упрощ. INO/FLIR)
 *   R_obj  = R/(eps*tau) - ((1-eps)/eps)*L(T_refl)
 *            - ((1-tau)/(eps*tau))*L(T_atm)
 *   T_obj  = b / ln( r1/(r2*(R_obj+o)) + f ) - 273.15
 */
#include "seekcore.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ABS_ZERO 273.15
/* атмосферная модель FLIR (ata1/atb1 типовые для 7.5–13 мкм) */
#define ATA1 0.006569
#define ATB1 -0.002276

/* Дефолт — общесетевые CompactPRO-подобные значения (B ~ c2/lambda_eff,
 * lambda_eff ≈ 9.9 мкм). Финальные константы калибр-файла перекрывают
 * (sk_planck_load), точность подтверждается blackbody-этапом E1. */
static const sk_planck_t DEFAULT_PLANCK = {
    .r1 = 21106.77,
    .b = 1501.0,
    .f = 1.0,
    .o = -7340.0,
    .r2 = 0.012545258,
};

void sk_scene_default(sk_scene_t *s) {
    s->emissivity = 0.95;
    s->t_refl_c = 20.0;
    s->t_atm_c = 20.0;
    s->distance_m = 1.0;
    s->rel_humidity = 50.0;
}

double sk_atm_tau(double distance_m, double t_atm_c, double rel_humidity) {
    (void)t_atm_c;
    if (distance_m < 0) distance_m = 0;
    double rh = rel_humidity < 0 ? 0 : (rel_humidity > 100 ? 100 : rel_humidity);
    double alpha = ATA1 + ATB1 * sqrt(rh);
    return exp(-sqrt(distance_m) * alpha);
}

static double L_of_T(const sk_planck_t *p, double t_celsius) {
    double tk = t_celsius + ABS_ZERO;
    if (tk < 1.0) tk = 1.0;
    return p->r1 / (p->r2 * (exp(p->b / tk) - p->f)) - p->o;
}

double sk_signal_to_celsius(const sk_planck_t *p, const sk_scene_t *s,
                            double signal) {
    double eps = s->emissivity;
    if (eps < 0.01) eps = 0.01;
    if (eps > 1.0) eps = 1.0;
    double tau = sk_atm_tau(s->distance_m, s->t_atm_c, s->rel_humidity);
    if (tau < 0.05) tau = 0.05;
    double r_obj = signal / (eps * tau) - ((1.0 - eps) / eps) *
                                               L_of_T(p, s->t_refl_c) -
                       ((1.0 - tau) / (eps * tau)) * L_of_T(p, s->t_atm_c);
    double denom = p->r2 * (r_obj + p->o);
    if (denom <= 0.0) return -273.15; /* вне диапазона */
    double arg = p->r1 / denom + p->f;
    if (arg <= 1.0) return -273.15;
    return p->b / log(arg) - ABS_ZERO;
}

double sk_celsius_to_signal(const sk_planck_t *p, double celsius) {
    return L_of_T(p, celsius);
}

bool sk_planck_fit2(const sk_planck_t *base, double s1, double c1, double s2,
                    double c2, sk_planck_t *out) {
    /* единичная эмиссивность/без атмосферы: R = L(T) =>
     * k_i = exp(b/T_i)-f;  R_i+o = A/k_i, A=r1/r2
     * A = (R1-R2)/(1/k1-1/k2);  o = A/k1 - R1;  r2 = r1/A */
    double t1 = c1 + ABS_ZERO, t2 = c2 + ABS_ZERO;
    if (t1 < 1.0 || t2 < 1.0) return false;
    double k1 = exp(base->b / t1) - base->f;
    double k2 = exp(base->b / t2) - base->f;
    if (k1 <= 0 || k2 <= 0) return false;
    double dk = 1.0 / k1 - 1.0 / k2;
    if (fabs(dk) < 1e-15 || s1 == s2) return false;
    double A = (s1 - s2) / dk;
    if (A <= 0) return false;
    *out = *base;
    out->r2 = base->r1 / A;
    out->o = A / k1 - s1;
    return true;
}

sk_err_t sk_planck_load(sk_planck_t *p, const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) return SK_ERR_IO;
    char line[256];
    while (fgets(line, sizeof(line), fp)) {
        char *hash = strchr(line, '#');
        if (hash) *hash = 0;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char *key = line;
        while (*key == ' ' || *key == '\t') key++;
        char *end = eq - 1;
        while (end > key && (*end == ' ' || *end == '\t')) *end-- = 0;
        char *val = eq + 1;
        while (*val == ' ' || *val == '\t') val++;
        double v = strtod(val, NULL);
        if (!strcmp(key, "planck_r1")) p->r1 = v;
        else if (!strcmp(key, "planck_b")) p->b = v;
        else if (!strcmp(key, "planck_f")) p->f = v;
        else if (!strcmp(key, "planck_o")) p->o = v;
        else if (!strcmp(key, "planck_r2")) p->r2 = v;
    }
    fclose(fp);
    return SK_OK;
}

/* инициализация дефолтом при первом обращении (для seekproc через --calib) */
void sk_planck_default(sk_planck_t *p) { *p = DEFAULT_PLANCK; }
