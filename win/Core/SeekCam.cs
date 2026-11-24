using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;

namespace SeekIRWin.Core;

/// <summary>Потокобезопасная обёртка skcap_t: кадр копируется из нативного
/// буфера немедленно в колбэке (валиден только во время колбэка, AUD-03).
/// Делегат удерживается полем — сборщик не должен его собрать.</summary>
public sealed class SeekCam : IDisposable
{
    public sealed record Frame(
        byte[] Rgb, double[] Temp, ushort[] Signal,
        double Lo, double Hi, double MeanSignal, double Fps, double TDevC,
        int Frames, int Ffs, int Errors, int Resyncs);

    public event Action<Frame>? FrameArrived;

    private IntPtr _h;
    private SkcapCallback? _cb; // keep-alive
    private bool _disposed;

    public bool IsOpen => _h != IntPtr.Zero;

    public bool Open(string? hotmapPath = null)
    {
        if (_h != IntPtr.Zero) return true;
        _cb = OnNativeFrame;
        _h = Native.Open(_cb, IntPtr.Zero, Native.Utf8Z(hotmapPath));
        return _h != IntPtr.Zero;
    }

    private void OnNativeFrame(IntPtr user, IntPtr framePtr)
    {
        var f = Marshal.PtrToStructure<SkcapFrame>(framePtr);
        int px = SeekConst.W * SeekConst.H;
        var rgb = new byte[px * 3];
        var temp = new double[px];
        var sig = new ushort[px];
        Marshal.Copy(f.Rgb, rgb, 0, rgb.Length);
        Marshal.Copy(f.Temp, temp, 0, px);
        unsafe { fixed (ushort* d = sig) Buffer.MemoryCopy((void*)f.Signal, d, px * 2, px * 2); }
        FrameArrived?.Invoke(new Frame(rgb, temp, sig, f.Lo, f.Hi, f.MeanSignal, f.Fps, f.TDevC,
                                       f.Frames, f.Ffs, f.Errors, f.Resyncs));
    }

    public void SetPalette(int pal) => Native.SetPalette(_h, pal);
    public void SetDenoise(float smooth, int motion, int spatial, bool reset) =>
        Native.SetDenoise(_h, smooth, motion, spatial, reset);
    public void SetSpanManual(bool on, double lo, double hi) => Native.SetSpanManual(_h, on, lo, hi);
    public void SetScene(double eps, double tRefl, double tAtm, double dist, double rh) =>
        Native.SetScene(_h, eps, tRefl, tAtm, dist, rh);
    public int PlanckLoad(string? path) => Native.PlanckLoad(_h, Native.Utf8Z(path));
    public SkPlanck PlanckGet() { Native.PlanckGet(_h, out var p); return p; }
    public bool PlanckFit(double s1, double c1, double s2, double c2) =>
        Native.PlanckFit(_h, s1, c1, s2, c2);
    public int PlanckSave(string path) => Native.PlanckSave(_h, Native.Utf8Z(path));
    public void SetDumpDir(string? dir) => Native.DumpDir(_h, Native.Utf8Z(dir));

    /// <summary>Канал FF-кадров (для HotmapBuilder). null = выключить.
    /// ВАЖНО: в этом колбэке валидно только поле Signal (ROI FF), rgb/temp — нет.</summary>
    public void SetFfCallback(Action<ushort[]>? onFf)
    {
        if (onFf is null) { Native.SetFfCb(_h, null!, IntPtr.Zero); _ffKeep = null; return; }
        _ffKeep = (user, framePtr) =>
        {
            var f = Marshal.PtrToStructure<SkcapFrame>(framePtr);
            var sig = new ushort[SeekConst.W * SeekConst.H];
            unsafe { fixed (ushort* d = sig) Buffer.MemoryCopy((void*)f.Signal, d, sig.Length * 2, sig.Length * 2); }
            onFf(sig);
        };
        Native.SetFfCb(_h, _ffKeep, IntPtr.Zero);
    }
    private SkcapCallback? _ffKeep;
    public (int frames, int ffs, int errors, int resyncs, int connected) Stats()
    { Native.Stats(_h, out var a, out var b, out var c, out var d, out var e); return (a, b, c, d, e); }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_h != IntPtr.Zero) { Native.Close(_h); _h = IntPtr.Zero; }
    }
}
