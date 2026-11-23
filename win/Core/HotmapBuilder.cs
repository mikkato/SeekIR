using System.IO;

namespace SeekIRWin.Core;

/// <summary>Карта шума по FF-кадрам — 1-в-1 алгоритм build_hotmap() из
/// tools/capture.py (проверен на железе, hotpixels.npy 0.65%).
/// Питание: Signal каждого FF-кадра (frame FF=true). Результат — raw u8 0/1
/// 320x240 (hot.bin ядра).</summary>
public sealed class HotmapBuilder
{
    public int TargetFf { get; }
    public int Collected { get; private set; }
    public bool IsDone { get; private set; }

    private readonly float[,,] _frames; // [n, 240, 320]
    private readonly double _floor;
    private readonly double _sigmaFactor;

    public HotmapBuilder(int targetFf = 60, double sigmaFactor = 3.0, double floor = 40.0)
    {
        TargetFf = Math.Clamp(targetFf, 10, 256);
        _frames = new float[TargetFf, SeekConst.H, SeekConst.W];
        _sigmaFactor = sigmaFactor;
        _floor = floor;
    }

    public void AddFf(ReadOnlySpan<ushort> signal)
    {
        if (IsDone) return;
        for (int i = 0; i < signal.Length; i++)
            _frames[Collected, i / SeekConst.W, i % SeekConst.W] = signal[i];
        if (++Collected >= TargetFf) Compute();
    }

    private void Compute()
    {
        int W = SeekConst.W, H = SeekConst.H, N = TargetFf;
        var sd = new double[W * H];
        var tmp = new double[N];
        for (int px = 0; px < W * H; px++)
        {
            int x = px % W, y = px / W;
            double sum = 0;
            for (int f = 0; f < N; f++) { tmp[f] = _frames[f, y, x]; sum += tmp[f]; }
            double mean = sum / N, v = 0;
            for (int f = 0; f < N; f++) { double d = tmp[f] - mean; v += d * d; }
            sd[px] = Math.Sqrt(v / N); // np.std ddof=0
        }
        // локальная медиана σ в окне 5x5 (edge-pad), порог max(3σ_med, floor)
        byte[] mask = new byte[W * H];
        var win = new double[25];
        double medAll = Median(sd);
        for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++)
        {
            int k = 0;
            for (int dy = -2; dy <= 2; dy++)
            for (int dx = -2; dx <= 2; dx++)
            {
                int yy = Math.Clamp(y + dy, 0, H - 1), xx = Math.Clamp(x + dx, 0, W - 1);
                win[k++] = sd[yy * W + xx];
            }
            Array.Sort(win);
            double thr = Math.Max(_sigmaFactor * win[12], _floor);
            mask[y * W + x] = sd[y * W + x] > thr ? (byte)1 : (byte)0;
        }
        Mask = mask; MedianSigma = medAll; HotCount = mask.Sum(b => (int)b);
        IsDone = true;
    }

    private static double Median(double[] a)
    {
        var c = (double[])a.Clone();
        Array.Sort(c);
        int n = c.Length;
        return n % 2 == 1 ? c[n / 2] : (c[n / 2 - 1] + c[n / 2]) / 2.0; // numpy-точность
    }

    public byte[]? Mask { get; private set; }
    public double MedianSigma { get; private set; }
    public int HotCount { get; private set; }

    public void Save(string path)
    {
        if (Mask is null) throw new InvalidOperationException("не собрано");
        string? dir = Path.GetDirectoryName(path);
        if (dir is not null) Directory.CreateDirectory(dir);
        File.WriteAllBytes(path, Mask);
    }

    public string Summary =>
        $"шумных {HotCount} ({100.0 * HotCount / (SeekConst.W * SeekConst.H):F2}%), медиана σ={MedianSigma:F0}";
}
