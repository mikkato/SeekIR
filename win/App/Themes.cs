using System.Windows;

namespace SeekIRWin.App;

/// <summary>Плоская тема: токены цветом, живое переключение light/dark/system.
/// Никаких теней/градиентов/скруглений — только цвета и 1px границы.</summary>
public static class Themes
{
    public enum Mode { Light, Dark, System }

    private static readonly Dictionary<string, (string L, string D)> Tok = new()
    {
        ["Bg"]        = ("#FFFFFF", "#17181A"),
        ["Panel"]     = ("#F4F4F4", "#1F2124"),
        ["Fg"]        = ("#1A1A1A", "#E6E6E6"),
        ["FgDim"]     = ("#6A6A6A", "#9A9A9A"),
        ["Border"]    = ("#C8C8C8", "#3A3D40"),
        ["Accent"]    = ("#0067C0", "#4CC2FF"),
        ["BtnBg"]     = ("#E8E8E8", "#2A2D31"),
        ["BtnHover"]  = ("#D8D8D8", "#34383D"),
        ["StatusBg"]  = ("#F4F4F4", "#1B1D1F"),
    };

    public static void Apply(Mode m)
    {
        bool dark = m == Mode.Dark ||
                    (m == Mode.System && IsSystemDark());
        var res = Application.Current.Resources;
        foreach (var (k, v) in Tok)
            res["C" + k + "Brush"] = new System.Windows.Media.SolidColorBrush(
                (System.Windows.Media.Color)
                System.Windows.Media.ColorConverter.ConvertFromString(dark ? v.D : v.L));
    }

    private static bool IsSystemDark()
    {
        using var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
    }
}
