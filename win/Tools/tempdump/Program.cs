// tempdump: writes the first N frames of SeekCam Frame.Temp (320x240 double)
// as raw f64 little-endian to <outdir>/temp.bin (concatenated) + meta.json.
// New standalone tool; does not touch any existing sources.
using System.Text.Json;
using SeekIRWin.Core;

int maxFrames = 120;
int seconds = 25;
string outDir = args.Length > 0 ? args[0]
    : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                   "hermes", "cache", "scratch", "seekdump");
Directory.CreateDirectory(outDir);

using var cam = new SeekCam();
if (!cam.Open(null))
{
    Console.Error.WriteLine("FATAL: cannot open device (SeekCam.Open failed)");
    return 2;
}
Console.WriteLine("device opened");

var binPath = Path.Combine(outDir, "temp.bin");
using var fs = new FileStream(binPath, FileMode.Create, FileAccess.Write);
var meta = new List<object>();
int count = 0;
using var done = new ManualResetEventSlim(false);

cam.FrameArrived += f =>
{
    if (count >= maxFrames) return;
    var bytes = new byte[f.Temp.Length * 8];
    Buffer.BlockCopy(f.Temp, 0, bytes, 0, bytes.Length);
    fs.Write(bytes, 0, bytes.Length);
    meta.Add(new { n = count, lo = f.Lo, hi = f.Hi, meanSignal = f.MeanSignal, fps = f.Fps,
                   frames = f.Frames, ffs = f.Ffs, errors = f.Errors, resyncs = f.Resyncs });
    count++;
    if (count % 10 == 0) Console.WriteLine($"frame {count}");
    if (count >= maxFrames) done.Set();
};

done.Wait(TimeSpan.FromSeconds(seconds));
Console.WriteLine($"captured {count} frames");
cam.Dispose();
fs.Flush(); fs.Dispose();
File.WriteAllText(Path.Combine(outDir, "meta.json"), JsonSerializer.Serialize(meta));
Console.WriteLine($"wrote {binPath}");
return count > 0 ? 0 : 3;
