using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace SeekIRWin.App;

/// <summary>Шапка окна (title bar) под тему: тёмный режим + цвет шапки/текста
/// через DWMWA_USE_IMMERSIVE_DARK_MODE / CAPTION_COLOR / TEXT_COLOR.</summary>
public static class WindowTheme
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

    private static int _color = 0x001A1A1A; // BGR светлая (bg #FFFFFF → шапка чуть темнее)

    /// <summary>Разово: применять тему шапки ко всем окнам при их появлении.</summary>
    public static void HookAllWindows() =>
        EventManager.RegisterClassHandler(typeof(Window), Window.LoadedEvent,
            new RoutedEventHandler((_, e) =>
            {
                if (e.Source is Window) ApplyAll(Themes.IsDark);
            }));

    public static void ApplyAll(bool dark)
    {
        // BGR: caption = CPanel, text = Cfg
        _color = dark ? ToBgr(0x1F, 0x21, 0x24) : ToBgr(0xF4, 0xF4, 0xF4);
        int text = dark ? ToBgr(0xE6, 0xE6, 0xE6) : ToBgr(0x1A, 0x1A, 0x1A);
        int on = dark ? 1 : 0;
        foreach (Window w in Application.Current.Windows)
        {
            var helper = new WindowInteropHelper(w);
            if (helper.Handle == IntPtr.Zero) continue;
            DwmSetWindowAttribute(helper.Handle, 20, ref on, 4);        // USE_IMMERSIVE_DARK_MODE
            DwmSetWindowAttribute(helper.Handle, 35, ref _color, 4);    // CAPTION_COLOR (Win11)
            DwmSetWindowAttribute(helper.Handle, 36, ref text, 4);      // BORDER_COLOR
        }
    }

    private static int ToBgr(byte r, byte g, byte b) => (b << 16) | (g << 8) | r;
}
