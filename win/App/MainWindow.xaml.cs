using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using SeekIRWin.Core;

namespace SeekIRWin.App;

public partial class MainWindow : Window
{
    private SeekCam _cam = new();
    private WriteableBitmap? _bmp;
    private WriteableBitmap? _palBmp;
    private bool _frozen;
    private string _snapDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Термография");

    // имена палитр совпадают с sk_palette_from_name в C-ядре
    private static readonly (string Name, int Id)[] Palettes =
    [
        ("ironbow", 0), ("ironbow2", 1), ("rainbow", 2), ("arctic", 3),
        ("whitehot", 4), ("blackhot", 5), ("lava", 6), ("jet", 7), ("medical", 8),
    ];

    public MainWindow()
    {
        InitializeComponent();
        CmbPalette.ItemsSource = Palettes.Select(p => p.Name).ToList();
        CmbPalette.SelectedIndex = 0;
        Themes.Apply(Themes.Mode.System);
        BuildPaletteStrip(0);
        _cam.FrameArrived += OnFrame; // поток libusb-воркера
        Closed += (_, _) => _cam.Dispose();
        // автоподключение: тепловизор — основное устройство; ретрай 2 с, пока открыто окно
        Loaded += (_, _) => { TryConnect(); StartRetryTimer(); };
    }

    private System.Windows.Threading.DispatcherTimer? _retry;
    private void StartRetryTimer()
    {
        if (_cam.IsOpen) return;
        _retry = new System.Windows.Threading.DispatcherTimer
        { Interval = TimeSpan.FromSeconds(2) };
        _retry.Tick += (_, _) => TryConnect();
        _retry.Start();
    }

    private void TryConnect()
    {
        if (_cam.IsOpen) { _retry?.Stop(); return; }
        string? hot = ResolveHotmap();
        if (!_cam.Open(hot)) return;
        _retry?.Stop();
        BtnConnect.IsEnabled = false;
        BtnFreeze.IsEnabled = BtnSnap.IsEnabled = BtnHotmap.IsEnabled = true;
        SldSmooth.IsEnabled = true;
        _denReady = true;
        _cam.SetDenoise((float)SldSmooth.Value, SeekConst.Motion, SeekConst.Spatial, reset: true);
        TxtStatus.Text = "подключение…";
    }

    // ---- тема ----
    private void OnTheme(object sender, RoutedEventArgs e)
    {
        if (CmbTheme?.SelectedIndex is null) return;
        Themes.Apply((Themes.Mode)(CmbTheme.SelectedIndex == 0 ? 2 : CmbTheme.SelectedIndex - 1));
        // Mode: 0=System,1=Light,2=Dark в комбобоксе -> enum Light,Dark,System
    }

    // ---- камера ----
    private void OnConnect(object sender, RoutedEventArgs e) => TryConnect();

    private static string? ResolveHotmap()
    {
        // приоритет: пользовательская карта (%APPDATA%\SeekIRWin\hot.bin),
        // иначе эталонная рядом с exe
        string user = HotmapPath();
        if (File.Exists(user)) return user;
        string p = Path.Combine(AppContext.BaseDirectory, "hot.bin");
        return File.Exists(p) ? p : null;
    }

    private void OnFrame(SeekCam.Frame f)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (_frozen) return;
            if (_bmp is null)
            {
                _bmp = new WriteableBitmap(SeekConst.W, SeekConst.H, 96, 96,
                    PixelFormats.Bgr32, null);
                Img.Source = _bmp;
            }
            // RGB888 -> BGR32
            var px = new byte[SeekConst.W * SeekConst.H * 4];
            for (int i = 0; i < SeekConst.W * SeekConst.H; i++)
            {
                px[i * 4 + 0] = f.Rgb[i * 3 + 2];
                px[i * 4 + 1] = f.Rgb[i * 3 + 1];
                px[i * 4 + 2] = f.Rgb[i * 3 + 0];
            }
            _bmp.WritePixels(new Int32Rect(0, 0, SeekConst.W, SeekConst.H), px,
                             SeekConst.W * 4, 0);
            int mid = SeekConst.W * SeekConst.H / 2;
            TxtStatus.Text =
                $"{f.Fps,4:F1} к/с  кадр {f.Frames}  FF {f.Ffs}  err {f.Errors}  recon {f.Resyncs}  " +
                $"span {f.Lo:F0}..{f.Hi:F0}  центр {f.Temp[mid]:F1} °C";
            UpdateScale(f.Lo, f.Hi);
        });
    }

    private void UpdateScale(double lo, double hi)
    {
        TxtLo.Text = $"{lo:F1}";
        TxtHi.Text = $"{hi:F1}";
        TxtMid.Text = $"{(lo + hi) / 2:F1}";
        // span-окно на шкале: кадр не тонмапится линейно по span (авто перцентили),
        // поэтому маски пока не считаем — v0 показывает только границы
    }

    private void BuildPaletteStrip(int pal)
    {
        // столбец 1x256 по LUT ядра: пересчёт серого -> RGB через нативную LUT нельзя
        // напрямую (LUT внутренняя), рисуем градиент приближённо по 256 gray-уровням
        // из того же кадра нельзя — строим эталонный铁 LUT-срез программно в UI:
        // для v0 берём ironbow-подобный градиент; точная синхронизация с ядром — этап W5.
        var w = 1; var h = 256;
        var px = new byte[w * h * 4];
        for (int i = 0; i < 256; i++)
        {
            double t = i / 255.0; // 0=холодно (низ), 1=горячо
            // ironbow-аппроксимация: сине-чёрно-красно-жёлто-белая
            System.Drawing.Color c = pal is 4 or 5
                ? System.Drawing.Color.FromArgb((int)(t * 255), (int)(t * 255), (int)(t * 255))
                : IronbowApprox(t);
            int idx = (255 - i) * 4; // сверху — горячее
            px[idx + 0] = c.B; px[idx + 1] = c.G; px[idx + 2] = c.R; px[idx + 3] = 255;
        }
        _palBmp = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgr32, null);
        _palBmp.WritePixels(new Int32Rect(0, 0, w, h), px, 4, 0);
        PaletteImg.Source = _palBmp;
    }

    private static System.Drawing.Color IronbowApprox(double t)
    {
        // 5 опорных точек ironbow (условно)
        (double P, byte R, byte G, byte B)[] stops =
        [
            (0.0,  10, 10, 60),
            (0.3,  40, 20, 160),
            (0.55, 190, 40, 40),
            (0.8,  250, 180, 40),
            (1.0,  255, 255, 255),
        ];
        for (int s = 0; s < stops.Length - 1; s++)
        {
            if (t <= stops[s + 1].P)
            {
                double k = (t - stops[s].P) / (stops[s + 1].P - stops[s].P);
                return System.Drawing.Color.FromArgb(
                    (byte)(stops[s].R + k * (stops[s + 1].R - stops[s].R)),
                    (byte)(stops[s].G + k * (stops[s + 1].G - stops[s].G)),
                    (byte)(stops[s].B + k * (stops[s + 1].B - stops[s].B)));
            }
        }
        return System.Drawing.Color.White;
    }

    // ---- управление ----
    private void OnScaleMode(object sender, SelectionChangedEventArgs e)
    {
        if (Img is null || CmbScale?.SelectedIndex is null) return;
        RenderOptions.SetBitmapScalingMode(Img, CmbScale.SelectedIndex switch
        {
            1 => BitmapScalingMode.Linear,
            2 => BitmapScalingMode.HighQuality, // кубический/fant
            _ => BitmapScalingMode.NearestNeighbor,
        });
    }

    private bool _denReady; // не дёргать ядро до подключения
    private void OnSmooth(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!_denReady || !_cam.IsOpen) return;
        _cam.SetDenoise((float)SldSmooth.Value, SeekConst.Motion, SeekConst.Spatial, reset: true);
    }

    private void OnFreeze(object sender, RoutedEventArgs e)
    {
        _frozen = !_frozen;
        BtnFreeze.Content = _frozen ? "Продолжить" : "Пауза";
    }

    private void OnPalette(object sender, SelectionChangedEventArgs e)
    {
        if (!_cam.IsOpen || CmbPalette.SelectedIndex < 0) return;
        _cam.SetPalette(Palettes[CmbPalette.SelectedIndex].Id);
        BuildPaletteStrip(Palettes[CmbPalette.SelectedIndex].Id);
    }

    private void OnAutoSpan(object sender, RoutedEventArgs e) =>
        _cam.SetSpanManual(ChkAutoSpan.IsChecked != true, 20, 30);

    private void OnSnap(object sender, RoutedEventArgs e)
    {
        if (_bmp is null) return;
        Directory.CreateDirectory(_snapDir);
        string name = $"IR_{DateTime.Now:yyyyMMdd_HHmmss}.png";
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(_bmp));
        using var fs = File.Create(Path.Combine(_snapDir, name));
        enc.Save(fs);
        TxtStatus.Text = $"снимок: {name}";
    }

    private HotmapBuilder? _hm;
    private string _hotmapResult = "";
    private void OnHotmap(object sender, RoutedEventArgs e)
    {
        if (!_cam.IsOpen) return;
        if (_hm is not null)
        {
            // повторное нажатие — завершить раньше; минимум 30 FF, иначе σ-оценка
            // зашумлена и карта недооценивает битые пиксели (проверено: 14 FF -> 0.10%)
            if (_hm.Collected >= 30) { FinishHotmap(_hm); }
            else { TxtStatus.Text = $"карта шума: рано — {_hm.Collected}/30 FF (повторное нажатие при ≥30)"; }
            return;
        }
        _hm = new HotmapBuilder(60);
        BtnHotmap.Content = "Завершить";
        _cam.SetFfCallback(sig =>
        {
            var b = _hm;
            if (b is null) return;
            b.AddFf(sig);
            Dispatcher.BeginInvoke(() =>
            {
                if (!b.IsDone) { TxtStatus.Text = $"карта шума: FF {b.Collected}/60 — повторное нажатие завершит (мин. 10)"; return; }
                FinishHotmap(b);
            });
        });
    }

    private void FinishHotmap(HotmapBuilder b)
    {
        // builder считает маску по достижении TargetFf; для досрочного — пересчёт
        if (!b.IsDone) b.ForceCompute();
        string path = HotmapPath();
        b.Save(path);
        _cam.SetFfCallback(null);
        _hm = null;
        BtnHotmap.Content = "Карта шума";
        RestartWithHotmap(path);
        TxtStatus.Text = $"карта шума: {b.Summary} — применена";
        _hotmapResult = b.Summary + " -> " + path;
    }

    private static string HotmapPath() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                     "SeekIRWin", "hot.bin");

    private void RestartWithHotmap(string hotpath)
    {
        // ядро читает карту при open — мягкий перезапуск потока
        _cam.Dispose();
        _bmp = null; Img.Source = null;
        _cam = new SeekCam();
        _cam.FrameArrived += OnFrame;
        bool ok = _cam.Open(File.Exists(hotpath) ? hotpath : ResolveHotmap());
        BtnHotmap.IsEnabled = ok;
        BtnFreeze.IsEnabled = BtnSnap.IsEnabled = ok;
        BtnConnect.IsEnabled = !ok;
        SldSmooth.IsEnabled = _denReady = ok;
        if (ok) _cam.SetDenoise((float)SldSmooth.Value, SeekConst.Motion, SeekConst.Spatial, reset: true);
        if (!ok) StartRetryTimer();
        if (!ok) TxtStatus.Text = "камера не вернулась после перезапуска (пероткните USB)";
    }
}
