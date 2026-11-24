using System;
using System.IO;
using SeekIRWin.Core;

namespace corecheck;

/// <summary>Лёгкий самодостаточный тест-раннер чистого слоя Core (без внешних пакетов).
/// Прогоняет проверки Radiometry / HotmapBuilder / Gallery и выходит с кодом 1 при провале.</summary>
public static class Program
{
    private static int _fail;

    private static void Check(bool cond, string what)
    {
        Console.WriteLine((cond ? "PASS  " : "FAIL  ") + what);
        if (!cond) _fail++;
    }

    private static void CheckClose(double a, double b, double tol, string what)
    {
        bool ok = Math.Abs(a - b) <= tol;
        Console.WriteLine((ok ? "PASS  " : "FAIL  ") + $"{what}  ({a:R} vs {b:R}, tol {tol})");
        if (!ok) _fail++;
    }

    public static int Main()
    {
        TestRadiometry();
        TestHotmap();
        TestGallery();

        Console.WriteLine();
        Console.WriteLine(_fail == 0 ? "ALL PASS" : $"{_fail} FAILURE(S)");
        return _fail == 0 ? 0 : 1;
    }

    private static void TestRadiometry()
    {
        var r = new Radiometry();
        Check(double.IsNaN(r.ToCelsius(1000)), "Radiometry: без планка -> NaN");
        Check(!r.Ready, "Radiometry: Ready=false до SetPlanck");

        r.SetPlanck(new SkPlanck { R1 = 15000, B = 1500, F = 1, O = -100, R2 = 1 });
        r.SetScene(0.95, 20, 20, 1, 50);
        Check(r.Ready, "Radiometry: Ready=true после SetPlanck");

        // обратная цепочка: FromCelsius -> ToCelsius должна возвращать исходную температуру
        for (double c = 0; c <= 80; c += 10)
        {
            double sig = r.FromCelsius(c);
            double back = r.ToCelsius(sig);
            CheckClose(back, c, 0.01, $"Radiometry: round-trip {c:F0} °C");
        }
    }

    private static void TestHotmap()
    {
        const int N = 30;
        var hb = new HotmapBuilder(N);
        var frames = new ushort[N][];
        for (int f = 0; f < N; f++)
        {
            var a = new ushort[SeekConst.W * SeekConst.H];
            a[100 * SeekConst.W + 100] = (ushort)(f % 2 == 0 ? 0 : 1000); // один шумный пиксель
            frames[f] = a;
        }
        foreach (var a in frames) hb.AddFf(a);

        Check(hb.IsDone, "Hotmap: завершён на TargetFf");
        var mask = hb.Mask!;
        int hot = 0;
        foreach (var m in mask) hot += m;
        Check(mask[100 * SeekConst.W + 100] == 1, "Hotmap: шумный пиксель помечен");
        Check(hot == 1, $"Hotmap: ровно 1 горячий пиксель (факт {hot})");
    }

    private static void TestGallery()
    {
        int n = SeekConst.W * SeekConst.H;
        var sig = new ushort[n];
        for (int i = 0; i < n; i++) sig[i] = (ushort)(i % 65536);
        var meta = new SnapshotMeta
        {
            Timestamp = "2026-11-24 12:00:00",
            Palette = "ironbow",
            SpanLo = 100, SpanHi = 60000,
            Emissivity = 0.95, TReflC = 20, TAtmC = 20, DistanceM = 1, RelHumidity = 50,
        };
        string name = "corecheck_tmp_" + Guid.NewGuid().ToString("N");
        var dir = Gallery.Save(name, sig, new byte[] { 1, 2, 3, 4 }, meta);
        try
        {
            var loaded = Gallery.Load(dir);
            Check(loaded is not null, "Gallery: Load вернул снимок");
            if (loaded is not null)
            {
                var (lsig, lmeta) = loaded.Value;
                bool same = lsig.Length == sig.Length;
                for (int i = 0; same && i < sig.Length; i++) if (lsig[i] != sig[i]) same = false;
                Check(same, "Gallery: signal.r16 round-trip");
                Check(lmeta.Palette == "ironbow" && lmeta.SpanHi == 60000, "Gallery: meta round-trip");
            }
        }
        finally { try { Directory.Delete(dir, recursive: true); } catch { } }
    }
}
