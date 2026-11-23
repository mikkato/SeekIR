using System.Diagnostics;
using System.Collections.Concurrent;
using System.IO;
using System.Threading;

namespace SeekIRWin.App;

/// <summary>Запись видеопотока через pipe в ffmpeg (portable, LGPL).
/// На входе — нативные RGB888 320x240; ffmpeg поворачивает (transpose=2,
/// 90° против ч.с., как на экране), апскейлит x4 nearest и кодирует H.264 yuv420p.
/// Запись не должна блокировать поток кадров: Write() только кладёт в очередь,
/// отдельный поток пишет в stdin.</summary>
public sealed class FfRecorder : IDisposable
{
    private readonly BlockingCollection<byte[]> _q = new(120); // ~20 c буфер
    private Process? _ff;
    private Stream? _stdin;
    private Thread? _writer;
    private string _path = "";
    private long _frames;
    private volatile bool _done; // Write() после Stop/Dispose не трогаем

    public bool IsRunning => !_done && _ff is { HasExited: false };
    public long Frames => Interlocked.Read(ref _frames);

    public bool Start(string outPath, double fps, string exeDir)
    {
        if (IsRunning) return false;
        string ff = Path.Combine(exeDir, "ffmpeg.exe");
        if (!File.Exists(ff)) ff = Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
        if (!File.Exists(ff)) return false;
        _path = outPath;
        int fr = Math.Clamp((int)Math.Round(fps <= 0 ? 7 : fps), 1, 30);
        _ff = new Process
        {
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
        try { _ff.Start(); } catch { Dispose(); return false; }
        _stdin = _ff.StandardInput.BaseStream;
        _ = _ff.StandardError.ReadToEndAsync(); // drain, не блокировать stderr
        _writer = new Thread(Pump) { IsBackground = true, Name = "ffrec" };
        _writer.Start();
        return true;
    }

    /// <summary>Вызывается из потока кадров. Копия RGB888 в очередь; переполнение — сброс кадра.</summary>
    public void Write(byte[] rgb888)
    {
        if (_done) return;
        try
        {
            if (!IsRunning) return;
            var copy = new byte[rgb888.Length];
            Buffer.BlockCopy(rgb888, 0, copy, 0, rgb888.Length);
            if (!_q.TryAdd(copy, 50)) return;
        }
        catch { /* остановка в этот момент — кадр просто теряется */ }
    }

    private void Pump()
    {
        try
        {
            foreach (var f in _q.GetConsumingEnumerable())
            {
                _stdin!.Write(f, 0, f.Length);
                Interlocked.Increment(ref _frames);
            }
        }
        catch (IOException) { /* ffmpeg умер — молча выходим, Stop() зафиксирует */ }
    }

    /// <summary>Остановка: закрываем stdin, ждём завершения кодирования (mp4 moov пишется в конце).</summary>
    public string Stop(int timeoutMs = 20000)
    {
        _done = true;
        if (_ff is null) return "";
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
        string p = ok ? _path : "";
        Dispose();
        return p;
    }

    public void Dispose()
    {
        _done = true;
        try { if (_ff is { HasExited: false }) _ff.Kill(entireProcessTree: true); } catch { }
        _ff?.Dispose(); _ff = null; _stdin = null;
        _q.Dispose();
    }
}
