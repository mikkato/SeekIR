using System.IO;

namespace SeekIRWin.App;

/// <summary>Минимальное логирование в %APPDATA%\SeekIRWin\error.log.
/// Никогда не бросает исключений.</summary>
public static class Diag
{
    public static void Log(string msg)
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SeekIRWin");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "error.log"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {msg}\n");
        }
        catch { /* логирование не должно ронять */ }
    }
}
