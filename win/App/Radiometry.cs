using SeekIRWin.Core;

namespace SeekIRWin.App;

/// <summary>Радиометрия «обратно»: счёт-сигнал ↔ °C по тем же константам,
/// что C-ядро (core/src/radiometric.c, float64; экспоненты libm vs .NET
/// расходятся <1e-12 — для подписей шкалы/перетаскивания незначимо).
/// Коэффициенты Планка берутся из ядра (planck_get) после connect/фита.</summary>
public sealed class Radiometry
{
    private SkPlanck _p;
    private double _eps = 0.95, _tRefl = 20, _tAtm = 20, _dist = 1, _rh = 50;
    private bool _ready;

    public bool Ready => _ready;

    public void SetPlanck(SkPlanck p) { _p = p; _ready = true; }

    public void SetScene(double eps, double tRefl, double tAtm, double dist, double rh)
    { _eps = eps; _tRefl = tRefl; _tAtm = tAtm; _dist = dist; _rh = rh; }

    private double L(double c)
    {
        double tk = c + 273.15;
        if (tk < 1.0) tk = 1.0;
        return _p.R1 / (_p.R2 * (Math.Exp(_p.B / tk) - _p.F)) - _p.O;
    }

    public double ToCelsius(double signal)
    {
        if (!_ready) return double.NaN;
        double eps = Math.Clamp(_eps, 0.01, 1.0);
        double tau = Math.Max(0.05,
            Math.Exp(-Math.Sqrt(Math.Max(0, _dist)) * (0.006569 + -0.002276 * Math.Sqrt(Math.Clamp(_rh, 0, 100)))));
        double rObj = signal / (eps * tau)
                    - (1.0 - eps) / eps * L(_tRefl)
                    - (1.0 - tau) / (eps * tau) * L(_tAtm);
        double denom = _p.R2 * (rObj + _p.O);
        if (denom <= 0.0) return -273.15;
        double arg = _p.R1 / denom + _p.F;
        if (arg <= 1.0) return -273.15;
        return _p.B / Math.Log(arg) - 273.15;
    }

    /// <summary>°C -> счёт-сигнал (обратная цепочка сцены; для span/изотермы).</summary>
    public double FromCelsius(double c)
    {
        if (!_ready) return double.NaN;
        double eps = Math.Clamp(_eps, 0.01, 1.0);
        double tau = Math.Max(0.05,
            Math.Exp(-Math.Sqrt(Math.Max(0, _dist)) * (0.006569 + -0.002276 * Math.Sqrt(Math.Clamp(_rh, 0, 100)))));
        return eps * tau * (L(c) + (1.0 - eps) / eps * L(_tRefl)
                                + (1.0 - tau) / (eps * tau) * L(_tAtm));
    }
}
