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
    private SeekCam.Frame? _lastFrame;
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
        BtnExportJpg.IsEnabled = BtnExportPng.IsEnabled = true;
        BtnRec.IsEnabled = true;
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
        // снимок берёт raw-сигнал последнего ПОКАЗАННОГО кадра (на паузе — замороженного)
        if (!_frozen) _lastFrame = f;
        _rec?.Write(f.Rgb); // запись живого потока (нативная ориентация; ffmpeg повернёт)
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
                $"span {f.Lo:F0}..{f.Hi:F0}  центр {f.Temp[mid]:F1} °C  M:{_markWinX},{_markWinY}";
            UpdateScale(f.Lo, f.Hi);
            UpdateMaxMarker(f);
        });
    }

    // ---- живой маркер максимума (F2 hot-spot) ----
    // Кадр разбит сеткой 3x3 (нарисована на Ovl). Анализ начинается с
    // центрального квадрата: первый захват — лучший горячий участок внутри
    // центра; далее маркер следует за кадром в общем гистерезисе (+0,5 °C).
    // Внутри выбранной зоны — окно 10x10 с макс. средним, крест ставится на
    // локальный максимум пикселя внутри окна.
    private int _markIdx = -1;          // позиция перекрестия (индекс 320x240)
    private int _markWinX = -1, _markWinY = -1; // левый верх текущего окна
    private double _markWinMean;        // среднее текущего окна (гистерезис)
    private const int Win = 10;         // окно анализа 10x10 px
    // центральный квадрат сетки 3x3: x 107..212, y 80..159 (включительно)
    private const int Cx0 = SeekConst.W / 3, Cx1 = SeekConst.W * 2 / 3 - 1;
    private const int Cy0 = SeekConst.H / 3, Cy1 = SeekConst.H * 2 / 3 - 1;

    private readonly double[] _integ = new double[(SeekConst.W + 1) * (SeekConst.H + 1)];
    private void BuildIntegral(double[] t)
    {
        const int W = SeekConst.W, P = W + 1;
        for (int y = 0; y < H1; y++) _integ[y * P] = 0;
        for (int x = 0; x < P; x++) _integ[x] = 0;
        for (int y = 1; y < H1; y++)
        {
            double rowSum = 0; int up = (y - 1) * P, cur = y * P, tc = (y - 1) * W;
            for (int x = 1; x < P; x++)
            {
                rowSum += t[tc + x - 1];
                _integ[cur + x] = _integ[up + x] + rowSum;
            }
        }
    }
    private const int H1 = SeekConst.H + 1;
    private double WindowMean(int x0, int y0)
    {
        const int W = SeekConst.W, P = W + 1, N = Win * Win;
        int a = y0 * P + x0, b = y0 * P + x0 + Win, c = (y0 + Win) * P + x0, d = (y0 + Win) * P + x0 + Win;
        return (_integ[d] - _integ[c] - _integ[b] + _integ[a]) / N;
    }
    private void UpdateMaxMarker(SeekCam.Frame f)
    {
        var t = f.Temp;
        BuildIntegral(t);
        // лучшее окно 10x10 по всему кадру
        int bx = -1, by = -1; double bmean = double.MinValue;
        for (int wy = 0; wy <= SeekConst.H - Win; wy++)
            for (int wx = 0; wx <= SeekConst.W - Win; wx++)
            {
                double m = WindowMean(wx, wy);
                if (m > bmean) { bmean = m; bx = wx; by = wy; }
            }
        if (_markWinX < 0)
        {
            // старт анализа — из центрального квадрата сетки 3x3
            bx = -1; by = -1; bmean = double.MinValue;
            for (int wy = Cy0; wy <= Cy1 - Win + 1; wy++)
                for (int wx = Cx0; wx <= Cx1 - Win + 1; wx++)
                {
                    double m = WindowMean(wx, wy);
                    if (m > bmean) { bmean = m; bx = wx; by = wy; }
                }
        }
        else
        {
            // гистерезис: перескакиваем, только если лучшее окно теплее текущего на 0,5 °C
            // (оба средних считаем на текущем кадре)
            double curMean = WindowMean(_markWinX, _markWinY);
            if (bmean <= curMean + 0.5) { bx = _markWinX; by = _markWinY; bmean = curMean; }
        }
        _markWinX = bx; _markWinY = by; _markWinMean = bmean;
        // локальный максимум внутри окна — точная точка перекрестия
        int px = bx, py = by; double vmax = double.MinValue;
        for (int ly = by; ly < by + Win; ly++)
            for (int lx = bx; lx < bx + Win; lx++)
            {
                int i = ly * SeekConst.W + lx;
                if (t[i] > vmax) { vmax = t[i]; px = lx; py = ly; }
            }
        _markIdx = py * SeekConst.W + px;
        int x = px, y = py; double tm = vmax;
        // компактное перекрестие: короткие штрихи сквозь центр, центр закрыт боксом
        const double arm = 9;   // длина луча от центра
        HLine.X1 = x - arm; HLine.X2 = x + arm; HLine.Y1 = y; HLine.Y2 = y;
        VLine.X1 = x; VLine.X2 = x; VLine.Y1 = y - arm; VLine.Y2 = y + arm;
        Canvas.SetLeft(HLine, 0); Canvas.SetTop(HLine, 0);
        Canvas.SetLeft(VLine, 0); Canvas.SetTop(VLine, 0);
        Canvas.SetLeft(MarkBox, x - 4.5); Canvas.SetTop(MarkBox, y - 4.5);
        MarkTxt.Text = $"{tm:F1} \u00b0C";
        double tx = x + 7, ty = y - 9;
        if (tx > SeekConst.W - 46) tx = x - 52;
        if (ty < 1) ty = y + 4;
        Canvas.SetLeft(MarkTag, tx); Canvas.SetTop(MarkTag, ty);
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

    // ---- FW2: запись видео (ffmpeg pipe -> H.264 mp4) ----
    private FfRecorder? _rec;
    private System.Windows.Threading.DispatcherTimer? _recTimer;

    private void OnRec(object sender, RoutedEventArgs e)
    {
        if (_rec is { IsRunning: true })
        {
            BtnRec.IsEnabled = false;
            string path = "";
            // остановка кодирования вне UI-потока: mp4 finalize может ждать секунды
            Task.Run(() =>
            {
                path = _rec!.Stop();
                Dispatcher.BeginInvoke(() =>
                {
                    _rec = null; _recTimer?.Stop();
                    BtnRec.Content = "Запись"; TxtRec.Text = ""; BtnRec.IsEnabled = _cam.IsOpen;
                    TxtStatus.Text = path.Length > 0 ? $"видео: {path}" : "видео: ошибка кодирования";
                });
            });
            return;
        }
        if (_lastFrame is null) return;
        string dir = _snapDir;
        Directory.CreateDirectory(dir);
        string outPath = Path.Combine(dir, $"IR_{DateTime.Now:yyyyMMdd_HHmmss}.mp4");
        double fps = Math.Clamp(_lastFrame.Fps <= 0 ? 7 : _lastFrame.Fps, 1, 30);
        _rec = new FfRecorder();
        if (!_rec.Start(outPath, fps, AppContext.BaseDirectory))
        {
            TxtStatus.Text = "ffmpeg.exe не найден рядом с приложением";
            _rec = null; return;
        }
        BtnRec.Content = "Стоп";
        _recTimer = new System.Windows.Threading.DispatcherTimer
        { Interval = TimeSpan.FromMilliseconds(500) };
        _recTimer.Tick += (_, _) => TxtRec.Text = $"{_rec!.Frames / fps:F0} c";
        _recTimer.Start();
        TxtStatus.Text = $"запись: {outPath}";
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
        var f = _lastFrame;
        if (_bmp is null || f is null) return;
        string name = $"IR_{DateTime.Now:yyyyMMdd_HHmmss}";
        var meta = new SnapshotMeta
        {
            Timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Palette = CmbPalette.SelectedIndex >= 0 ? Palettes[CmbPalette.SelectedIndex].Name : "ironbow",
            SpanLo = f.Lo, SpanHi = f.Hi, SpanAuto = ChkAutoSpan.IsChecked == true,
            Fps = f.Fps, CenterCelsius = f.Temp[SeekConst.W * SeekConst.H / 2],
            MeanSignal = f.MeanSignal,
            Smooth = (float)SldSmooth.Value, Motion = SeekConst.Motion, Spatial = SeekConst.Spatial,
            Hotmap = ResolveHotmap() ?? "",
        };
        string dir = Gallery.Save(name, f.Signal, Exports.Png(_bmp), meta);
        TxtStatus.Text = $"снимок: {Path.GetFileName(dir)} (raw+png+meta)";
    }

    private void OnExport(object sender, RoutedEventArgs e)
    {
        if (_bmp is null) return;
        string baseName = $"IR_{DateTime.Now:yyyyMMdd_HHmmss}";
        if (sender == BtnExportJpg) Exports.ExportDialog(_bmp, baseName, jpeg: true);
        else Exports.ExportDialog(_bmp, baseName, jpeg: false);
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
        BtnExportJpg.IsEnabled = BtnExportPng.IsEnabled = ok;
        BtnConnect.IsEnabled = !ok;
        SldSmooth.IsEnabled = _denReady = ok;
        if (ok) _cam.SetDenoise((float)SldSmooth.Value, SeekConst.Motion, SeekConst.Spatial, reset: true);
        if (!ok) StartRetryTimer();
        if (!ok) TxtStatus.Text = "камера не вернулась после перезапуска (пероткните USB)";
    }
}
