using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using SeekIRWin.Core;

namespace SeekIRWin.App;

public partial class MainWindow : Window
{
    private SeekCam _cam = new();
    private AppConfig _cfg = AppConfig.Load();
    private SeekCam.Frame? _lastFrame;
    private WriteableBitmap? _bmp;
    private WriteableBitmap? _palBmp;
    private bool _frozen;
    private Radiometry _radio = new();
    private readonly double[] _hist = new double[96];    // гистограмма счёт-сигнала
    private bool _histDrag;
    private double _histCenter = double.NaN;             // центр ручного span, °C
    private double _histWidth = 5.0;                     // ширина ручного span, °C
    private double _probeX = -1, _probeY = -1;           // ручной зонд, -1 = выкл
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
        int palIdx = Array.FindIndex(Palettes, p => p.Name == _cfg.Palette);
        CmbPalette.SelectedIndex = palIdx >= 0 ? palIdx : 0;
        Themes.Apply(Themes.Mode.System);
        BuildPaletteStrip(Palettes[CmbPalette.SelectedIndex].Id);
        // тумблеры оверлеев из конфига
        ChkMarks.IsChecked = _cfg.ShowMarks;
        ChkGridOvl.IsChecked = _cfg.ShowGrid;
        ChkRoi.IsChecked = _cfg.ShowRoi;
        RoiG.Visibility = _cfg.ShowRoi ? Visibility.Visible : Visibility.Collapsed;
        RebuildDeltaCombos();
        ApplyOverlayToggles();
        _cam.FrameArrived += OnFrame; // поток libusb-воркера
        Closed += (_, _) => _cam.Dispose();
        // автоподключение: тепловизор — основное устройство; ретрай 2 с, пока открыто окно
        Loaded += (_, _) => { WindowTheme.ApplyAll(Themes.IsDark); TryConnect(); StartRetryTimer(); };
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
        _cam.SetGainPath(GainCachePath()); // NUC-карта ID4: загрузить кэш, писать свежую
        _retry?.Stop();
        BtnConnect.IsEnabled = false;
        BtnFreeze.IsEnabled = BtnSnap.IsEnabled = BtnHotmap.IsEnabled = true;
        BtnExportJpg.IsEnabled = BtnExportPng.IsEnabled = true;
        BtnRec.IsEnabled = true;
        BtnReport.IsEnabled = !string.IsNullOrWhiteSpace(_cfg.Llm.BaseUrl);
        BtnCalib.IsEnabled = true;
        SldSmooth.IsEnabled = true;
        _denReady = true;
        _cam.SetDenoise((float)SldSmooth.Value, SeekConst.Motion, SeekConst.Spatial, reset: true);
        _cam.SetPalette(Palettes[Math.Max(CmbPalette.SelectedIndex, 0)].Id);
        // калибровка Планка, если пользователь снимал по чёрному телу (F8)
        string calib = Path.Combine(AppConfig.Dir, "planck.calib");
        if (File.Exists(calib)) _cam.PlanckLoad(calib);
        _radio.SetPlanck(_cam.PlanckGet());
        ResetProbe();
        ApplyScene();
        TxtStatus.Text = "подключение…";
    }

    private void ApplyScene()
    {
        if (!_cam.IsOpen) return;
        var s = _cfg.Scene;
        double tRefl = s.TReflEqualsAir ? s.TAtmC : s.TReflC;
        _cam.SetScene(s.Emissivity, tRefl, s.TAtmC, s.DistanceM, s.RelHumidity);
        _radio.SetScene(s.Emissivity, tRefl, s.TAtmC, s.DistanceM, s.RelHumidity);
    }

    // ---- сцена (радиометрии) ----
    private void OnScene(object sender, RoutedEventArgs e)
    {
        var w = new SceneWindow(_cfg) { Owner = this };
        if (w.ShowDialog() == true)
        {
            ApplyScene();
            TxtStatus.Text = $"сцена: ε={_cfg.Scene.Emissivity:0.00}, " +
                             $"T_refl={(_cfg.Scene.TReflEqualsAir ? _cfg.Scene.TAtmC : _cfg.Scene.TReflC):0.0} °C, " +
                             $"{_cfg.Scene.DistanceM:0.0} м";
        }
    }

    // ---- тумблеры оверлеев на кадре ----
    private void ApplyOverlayToggles()
    {
        bool marks = ChkMarks.IsChecked == true, grid = ChkGridOvl.IsChecked == true;
        MarkG.Visibility = marks ? Visibility.Visible : Visibility.Collapsed;
        GridG.Visibility = grid ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnOvlToggle(object sender, RoutedEventArgs e)
    {
        ApplyOverlayToggles();
        _cfg.ShowMarks = ChkMarks.IsChecked == true;
        _cfg.ShowGrid = ChkGridOvl.IsChecked == true;
        _cfg.Save();
    }

    // ---- настройки LLM ----
    private void OnSettings(object sender, RoutedEventArgs e)
    {
        var w = new SettingsWindow(_cfg) { Owner = this };
        if (w.ShowDialog() == true)
        {
            _cfg.Save();
            BtnReport.IsEnabled = !string.IsNullOrWhiteSpace(_cfg.Llm.BaseUrl);
            TxtStatus.Text = $"LLM: {_cfg.Llm.BaseUrl} · {_cfg.Llm.Model}";
        }
    }

    // ---- LLM-интервью / отчёт (F4/F5) ----
    private void OnReport(object sender, RoutedEventArgs e)
    {
        if (_bmp is null || _lastFrame is null) return;
        byte[] png = Exports.Png(Exports.Rotated(_bmp));
        var f = _lastFrame;
        var s = _cfg.Scene;
        int mid = SeekConst.W * SeekConst.H / 2;
        string facts =
            $"Палитра: {(CmbPalette.SelectedIndex >= 0 ? Palettes[CmbPalette.SelectedIndex].Name : "?")}; " +
            $"span {f.Lo:F0}..{f.Hi:F0} отсч.; центр кадра {f.Temp[mid]:F1} °C\n" +
            $"ε={s.Emissivity:0.00} ({s.Material}); T_возд={s.TAtmC:0.0} °C; " +
            $"T_refl={(s.TReflEqualsAir ? s.TAtmC : s.TReflC):0.0} °C; " +
            $"дистанция {s.DistanceM:0.0} м; RH {s.RelHumidity:0} %";
        new ReportWindow(new LlmClient(_cfg.Llm), png, facts) { Owner = this }.Show();
    }

    // ---- калибровка под управлением LLM ----
    private CalibrationWindow? _calibWin;
    private readonly Queue<double> _centerHist = new(); // T центра, окно ~40 кадров (~6 c)

    private void OnCalib(object sender, RoutedEventArgs e)
    {
        if (_calibWin is { IsLoaded: true }) { _calibWin.Activate(); return; }
        _calibWin = new CalibrationWindow(this, new LlmClient(_cfg.Llm)) { Owner = this };
        _calibWin.Show();
    }

    /// <summary>Баннер указаний модели поверх кадра (пустая строка — спрятать).</summary>
    public void SetCalibHint(string hint)
    {
        if (string.IsNullOrWhiteSpace(hint))
        {
            CalibBanner.Visibility = Visibility.Collapsed;
            StampBadge.Visibility = _cam.IsOpen ? Visibility.Visible : Visibility.Collapsed;
            return;
        }
        StampBadge.Visibility = Visibility.Collapsed; // общий верхний-левый угол
        CalibTxt.Text = hint;
        CalibBanner.Visibility = Visibility.Visible;
    }

    /// <summary>Снимок для калибровщика: PNG повёрнутого кадра + телеметрия +
    /// среднее по центру 10x10 (сигнал/температура) + признак стабилизации.</summary>
    public CalibrationWindow.Snap CalibSnapshot()
    {
        var f = _lastFrame ?? throw new InvalidOperationException("нет кадра");
        byte[] png = _bmp is null ? [] : Exports.Png(Exports.Rotated(_bmp));
        double sig = 0, t = 0; int n = 0;
        for (int ry = MidY - 5; ry < MidY + 5; ry++)
            for (int rx = MidX - 5; rx < MidX + 5; rx++)
            {
                int i = ry * SeekConst.W + rx;
                sig += f.Signal[i]; t += f.Temp[i]; n++;
            }
        sig /= n; t /= n;
        // стабилизация: разброс T центра за ~40 кадров < 0.4 °C
        lock (_centerHist)
        {
            _centerHist.Enqueue(t);
            while (_centerHist.Count > 40) _centerHist.Dequeue();
        }
        bool stable = _centerHist.Count >= 15 && _centerHist.Max() - _centerHist.Min() < 0.4;
        var s = _cfg.Scene;
        string facts =
            $"span {f.Lo:F0}..{f.Hi:F0} отсч.; fps {f.Fps:F1}\n" +
            $"ε={s.Emissivity:0.00} ({s.Material}); T_возд={s.TAtmC:0.0} °C; " +
            $"T_refl={(s.TReflEqualsAir ? s.TAtmC : s.TReflC):0.0} °C; RH {s.RelHumidity:0} %";
        return new CalibrationWindow.Snap(png, facts, sig, t, stable);
    }

    /// <summary>Планк-фит по 2 точкам + сохранение planck.calib. null = успех.</summary>
    public string? CalibFit(double s1, double c1, double s2, double c2)
    {
        if (Math.Abs(c2 - c1) < 8) return "опорные температуры должны различаться минимум на ~10 °C";
        if (!_cam.PlanckFit(s1, c1, s2, c2)) return "точки вырождены — сигнал/температуры не дали решения";
        _radio.SetPlanck(_cam.PlanckGet());
        ResetProbe();
        try { _cam.PlanckSave(Path.Combine(AppConfig.Dir, "planck.calib")); }
        catch (Exception ex) { return "фит применён, но сохранение не удалось: " + ex.Message; }
        return null;
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

    /// <summary>Кэш NUC-карты усиления (кадр ID4 PRO). Ядро читает его при
    /// открытии и перезаписывает при приёме свежей карты с камеры.</summary>
    private static string GainCachePath()
    {
        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SeekIRWin");
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, "gain.cache");
    }

    private void OnFrame(SeekCam.Frame f)
    {
        // снимок берёт raw-сигнал последнего ПОКАЗАННОГО кадра (на паузе — замороженного)
        if (!_frozen) _lastFrame = f;
        _rec?.Write(f.Rgb, f.Signal); // запись живого потока (нативная ориентация; ffmpeg повернёт)
        Dispatcher.BeginInvoke(() =>
        {
            if (_frozen) return;
            if (_bmp is null)
            {
                _bmp = new WriteableBitmap(SeekConst.W, SeekConst.H, 96, 96,
                    PixelFormats.Bgr32, null);
                Img.Source = _bmp;
            }
            // RGB888 -> BGR32 (+ изотерма: подсветка пикселей теплее порога)
            double isoT = double.NaN;
            if (ChkIso.IsChecked == true)
                double.TryParse(TxtIso.Text.Replace(',', '.'),
                    System.Globalization.CultureInfo.InvariantCulture, out isoT);
            bool iso = !double.IsNaN(isoT);
            var px = new byte[SeekConst.W * SeekConst.H * 4];
            for (int i = 0; i < SeekConst.W * SeekConst.H; i++)
            {
                if (iso && f.Temp[i] >= isoT)
                {
                    px[i * 4 + 0] = 0; px[i * 4 + 1] = 230; px[i * 4 + 2] = 230; // жёлтый (BGR)
                    continue;
                }
                px[i * 4 + 0] = f.Rgb[i * 3 + 2];
                px[i * 4 + 1] = f.Rgb[i * 3 + 1];
                px[i * 4 + 2] = f.Rgb[i * 3 + 0];
            }
            _bmp.WritePixels(new Int32Rect(0, 0, SeekConst.W, SeekConst.H), px,
                             SeekConst.W * 4, 0);
            int mid = SeekConst.W * SeekConst.H / 2;
            TxtStatus.Text =
                $"скорость {f.Fps:F1} к/с · кадров {f.Frames} · шторка {f.Ffs} · ошибок {f.Errors} · " +
                $"переподключений {f.Resyncs} · шкала {f.Lo:F0}…{f.Hi:F0} · центр {f.Temp[mid]:F1} °C" +
                (f.TDevC > 0 ? $" · FPA {f.TDevC:F1} °C" : "");
            UpdateScale(f.Lo, f.Hi);
            UpdateMaxMarker(f);
            UpdateProbe(f);
            if (ChkRoi.IsChecked == true && _zones.Count > 0) UpdateRois(f);
            UpdateHistogram(f);
            UpdateSideInfo(f);
        });
    }

    /// <summary>Левая служебная панель: параметры съёмки и измерения (OSD-спек P1:
    /// не на фрейме, а в панели; обновление раз в ~0.5 с достаточно).</summary>
    private DateTime _sideT = DateTime.MinValue;
    private void UpdateSideInfo(SeekCam.Frame f)
    {
        if ((DateTime.Now - _sideT).TotalMilliseconds < 500) return;
        _sideT = DateTime.Now;
        if (CalibBanner.Visibility != Visibility.Visible)
        {
            StampBadge.Visibility = Visibility.Visible;
            StampTxt.Text = DateTime.Now.ToString("dd.MM HH:mm:ss");
        }
        LbStream.Text = $"{f.Fps:F1} к/с";
        LbStream.ToolTip = $"кадр {f.Frames} · FF {f.Ffs} · err {f.Errors} · recon {f.Resyncs}";
        LbRes.Text = $"320×240 · {Palettes[Math.Max(CmbPalette.SelectedIndex, 0)].Name}";
        bool manual = ChkAutoSpan.IsChecked != true;
        if (manual && _radio.Ready)
            LbSpanC.Text = $"шкала: {_radio.ToCelsius(_spanLo):F0}…{_radio.ToCelsius(_spanHi):F0} °C ручн.";
        else
            LbSpanC.Text = "шкала: авто";
        if (ChkIso.IsChecked == true)
        {
            double.TryParse(TxtIso.Text.Replace(',', '.'),
                System.Globalization.CultureInfo.InvariantCulture, out double isoT);
            LbIsoC.Text = double.IsNaN(isoT) ? "изотерма: ?" : $"изотерма ≥ {isoT:F1} °C";
        }
        else LbIsoC.Text = "изотерма: выкл";
        LbDenC.Text = $"сглаживание: {SldSmooth.Value:F2}";
        if (_radio.Ready)
        {
            double mn = double.MaxValue, mx = double.MinValue;
            var t = f.Temp;
            for (int i = 0; i < t.Length; i++)
            {
                if (t[i] < -200) continue; // заглушки ядра
                if (t[i] < mn) mn = t[i];
                if (t[i] > mx) mx = t[i];
            }
            LbDT.Text = $"ΔT кадра: {mx - mn:F1} °C";
            LbDT.ToolTip = $"{mn:F1}…{mx:F1} °C";
        }
        int mid2 = SeekConst.W * SeekConst.H / 2;
        LbCenterT.Text = $"центр: {f.Temp[mid2]:F1} °C";
        var s = _cfg.Scene;
        LbEps.Text = $"ε: {s.Emissivity:0.00}";
        LbEps.ToolTip = s.Material;
        LbTRefl.Text = $"T отр: {(s.TReflEqualsAir ? s.TAtmC : s.TReflC):F1} °C";
        LbDist.Text = $"дист: {s.DistanceM:F1} м · RH {s.RelHumidity:F0} %";
        LbCalib.Text = _radio.Ready ? "планк: применена" : "планк: нет (±5 °C)";
        LbCalib.ToolTip = _radio.Ready
            ? "коэффициенты Планка из planck.calib применяются к °C"
            : "калибровка по 2 опорным точкам не выполнялась — абсолютные °C могут быть смещены до ±5 °C";
        LbLlm.Text = string.IsNullOrWhiteSpace(_cfg.Llm.BaseUrl)
            ? "не настроен" : $"{_cfg.Llm.Model}";
        LbLlm.ToolTip = string.IsNullOrWhiteSpace(_cfg.Llm.BaseUrl) ? "откройте настройки (шестерёнка)" : _cfg.Llm.BaseUrl;
    }

    // ---- метки температуры (F2) ----
    // 1) живая (оранжевая): максимум по всему полю — окно 10x10 с наибольшим
    //    средним (интегральное изображение, устойчиво к шуму), крест на
    //    локальном максимуме пикселя внутри окна; гистерезис +0,5 °C.
    // 2) статичная (голубая): просто индикатор температуры в центре кадра —
    //    среднее окна 10x10 вокруг центра.
    // Подписи горизонтальны на экране (компенсирующий поворот +90 в XAML).
    private int _markWinX = -1, _markWinY = -1; // левый верх текущего окна живой метки
    private const int Win = 10;                 // окно сглаживания 10x10 px
    // центр кадра (центр статичной метки на сетке)
    private const int MidX = 163, MidY = 120;

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
                double v = t[tc + x - 1];
                // невалидные пиксели ядра (-273.15, см. radiometric.c) в сумму не входят:
                // окно с заглушками становится холоднее и не выигрывает поиск
                rowSum += v > -200 ? v : 0;
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

        // --- статичная метка центра: среднее 10x10 вокруг центра ---
        double tcenter = WindowMean(MidX - Win / 2, MidY - Win / 2);
        CenterTxt.Text = $"{tcenter:F1} \u00b0C";
        Canvas.SetLeft(CenterTag, MidX + 6); Canvas.SetTop(CenterTag, MidY - 24); // правее на экране

        // --- живая метка: максимум по всему полю ---
        // По данным замеров (docs/research/hotspot-empirics.md): кромки ROI
        // статично приподняты на +0,5..+1,1 °C (FF-цепочка), поэтому окна,
        // касающиеся 12-пиксельной рамки, из поиска исключаются; невалидные
        // пиксели (-273.15) уже обнулены в BuildIntegral и окно не выиграет.
        const int K = 12;
        int bx = K, by = K; double bmean = double.MinValue;
        for (int wy = K; wy <= SeekConst.H - Win - K; wy++)
            for (int wx = K; wx <= SeekConst.W - Win - K; wx++)
            {
                double m = WindowMean(wx, wy);
                if (m > bmean) { bmean = m; bx = wx; by = wy; }
            }
        if (_markWinX >= 0)
        {
            // гистерезис: перескакиваем, только если лучшее окно теплее текущего на 0,3 °C
            double curMean = WindowMean(_markWinX, _markWinY);
            if (bmean <= curMean + 0.3) { bx = _markWinX; by = _markWinY; }
        }
        _markWinX = bx; _markWinY = by;
        // локальный максимум пикселя внутри лучшего окна — точка перекрестия
        int px = bx, py = by; double vmax = double.MinValue;
        for (int ly = by; ly < by + Win; ly++)
            for (int lx = bx; lx < bx + Win; lx++)
            {
                double v = t[ly * SeekConst.W + lx];
                if (v > vmax) { vmax = v; px = lx; py = ly; }
            }
        const double arm = 9; // длина луча перекрестия
        HLine.X1 = px - arm; HLine.X2 = px + arm; HLine.Y1 = py; HLine.Y2 = py;
        VLine.X1 = px; VLine.X2 = px; VLine.Y1 = py - arm; VLine.Y2 = py + arm;
        Canvas.SetLeft(HLine, 0); Canvas.SetTop(HLine, 0);
        Canvas.SetLeft(VLine, 0); Canvas.SetTop(VLine, 0);
        Canvas.SetLeft(MarkBox, px - 4.5); Canvas.SetTop(MarkBox, py - 4.5);
        MarkTxt.Text = $"{vmax:F1} \u00b0C";
        // КАНВАС повёрнут на -90 (LayoutTransform): канвас-Y = горизонталь экрана
        // (вправо = рост Y), канвас-X = вертикаль (выше = больший X).
        // Подпись (макет ~46x12) повёрнута +90 внутри канваса: её след на канвасе
        // X:[tx+17,tx+29], Y:[ty-17,ty+29], центр (tx+23, ty+6).
        // Цель: справа от маркера, по его высоте.
        double tx = px - 23;                       // центр подписи на высоте маркера
        if (tx < 0) tx = 0; if (tx > SeekConst.W - 46) tx = SeekConst.W - 46;
        double ty = py + 8;                        // правее маркера
        if (ty + 29 > SeekConst.H) ty = py - 20;   // не влезает справа — влево
        if (ty < 0) ty = 0; if (ty > SeekConst.H - 46) ty = SeekConst.H - 46;
        Canvas.SetLeft(MarkTag, tx); Canvas.SetTop(MarkTag, ty);
    }

    private void UpdateScale(double lo, double hi)
    {
        _spanLo = lo; _spanHi = hi;
        if (_radio.Ready)
        {
            TxtLo.Text = $"{_radio.ToCelsius(lo):F1} °C";
            TxtHi.Text = $"{_radio.ToCelsius(hi):F1} °C";
            TxtMid.Text = $"{_radio.ToCelsius((lo + hi) / 2):F1}";
        }
        else
        {
            TxtLo.Text = $"{lo:F1}";
            TxtHi.Text = $"{hi:F1}";
            TxtMid.Text = $"{(lo + hi) / 2:F1}";
        }
    }

    // шкала °C: span кадра + динамические отметки мин/макс
    private double _spanLo = double.NaN, _spanHi = double.NaN;
    private void UpdateScaleTicks(int minSig, int maxSig)
    {
        double h = ScaleHost.ActualHeight;
        if (h <= 0 || double.IsNaN(_spanHi) || _spanHi <= _spanLo) return;
        double Y(double sig) => Math.Clamp((1 - (sig - _spanLo) / (_spanHi - _spanLo)) * h, 1, h - 1);
        double yMin = Y(minSig), yMax = Y(maxSig);
        TickMin.Y1 = TickMin.Y2 = yMin; TickMax.Y1 = TickMax.Y2 = yMax;
        Canvas.SetLeft(TickMin, 0); Canvas.SetLeft(TickMax, 0);
        if (_radio.Ready)
        {
            TickMinTxt.Text = $"{_radio.ToCelsius(minSig):F1}";
            TickMaxTxt.Text = $"{_radio.ToCelsius(maxSig):F1}";
        }
        Canvas.SetLeft(TickMinTxt, 22); Canvas.SetTop(TickMinTxt, Math.Clamp(yMin - 6, 0, h - 12));
        Canvas.SetLeft(TickMaxTxt, 22); Canvas.SetTop(TickMaxTxt, Math.Clamp(yMax - 6, 0, h - 12));
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
        FreezeIco.Data = (Geometry)FindResource(_frozen ? "IcoPlay" : "IcoPause");
        BtnFreeze.ToolTip = _frozen ? "Продолжить (пробел)" : "Пауза (пробел)";
    }

    // ---- FW2: запись видео (ffmpeg pipe -> H.264 mp4) ----
    private FfRecorder? _rec;
    private System.Windows.Threading.DispatcherTimer? _recTimer;
    private SnapshotMeta? _recMeta;
    private string _recDir = "", _recBase = "";

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
                    RecDot.Fill = (Brush)new SolidColorBrush(
                        System.Windows.Media.Color.FromArgb(0x55, 0xFF, 0x44, 0x44));
                    BtnRec.ToolTip = "Запись видео MP4 + радиометрический sidecar";
                    TxtRec.Text = ""; BtnRec.IsEnabled = _cam.IsOpen;
                    if (path.Length > 0 && _recMeta is not null)
                    {
                        try
                        {
                            File.WriteAllText(Path.Combine(_recDir, _recBase + ".meta.json"),
                                System.Text.Json.JsonSerializer.Serialize(_recMeta,
                                    new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
                        }
                        catch { }
                        _recMeta = null;
                    }
                    TxtStatus.Text = path.Length > 0 ? $"видео: {path}" : "видео: ошибка кодирования";
                });
            });
            return;
        }
        if (_lastFrame is null) return;
        string dir = _snapDir;
        Directory.CreateDirectory(dir);
        // FW2: лимит по свободному месту (<1 ГБ — не начинать)
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(dir)!);
            if (drive.AvailableFreeSpace < 1L << 30)
            { TxtStatus.Text = "запись: свободно < 1 ГБ — освободите место"; return; }
        }
        catch { }
        string baseName = $"IR_{DateTime.Now:yyyyMMdd_HHmmss}";
        string outPath = Path.Combine(dir, baseName + ".mp4");
        double fps = Math.Clamp(_lastFrame.Fps <= 0 ? 7 : _lastFrame.Fps, 1, 30);
        _rec = new FfRecorder();
        // sidecar радиоданных FW2: raw-сигнал LE + meta (как у снимка)
        string sidecar = Path.Combine(dir, baseName + ".sig16");
        if (!_rec.Start(outPath, fps, AppContext.BaseDirectory, sidecar))
        {
            TxtStatus.Text = "ffmpeg.exe не найден рядом с приложением";
            _rec = null; return;
        }
        _recMeta = new SnapshotMeta
        {
            Timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            Palette = CmbPalette.SelectedIndex >= 0 ? Palettes[CmbPalette.SelectedIndex].Name : "ironbow",
            SpanLo = _lastFrame.Lo, SpanHi = _lastFrame.Hi, SpanAuto = ChkAutoSpan.IsChecked == true,
            Fps = fps, CenterCelsius = _lastFrame.Temp[SeekConst.W * SeekConst.H / 2],
            MeanSignal = _lastFrame.MeanSignal,
            Smooth = (float)SldSmooth.Value, Motion = SeekConst.Motion, Spatial = SeekConst.Spatial,
            Hotmap = ResolveHotmap() ?? "",
            Emissivity = _cfg.Scene.Emissivity,
            TReflC = _cfg.Scene.TReflEqualsAir ? _cfg.Scene.TAtmC : _cfg.Scene.TReflC,
            TAtmC = _cfg.Scene.TAtmC, DistanceM = _cfg.Scene.DistanceM,
            RelHumidity = _cfg.Scene.RelHumidity,
        };
        _recDir = dir; _recBase = baseName;
        RecDot.Fill = (Brush)FindResource("CRecBrush");
        BtnRec.ToolTip = "Остановить запись";
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
        _cfg.Palette = Palettes[CmbPalette.SelectedIndex].Name;
        try { _cfg.Save(); } catch { }
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
            Emissivity = _cfg.Scene.Emissivity,
            TReflC = _cfg.Scene.TReflEqualsAir ? _cfg.Scene.TAtmC : _cfg.Scene.TReflC,
            TAtmC = _cfg.Scene.TAtmC, DistanceM = _cfg.Scene.DistanceM,
            RelHumidity = _cfg.Scene.RelHumidity,
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
            else { TxtStatus.Text = $"карта шума: рано — шторка {_hm.Collected}/30 (повторное нажатие при ≥30)"; }
            return;
        }
        _hm = new HotmapBuilder(60);
        NoiseIco.Data = (Geometry)FindResource("IcoStop");
        NoiseIco.Fill = (Brush)FindResource("CRecBrush");
        NoiseIco.Stroke = (Brush)FindResource("CRecBrush");
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
        NoiseIco.Data = (Geometry)FindResource("IcoNoise");
        NoiseIco.Fill = System.Windows.Media.Brushes.Transparent;
        NoiseIco.Stroke = (Brush)FindResource("CFgBrush");
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
        if (ok) _cam.SetGainPath(GainCachePath());
        BtnHotmap.IsEnabled = ok;
        BtnFreeze.IsEnabled = BtnSnap.IsEnabled = ok;
        BtnExportJpg.IsEnabled = BtnExportPng.IsEnabled = ok;
        BtnConnect.IsEnabled = !ok;
        SldSmooth.IsEnabled = _denReady = ok;
        if (ok) _cam.SetDenoise((float)SldSmooth.Value, SeekConst.Motion, SeekConst.Spatial, reset: true);
        if (!ok) StartRetryTimer();
        if (!ok) TxtStatus.Text = "камера не вернулась после перезапуска (пероткните USB)";
    }

    // ---- гистограмма кадра + ручной span (правая панель) ----
    // Ось X — счёт-сигнал (тонмап живёт в сигнале), подписи — °C через Radiometry.
    private WriteableBitmap? _histBmp;
    private const int HBins = 96, HV = 48;
    private double _axLo = double.NaN, _axHi = double.NaN; // ось, ед. сигнала
    private double _histDragSig0, _histCenter0;

    private void UpdateHistogram(SeekCam.Frame f)
    {
        var sig = f.Signal;
        int min = 65535, max = 0;
        for (int i = 0; i < sig.Length; i++)
        {
            ushort v = sig[i];
            if (v < min) min = v;
            if (v > max) max = v;
        }
        if (max - min < 1) max = min + 1;
        if (double.IsNaN(_axLo)) { _axLo = min; _axHi = max; }
        else // сглаживание оси, чтобы столбцы не прыгали
        {
            _axLo += (min - _axLo) * 0.25;
            _axHi += (max - _axHi) * 0.25;
        }
        Array.Clear(_hist);
        double scale = (HBins - 1e-9) / (_axHi - _axLo);
        for (int i = 0; i < sig.Length; i++)
        {
            int b = (int)((sig[i] - _axLo) * scale);
            if ((uint)b < HBins) _hist[b]++;
        }
        _histBmp ??= new WriteableBitmap(HBins, HV, 96, 96, PixelFormats.Bgr32, null);
        HistImg.Source = _histBmp;
        var px = new byte[HBins * HV * 4];
        double maxc = 1;
        for (int i = 0; i < HBins; i++) if (_hist[i] > maxc) maxc = _hist[i];
        for (int b = 0; b < HBins; b++)
        {
            int bar = (int)(Math.Sqrt(_hist[b] / maxc) * (HV - 1)); // корень — динамичнее
            for (int y = HV - bar; y < HV; y++)
            {
                int idx = (y * HBins + b) * 4;
                px[idx] = 140; px[idx + 1] = 140; px[idx + 2] = 140; px[idx + 3] = 255;
            }
        }
        _histBmp.WritePixels(new Int32Rect(0, 0, HBins, HV), px, HBins * 4, 0);
        if (_radio.Ready)
        {
            TxtFrameMin.Text = $"{_radio.ToCelsius(min):F1} °C";
            TxtFrameMax.Text = $"{_radio.ToCelsius(max):F1} °C";
        }
        UpdateScaleTicks(min, max);
        UpdateSpanOverlay();
    }

    private double SigAtX(double x) =>
        _axLo + Math.Clamp(x / Math.Max(1, HistHost.ActualWidth), 0, 1) * (_axHi - _axLo);

    private void UpdateSpanOverlay()
    {
        double w = HistHost.ActualWidth;
        if (w <= 0 || double.IsNaN(_axHi)) return;
        bool manual = ChkAutoSpan.IsChecked != true && !double.IsNaN(_histCenter);
        if (!manual)
        {
            HistMaskL.Width = 0; HistMaskR.Width = 0;
            HistSpanRect.Width = w; HistSpanRect.Margin = new Thickness(0);
            return;
        }
        double xLo = (_histCenter - _histWidth / 2 - _axLo) / (_axHi - _axLo) * w;
        double xHi = (_histCenter + _histWidth / 2 - _axLo) / (_axHi - _axLo) * w;
        xLo = Math.Clamp(xLo, 0, w); xHi = Math.Clamp(xHi, 0, w);
        HistMaskL.Width = xLo;
        HistMaskR.Width = w - xHi;
        HistSpanRect.Width = Math.Max(2, xHi - xLo);
        HistSpanRect.Margin = new Thickness(xLo, 0, 0, 0);
    }

    private void ApplyHistSpan()
    {
        if (double.IsNaN(_histCenter)) return;
        double lo = _histCenter - _histWidth / 2, hi = _histCenter + _histWidth / 2;
        _cam.SetSpanManual(true, lo, hi);
        UpdateScale(lo, hi);
        UpdateSpanOverlay();
    }

    private void OnHistDown(object sender, MouseButtonEventArgs e)
    {
        if (double.IsNaN(_axHi) || !_cam.IsOpen) return;
        _histDrag = true;
        HistHost.CaptureMouse();
        if (double.IsNaN(_histCenter)) { _histCenter = (_axLo + _axHi) / 2; _histWidth = _axHi - _axLo; }
        _histDragSig0 = SigAtX(e.GetPosition(HistHost).X);
        _histCenter0 = _histCenter;
        if (ChkAutoSpan.IsChecked == true) ChkAutoSpan.IsChecked = false; // включит manual
        ApplyHistSpan();
    }

    private void OnHistMove(object sender, MouseEventArgs e)
    {
        if (!_histDrag) return;
        _histCenter = _histCenter0 + (SigAtX(e.GetPosition(HistHost).X) - _histDragSig0);
        ApplyHistSpan();
    }

    private void OnHistUp(object sender, MouseButtonEventArgs e)
    {
        _histDrag = false;
        HistHost.ReleaseMouseCapture();
    }

    private void OnHistWheel(object sender, MouseWheelEventArgs e)
    {
        if (double.IsNaN(_axHi) || !_cam.IsOpen) return;
        if (double.IsNaN(_histCenter)) { _histCenter = (_axLo + _axHi) / 2; _histWidth = _axHi - _axLo; }
        _histWidth = Math.Clamp(_histWidth * (e.Delta < 0 ? 1.2 : 1 / 1.2), 1.0, _axHi - _axLo);
        if (ChkAutoSpan.IsChecked == true) ChkAutoSpan.IsChecked = false;
        ApplyHistSpan();
        e.Handled = true;
    }

    // ---- ручной температурный зонд: клик по кадру ----
    private void OnProbeClick(object sender, MouseButtonEventArgs e)
    {
        Point p = e.GetPosition(FrameHost); // координаты нативного кадра (поворот учтён WPF)
        if (p.X < 0 || p.Y < 0 || p.X >= SeekConst.W || p.Y >= SeekConst.H) return;
        _probeX = Math.Clamp((int)p.X, 1, SeekConst.W - 2);
        _probeY = Math.Clamp((int)p.Y, 1, SeekConst.H - 2);
        ProbeG.Visibility = Visibility.Visible;
        if (_lastFrame is not null) UpdateProbe(_lastFrame);
    }

    private void ResetProbe()
    {
        _probeX = _probeY = -1;
        ProbeG.Visibility = Visibility.Collapsed;
        LbProbeT.Text = "зонд: --";
    }

    /// <summary>Зонд живёт на сыром сигнале 3x3 (не зависит от калибровки);
    /// после фит-калибровки °C пересчитываются из сигнала — значение обновляется.</summary>
    private void UpdateProbe(SeekCam.Frame f)
    {
        if (_probeX < 0) return;
        int px = (int)_probeX, py = (int)_probeY;
        double sig = 0, t = 0; int n = 0;
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++)
            {
                int i = (py + dy) * SeekConst.W + px + dx;
                sig += f.Signal[i]; t += f.Temp[i]; n++;
            }
        sig /= n; t /= n;
        const double arm = 7;
        string probeTxt = $"{(_radio.Ready ? _radio.ToCelsius(sig) : t):F1} °C";
        LbProbeT.Text = $"зонд ({px},{py}): {probeTxt}";
        ProbeH.X1 = px - arm; ProbeH.X2 = px + arm; ProbeH.Y1 = py; ProbeH.Y2 = py;
        ProbeV.X1 = px; ProbeV.X2 = px; ProbeV.Y1 = py - arm; ProbeV.Y2 = py + arm;
        ProbeTxt.Text = probeTxt;
        // подпись в канвасе, повёрнутом на -90: как у MarkTag (справа на экране)
        double tx = Math.Clamp(px - 23, 0, SeekConst.W - 46);
        double ty = py + 8;
        if (ty + 29 > SeekConst.H) ty = py - 20;
        ty = Math.Clamp(ty, 0, SeekConst.H - 46);
        Canvas.SetLeft(ProbeTag, tx); Canvas.SetTop(ProbeTag, ty);
    }

    // ---- температурные зоны (ROI) и ΔT ----
    private sealed class Zone
    {
        public int Id;
        public string Letter = "";
        public bool Ellipse;
        public double X0, Y0, X1, Y1;        // границы в координатах кадра
        public System.Windows.Shapes.Shape Fig = null!;
        public Border Badge = null!;
        public TextBlock BadgeTxt = null!;
        public TextBlock Row = null!;        // строка статистики в панели
        public double Mean = double.NaN;
    }

    private static readonly Color[] ZoneColors =
    [
        Color.FromRgb(0x4C, 0xC2, 0xFF), Color.FromRgb(0x78, 0xD4, 0x42),
        Color.FromRgb(0xFF, 0xD0, 0x42), Color.FromRgb(0xFF, 0x78, 0x42),
        Color.FromRgb(0xE0, 0x6A, 0xFF), Color.FromRgb(0xFF, 0x5A, 0x8A),
    ];
    private readonly List<Zone> _zones = new();
    private Zone? _zoneSel;
    private int _zoneSeq;
    private bool _roiDrag;
    private double _roiAx, _roiAy;
    private System.Windows.Shapes.Shape? _roiPrev;

    private static System.Windows.Shapes.Shape MakeFig(bool ellipse, Color c, double thick)
    {
        System.Windows.Shapes.Shape s = ellipse
            ? new System.Windows.Shapes.Ellipse() : new System.Windows.Shapes.Rectangle();
        s.Stroke = new SolidColorBrush(c);
        s.StrokeThickness = thick;
        s.Fill = Brushes.Transparent;
        return s;
    }

    private static void PlaceFig(System.Windows.Shapes.Shape s, double x0, double y0, double x1, double y1)
    {
        Canvas.SetLeft(s, Math.Min(x0, x1)); Canvas.SetTop(s, Math.Min(y0, y1));
        s.Width = Math.Abs(x1 - x0); s.Height = Math.Abs(y1 - y0);
    }

    private void OnRoiToggle(object sender, RoutedEventArgs e)
    {
        RoiG.Visibility = ChkRoi.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        _cfg.ShowRoi = ChkRoi.IsChecked == true;
        _cfg.Save();
    }

    // мышь по кадру: с включёнными зонами — рисование ROI, иначе — прежний зонд
    private void OnFrameDown(object sender, MouseButtonEventArgs e)
    {
        Point p = e.GetPosition(FrameHost);
        if (ChkRoi.IsChecked != true) { OnProbeClick(sender, e); return; }
        if (p.X < 0 || p.Y < 0 || p.X >= SeekConst.W || p.Y >= SeekConst.H) return;
        _roiDrag = true; _roiAx = p.X; _roiAy = p.Y;
        FrameHost.CaptureMouse();
        _roiPrev = MakeFig(CmbRoiShape.SelectedIndex == 1, Colors.White, 0.8);
        PlaceFig(_roiPrev, p.X, p.Y, p.X, p.Y);
        RoiG.Children.Add(_roiPrev);
        e.Handled = true;
    }

    private void OnFrameMove(object sender, MouseEventArgs e)
    {
        if (!_roiDrag || _roiPrev is null) return;
        Point p = e.GetPosition(FrameHost);
        PlaceFig(_roiPrev, _roiAx, _roiAy,
                 Math.Clamp(p.X, 0, SeekConst.W), Math.Clamp(p.Y, 0, SeekConst.H));
    }

    private void OnFrameUp(object sender, MouseButtonEventArgs e)
    {
        if (!_roiDrag) return;
        _roiDrag = false;
        FrameHost.ReleaseMouseCapture();
        bool ellipse = _roiPrev is System.Windows.Shapes.Ellipse;
        if (_roiPrev is not null) RoiG.Children.Remove(_roiPrev);
        _roiPrev = null;
        Point p = e.GetPosition(FrameHost);
        double x1 = Math.Clamp(p.X, 0, SeekConst.W), y1 = Math.Clamp(p.Y, 0, SeekConst.H);
        if (Math.Abs(x1 - _roiAx) < 3 || Math.Abs(y1 - _roiAy) < 3) return; // слишком мелко
        AddZone(ellipse, Math.Min(_roiAx, x1), Math.Min(_roiAy, y1),
                Math.Max(_roiAx, x1), Math.Max(_roiAy, y1));
    }

    private void AddZone(bool ellipse, double x0, double y0, double x1, double y1)
    {
        var z = new Zone
        {
            Id = _zoneSeq,
            Letter = ((char)('A' + _zoneSeq % 26)).ToString(),
            Ellipse = ellipse,
            X0 = x0, Y0 = y0, X1 = x1, Y1 = y1,
        };
        _zoneSeq++;
        var c = ZoneColors[_zones.Count % ZoneColors.Length];
        z.Fig = MakeFig(ellipse, c, 1.0);
        PlaceFig(z.Fig, x0, y0, x1, y1);
        RoiG.Children.Add(z.Fig);
        z.BadgeTxt = new TextBlock
        {
            FontSize = 7,
            FontFamily = new FontFamily("Consolas"),
            Foreground = new SolidColorBrush(c),
        };
        z.Badge = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xCC, 0, 0, 0)),
            BorderBrush = new SolidColorBrush(c),
            BorderThickness = new Thickness(0.5),
            Padding = new Thickness(2, 0, 2, 0),
            RenderTransform = new RotateTransform(90),   // компенсация -90 канваса
            RenderTransformOrigin = new Point(0.5, 0.5),
            Child = z.BadgeTxt,
        };
        Canvas.SetLeft(z.Badge, Math.Clamp(x0, 0, SeekConst.W - 46));
        Canvas.SetTop(z.Badge, Math.Max(0, y0 - 11));
        RoiG.Children.Add(z.Badge);
        z.Row = new TextBlock
        {
            FontSize = 11,
            FontFamily = new FontFamily("Consolas"),
            Foreground = (Brush)FindResource("CFgBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            Text = $"{z.Letter}: --",
            Cursor = Cursors.Hand,
        };
        z.Row.MouseLeftButtonUp += (_, _) => SelectZone(z);
        ZoneList.Children.Add(z.Row);
        _zones.Add(z);
        SelectZone(z);
        RebuildDeltaCombos();
        if (_lastFrame is { } f) UpdateRois(f);
    }

    private void SelectZone(Zone? z)
    {
        _zoneSel = z;
        var hl = (Brush)FindResource("CBgBrush");
        foreach (var q in _zones)
        {
            q.Fig.StrokeThickness = q == z ? 1.6 : 1.0;
            q.Row.Background = q == z ? hl : Brushes.Transparent;
        }
    }

    private void DeleteSelectedZone()
    {
        if (_zoneSel is null) return;
        RoiG.Children.Remove(_zoneSel.Fig);
        RoiG.Children.Remove(_zoneSel.Badge);
        ZoneList.Children.Remove(_zoneSel.Row);
        _zones.Remove(_zoneSel);
        _zoneSel = _zones.Count > 0 ? _zones[^1] : null;
        SelectZone(_zoneSel);
        RebuildDeltaCombos();
    }

    /// <summary>Мин/макс/средн/СКО по маске зоны на радиометрическом потоке.</summary>
    private void UpdateRois(SeekCam.Frame f)
    {
        foreach (var z in _zones)
        {
            int x0 = Math.Max(0, (int)Math.Floor(z.X0)), x1 = Math.Min(SeekConst.W - 1, (int)Math.Ceiling(z.X1));
            int y0 = Math.Max(0, (int)Math.Floor(z.Y0)), y1 = Math.Min(SeekConst.H - 1, (int)Math.Ceiling(z.Y1));
            double cx = (x0 + x1) / 2.0, cy = (y0 + y1) / 2.0;
            double rx = Math.Max(0.5, (x1 - x0) / 2.0), ry = Math.Max(0.5, (y1 - y0) / 2.0);
            double mn = double.MaxValue, mx = double.MinValue, s = 0, s2 = 0; int n = 0;
            for (int y = y0; y <= y1; y++)
                for (int x = x0; x <= x1; x++)
                {
                    if (z.Ellipse)
                    {
                        double dx = (x - cx) / rx, dy = (y - cy) / ry;
                        if (dx * dx + dy * dy > 1) continue;
                    }
                    double t = f.Temp[y * SeekConst.W + x];
                    if (double.IsNaN(t)) continue;
                    if (t < mn) mn = t;
                    if (t > mx) mx = t;
                    s += t; s2 += t * t; n++;
                }
            if (n == 0) { z.Mean = double.NaN; continue; }
            double mean = s / n;
            double sd = Math.Sqrt(Math.Max(0, s2 / n - mean * mean));
            z.Mean = mean;
            z.Row.Text = $"{z.Letter}: {mean:F1} ±{sd:F1} ({mn:F1}…{mx:F1})";
            z.Row.ToolTip = $"зона {z.Letter}: n={n} · среднее {mean:F2} · СКО {sd:F2} · " +
                            $"мин {mn:F2} · макс {mx:F2} °C";
            z.BadgeTxt.Text = $"{z.Letter} {mean:F1}";
        }
        UpdateDelta();
    }

    // ---- ΔT: две зоны, зона↔кадр или зона↔опорная температура ----
    private void RebuildDeltaCombos()
    {
        string?[] keep =
        {
            (CmbDx.SelectedItem as ComboBoxItem)?.Content?.ToString(),
            (CmbDy.SelectedItem as ComboBoxItem)?.Content?.ToString(),
        };
        ComboBox[] cmb = { CmbDx, CmbDy };
        for (int k = 0; k < 2; k++)
        {
            var c = cmb[k];
            c.SelectionChanged -= OnDeltaSel;
            c.Items.Clear();
            c.Items.Add(new ComboBoxItem { Content = "—" });
            foreach (var z in _zones) c.Items.Add(new ComboBoxItem { Content = "зона " + z.Letter });
            c.Items.Add(new ComboBoxItem { Content = "макс кадра" });
            c.Items.Add(new ComboBoxItem { Content = "мин кадра" });
            c.Items.Add(new ComboBoxItem { Content = "центр" });
            if (k == 1 && ChkRef.IsChecked == true) c.Items.Add(new ComboBoxItem { Content = "опора" });
            int idx = 0;
            for (int i = 0; i < c.Items.Count; i++)
                if (((ComboBoxItem)c.Items[i]).Content?.ToString() == keep[k]) idx = i;
            c.SelectedIndex = idx;
            c.SelectionChanged += OnDeltaSel;
        }
        UpdateDelta();
    }

    private bool OpValue(string? sel, out double v)
    {
        v = double.NaN;
        if (sel is null || sel == "—") return false;
        if (sel.StartsWith("зона "))
        {
            var z = _zones.FirstOrDefault(q => "зона " + q.Letter == sel);
            if (z is null || double.IsNaN(z.Mean)) return false;
            v = z.Mean; return true;
        }
        var f = _lastFrame;
        if (f is null) return false;
        switch (sel)
        {
            case "макс кадра": v = f.Temp.Max(); return true;
            case "мин кадра": v = f.Temp.Min(); return true;
            case "центр": v = f.Temp[f.Temp.Length / 2]; return true;
            case "опора":
                return double.TryParse(TxtRef.Text.Replace(',', '.'),
                    System.Globalization.CultureInfo.InvariantCulture, out v);
        }
        return false;
    }

    private void UpdateDelta()
    {
        if (!OpValue((CmbDx.SelectedItem as ComboBoxItem)?.Content?.ToString(), out double a) ||
            !OpValue((CmbDy.SelectedItem as ComboBoxItem)?.Content?.ToString(), out double b))
        { LbDelta.Text = "ΔT: --"; return; }
        LbDelta.Text = $"ΔT = {a - b:+0.0;-0.0;0.0} °C";
    }

    private void OnDeltaSel(object sender, SelectionChangedEventArgs e) => UpdateDelta();

    private void OnRefToggle(object sender, RoutedEventArgs e)
    {
        TxtRef.IsEnabled = ChkRef.IsChecked == true;
        RebuildDeltaCombos();
    }

    private void OnRefText(object sender, TextChangedEventArgs e) => UpdateDelta();

    // ---- горячие клавиши ----
    private void OnIso(object sender, RoutedEventArgs e) { /* читается в OnFrame */ }

    private void OnGallery(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(_snapDir);
            System.Diagnostics.Process.Start("explorer.exe", _snapDir);
        }
        catch (Exception ex) { TxtStatus.Text = "галерея: " + ex.Message; }
    }

    private void OnHotKey(object sender, KeyEventArgs e)
    {
        if (Keyboard.FocusedElement is TextBox) return;
        switch (e.Key)
        {
            case Key.Space:
                if (BtnFreeze.IsEnabled) OnFreeze(this, new RoutedEventArgs());
                e.Handled = true; break;
            case Key.S when BtnSnap.IsEnabled:
                OnSnap(this, new RoutedEventArgs()); e.Handled = true; break;
            case Key.C when BtnCalib.IsEnabled:
                OnCalib(this, new RoutedEventArgs()); e.Handled = true; break;
            case Key.R when BtnReport.IsEnabled:
                OnReport(this, new RoutedEventArgs()); e.Handled = true; break;
            case Key.Delete:
                DeleteSelectedZone(); e.Handled = true; break;
            case Key.Escape:
                ResetProbe(); e.Handled = true; break;
        }
    }
}
