using System.IO;
using System.Text.Json;

namespace SeekIRWin.Core;

/// <summary>Снимок по ТЗ FW1/F6: raw-сигнал u16 (ре-радиометрия без камеры
/// возможна), визуализация, метаданные цепочки. Каталог:
/// %APPDATA%\SeekIRWin\gallery\IR_yyyyMMdd_HHmmss\{signal.r16, vis.png, meta.json}</summary>
public sealed class SnapshotMeta
{
    public string Timestamp { get; set; } = "";
    public int W { get; set; } = SeekConst.W;
    public int H { get; set; } = SeekConst.H;
    public string Palette { get; set; } = "";
    public double SpanLo { get; set; }
    public double SpanHi { get; set; }
    public bool SpanAuto { get; set; } = true;
    public double Fps { get; set; }
    public double CenterCelsius { get; set; }
    public double MeanSignal { get; set; }
    // F9 baseline/текущие
    public float Smooth { get; set; } = SeekConst.Smooth;
    public int Motion { get; set; } = SeekConst.Motion;
    public int Spatial { get; set; } = SeekConst.Spatial;
    // условия съёмки (сцены)
    public double Emissivity { get; set; } = 0.95;
    public double TReflC { get; set; } = 20;
    public double TAtmC { get; set; } = 20;
    public double DistanceM { get; set; } = 1;
    public double RelHumidity { get; set; } = 50;
    public string Hotmap { get; set; } = "";
    public string App { get; set; } = "SeekIRWin 0.1";
}

public static class Gallery
{
    public static string Root => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "SeekIRWin", "gallery");

    public static string CreateDir(string name)
    {
        string p = Path.Combine(Root, name);
        Directory.CreateDirectory(p);
        return p;
    }

    public static IEnumerable<string> Enumerate()
    {
        if (!Directory.Exists(Root)) return [];
        return Directory.EnumerateDirectories(Root)
                        .Where(d => File.Exists(Path.Combine(d, "meta.json")))
                        .OrderByDescending(d => d);
    }

    /// <summary>signal — ROI-сигнал u16 (FF-скорр., ре-радиометрия),
    /// visPng — готовый PNG-код визуализации (энкодит UI-слой).</summary>
    public static string Save(string dirName, ushort[] signal, byte[] visPng, SnapshotMeta meta)
    {
        string dir = CreateDir(dirName);
        var bs = new byte[signal.Length * 2];
        Buffer.BlockCopy(signal, 0, bs, 0, bs.Length);
        File.WriteAllBytes(Path.Combine(dir, "signal.r16"), bs);
        File.WriteAllBytes(Path.Combine(dir, "vis.png"), visPng);
        File.WriteAllText(Path.Combine(dir, "meta.json"),
            JsonSerializer.Serialize(meta, new JsonSerializerOptions { WriteIndented = true }));
        return dir;
    }

    public static (ushort[] signal, SnapshotMeta meta)? Load(string dir)
    {
        string sp = Path.Combine(dir, "signal.r16"), mp = Path.Combine(dir, "meta.json");
        if (!File.Exists(sp) || !File.Exists(mp)) return null;
        byte[] bs = File.ReadAllBytes(sp);
        var sig = new ushort[bs.Length / 2];
        Buffer.BlockCopy(bs, 0, sig, 0, bs.Length);
        return (sig, JsonSerializer.Deserialize<SnapshotMeta>(File.ReadAllText(mp))!);
    }
}
