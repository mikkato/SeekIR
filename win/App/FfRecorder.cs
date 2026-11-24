using System.Diagnostics;
using System.Collections.Concurrent;
using System.IO;
using System.Threading;

namespace SeekIRWin.App;

/// <summary>Запись видеопотока через pipe в ffmpeg (bundled-бинарник — см. лицензию).
/// На входе — нативные RGB888 320x240; ffmpeg поворачивает (transpose=2,
/// 90° против ч.с., как на экране), апскейлит x4 nearest и кодирует H.264 yuv420p.
/// Запись не должна блокировать поток кадров: Write() только кладёт в очередь,
/// отдельный поток пишет в stdin.</summary>
public sealed class FfRecorder : IDisposable
{
    private readonly BlockingCollection<(byte[] Rgb, ushort[]? Sig)> _q = new(120); // ~20 c буфер
    private Process? _ff;
    private Stream? _stdin;
    private Thread? _writer;
    private string _path = "";
    private BinaryWriter? _raw; // FW2 sidecar: сырой 16-битный сигнал, тот же порядок кадров
    private long _frames;
    private volatile bool _done;       // Write() после Stop/Dispose не трогаем
    private volatile bool _ffExited;   // кэш факта смерти ffmpeg (без HasExited на каждый кадр)

    public bool IsRunning => !_done && !_ffExited && _ff is not null;
    public long Frames => Interlocked.Read(ref _frames);

    /// <summary>sidecarPath — необязательный .sig16 (LE ushort по кадрам, 320x240).</summary>
    public bool Start(string outPath, double fps, string exeDir, string? sidecarPath = null)
    {
        if (IsRunning) return false;
        string ff = Path.Combine(exeDir, "ffmpeg.exe");
        if (!File.Exists(ff)) ff = Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
        if (!File.Exists(ff)) return false;
        _path = outPath;
        _ffExited = false;
        int fr = Math.Clamp((int)Math.Round(fps <= 0 ? 7 : fps), 1, 30);
        _ff = new Process
        {
            EnableRaisingEvents = true,
            StartInfo = new ProcessStartInfo
            {
                FileName = ff,
                Arguments =
                    $"-hide_banner -loglevel error -y " +
                    $"-f rawvideo -pix_fmt rgb24 -s 320x240 -framerate {fr} -i pipe: " +
                    $"-vf \"transpose=2,scale=iw*4:ih*4:flags=neighbor\" " +
                    $"-c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p " +
                    $"-movflags +faststart \"{outPath}\"",
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            },
        };
        _ff.Exited += (_, _) => _ffExited = true;
        try { _ff.Start(); } catch (Exception ex) { Diag.Log("ffmpeg не стартовал: " + ex.Message); Dispose(); return false; }
        if (sidecarPath is not null)
        {
            try { _raw = new BinaryWriter(File.Create(sidecarPath)); }
            catch (Exception ex) { Diag.Log("sidecar не создан: " + ex.Message); _raw = null; }
        }
        _stdin = _ff.StandardInput.BaseStream;
        _ = _ff.StandardError.ReadToEndAsync(); // drain, не блокировать stderr
        _writer = new Thread(Pump) { IsBackground = true, Name = "ffrec" };
        _writer.Start();
        return true;
    }

    /// <summary>Вызывается из потока кадров. Копия RGB888 (+signal, если sidecar)
    /// в очередь; переполнение — сброс кадра.</summary>
    public void Write(byte[] rgb888, ushort[]? signal = null)
    {
        if (_done) return;
        try
        {
            if (!IsRunning) return;
            var copy = new byte[rgb888.Length];
            Buffer.BlockCopy(rgb888, 0, copy, 0, rgb888.Length);
            if (!_q.TryAdd((copy, _raw is null ? null : signal), 50)) return;
        }
        catch { /* остановка в этот момент — кадр просто теряется */ }
    }

    private void Pump()
    {
        try
        {
            foreach (var (rgb, sig) in _q.GetConsumingEnumerable())
            {
                _stdin!.Write(rgb, 0, rgb.Length);
                if (sig is not null && _raw is not null)
                {
                    // sidecar: один буфер на весь кадр, а не 76 800 записей по 2 байта
                    var buf = new byte[sig.Length * 2];
                    Buffer.BlockCopy(sig, 0, buf, 0, buf.Length); // LE (x86/ARM64)
                    _raw.Write(buf);
                }
                Interlocked.Increment(ref _frames);
            }
        }
        catch (IOException) { /* ffmpeg умер — молча выходим, Stop() зафиксирует */ }
        catch (ObjectDisposedException) { /* Dispose во время чтения очереди — норм. выход */ }
        catch (InvalidOperationException) { /* коллекция завершена во время перебора */ }
    }

    /// <summary>Остановка: закрываем stdin, ждём завершения кодирования (mp4 moov пишется в конце).</summary>
    public string Stop(int timeoutMs = 20000)
    {
        _done = true;
        if (_ff is null) return "";
        string path;
        try
        {
            _q.CompleteAdding();
            _writer?.Join(3000);
            _stdin?.Flush();
            _stdin?.Close();
            if (!_ff.WaitForExit(timeoutMs)) { try { _ff.Kill(entireProcessTree: true); } catch { } }
        }
        catch { }
        bool ok = _ff.HasExited && _ff.ExitCode == 0 && File.Exists(_path);
        path = ok ? _path : "";
        Dispose();
        return path;
    }

    public void Dispose()
    {
        _done = true;
        if (!_q.IsAddingCompleted) _q.CompleteAdding();
        // даём писателю выйти до освобождения коллекции — иначе ObjectDisposedException
        _writer?.Join(1000);
        try { if (_ff is { HasExited: false }) _ff.Kill(entireProcessTree: true); } catch { }
        _ff?.Dispose(); _ff = null; _stdin = null;
        try { _raw?.Flush(); _raw?.Dispose(); } catch { }
        _raw = null;
        _q.Dispose();
    }
}
