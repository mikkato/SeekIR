using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

// П/Invoke к seekcap.dll (mingw-w64, cdecl). ВАЖНО: long в C на Windows = 4 байта
// (не 8, как на macOS) — поля статистики объявлены int.
[assembly: DisableRuntimeMarshalling]

namespace SeekIRWin.Core;

[StructLayout(LayoutKind.Sequential)]
public struct SkcapFrame
{
    public IntPtr Rgb;        // SK_W*SK_H*3, валиден только во время колбэка
    public IntPtr Temp;       // double °C, SK_W*SK_H
    public IntPtr Signal;     // ushort FF-скорр. ROI-сигнал
    public double Lo, Hi;     // текущий span
    public double MeanSignal;
    public double Fps;
    public double TDevC;      // внутр. термистор FPA, °C
    public int Frames, Ffs, Errors, Resyncs; // C long на Win == int
}

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void SkcapCallback(IntPtr user, IntPtr frame /* SkcapFrame* */);

public static partial class Native
{
    private const string Lib = "seekcap.dll";

    [LibraryImport(Lib, EntryPoint = "skcap_open")]
    public static partial IntPtr Open(SkcapCallback cb, IntPtr user, byte[]? hotmapPathUtf8);

    [LibraryImport(Lib, EntryPoint = "skcap_close")]
    public static partial void Close(IntPtr c);

    [LibraryImport(Lib, EntryPoint = "skcap_set_palette")]
    public static partial void SetPalette(IntPtr c, int pal);

    [LibraryImport(Lib, EntryPoint = "skcap_set_denoise")]
    public static partial void SetDenoise(IntPtr c, float smooth, int motion, int spatial, [MarshalAs(UnmanagedType.I1)] bool reset);

    [LibraryImport(Lib, EntryPoint = "skcap_set_span_manual")]
    public static partial void SetSpanManual(IntPtr c, [MarshalAs(UnmanagedType.I1)] bool on, double lo, double hi);

    [LibraryImport(Lib, EntryPoint = "skcap_set_scene")]
    public static partial void SetScene(IntPtr c, double eps, double tReflC, double tAtmC, double distanceM, double relHumidity);

    [LibraryImport(Lib, EntryPoint = "skcap_planck_load")]
    public static partial int PlanckLoad(IntPtr c, byte[]? pathUtf8);

    [LibraryImport(Lib, EntryPoint = "skcap_planck_fit")]
    [return: MarshalAs(UnmanagedType.I1)]
    public static partial bool PlanckFit(IntPtr c, double s1, double c1, double s2, double c2);

    [LibraryImport(Lib, EntryPoint = "skcap_planck_save")]
    public static partial int PlanckSave(IntPtr c, byte[] pathUtf8);

    [LibraryImport(Lib, EntryPoint = "skcap_dump_dir")]
    public static partial void DumpDir(IntPtr c, byte[]? dirUtf8);

    [LibraryImport(Lib, EntryPoint = "skcap_set_ff_cb")]
    public static partial void SetFfCb(IntPtr c, SkcapCallback cb, IntPtr user);

    [LibraryImport(Lib, EntryPoint = "skcap_stats")]
    public static partial void Stats(IntPtr c, out int frames, out int ffs, out int errors, out int resyncs, out int connected);

    [LibraryImport(Lib, EntryPoint = "skcap_planck_get")]
    public static partial void PlanckGet(IntPtr c, out SkPlanck outPlanck);

    public static byte[]? Utf8Z(string? s) => s is null ? null : System.Text.Encoding.UTF8.GetBytes(s + "\0");
}

[StructLayout(LayoutKind.Sequential)]
public struct SkPlanck
{
    public double R1, B, F, O, R2;
}

[StructLayout(LayoutKind.Sequential)]
public struct SkScene
{
    public double Emissivity, TReflC, TAtmC, DistanceM, RelHumidity;
}

public static class SeekConst
{
    public const int W = 320, H = 240;
    public const string PaletteIronbow = "ironbow";
    // baseline F9 (утверждён): smooth 0.75 / motion 440 / spatial 75
    public const float Smooth = 0.75f; public const int Motion = 440, Spatial = 75;
}
