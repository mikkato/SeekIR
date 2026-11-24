using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using SeekIRWin.Core;

namespace SeekIRWin.App;

/// <summary>Экспорт кадров FW1: PNG/JPG из WriteableBitmap (WPF-энкодеры).</summary>
public static class Exports
{
    /// <summary>PNG-байты -> BitmapSource (для миниатюр в чате).</summary>
    public static BitmapSource BitmapFromPng(byte[] png)
    {
        var bi = new BitmapImage();
        using var ms = new MemoryStream(png);
        bi.BeginInit();
        bi.CacheOption = BitmapCacheOption.OnLoad;
        bi.StreamSource = ms;
        bi.EndInit();
        bi.Freeze();
        return bi;
    }

    /// <summary>Поворот кадра на 90° против часовой — как на экране (камера
    /// держится вертикально). Raw signal.r16 в галерее не поворачивается.</summary>
    public static BitmapSource Rotated(BitmapSource src) =>
        new TransformedBitmap(src, new RotateTransform(-90));

    public static byte[] Png(BitmapSource bmp, int quality = -1)
    {
        bmp = Rotated(bmp);
        var enc = quality < 0 ? (BitmapEncoder)new PngBitmapEncoder()
                              : new JpegBitmapEncoder { QualityLevel = quality };
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var ms = new MemoryStream();
        enc.Save(ms);
        return ms.ToArray();
    }

    public static void ExportDialog(BitmapSource bmp, string baseName, bool jpeg)
    {
        var dlg = new SaveFileDialog
        {
            FileName = baseName + (jpeg ? ".jpg" : ".png"),
            Filter = jpeg ? "JPEG|*.jpg" : "PNG|*.png",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
        };
        if (dlg.ShowDialog() != true) return;
        File.WriteAllBytes(dlg.FileName, Png(bmp, jpeg ? 92 : -1));
    }
}
