using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using SeekIRWin.Core;

namespace SeekIRWin.App;

/// <summary>Калибровка Планка по двум опорным точкам. Два явных алгоритма:
/// «Стандартный» — локальные числовые критерии (стабилизация, ΔT ≥ 10 °C,
/// проверка контакта ±2 °C), LLM не участвует; «С помощником LLM» — модель
/// видит телеметрию (каждые 5 с) и выдаёт пошаговые указания — какое опорное
/// тело, как навести; в режиме «Авто» ПРЕДЛАГАЕТ точку и температуру, но
/// фиксирует только оператор; после фита проверяет адекватность результата
/// (vision + числа). Указания дублируются баннером на термокадре.</summary>
public partial class CalibrationWindow : Window
{
    public sealed record Snap(byte[] Png, string Facts, double SigCenter, double TCenter, bool Stable);

    private readonly MainWindow _main;
    private readonly LlmClient _llm;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(5) };
    private readonly List<LlmClient.Msg> _hist = [];
    private readonly List<(double Sig, double TrueC)> _pts = [];
    private bool _busy, _done;

    // числовые критерии стандартного алгоритма (мировая практика 2-точечной
    // планк-калибровки: точки разносят минимум на 10 °C, кадр берётся только
    // на стабилизировавшемся сигнале, контрольная точка — ±2 °C к контакту)
    private const double MinDeltaT = 10.0;
    private const double VerifyTolC = 2.0;

    private bool LlmMode => RbtLlm.IsChecked == true;

    public CalibrationWindow(MainWindow main, LlmClient llm)
    {
        _main = main; _llm = llm;
        InitializeComponent();
        // «телеметрия каждые 5 с» — таймер реально опрашивает модель (раньше Tick не был назначен)
        _timer.Tick += (_, _) => Ask();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        WindowTheme.ApplyAll(Themes.IsDark);
        ApplyMode();
    }

    private void OnMode(object sender, RoutedEventArgs e)
    {
        if (!IsLoaded) return;
        ResetRun();
        ApplyMode();
    }

    private void ResetRun()
    {
        _timer.Stop();
        _pts.Clear(); _hist.Clear(); _busy = false; _done = false;
        Log.Items.Clear();
        BtnGrab.IsEnabled = true; BtnFit.IsEnabled = false; BtnCheck.IsEnabled = false;
        _main.SetCalibHint("");
    }

    private void ApplyMode()
    {
        if (!IsLoaded) return;
        if (!LlmMode)
        {
            // ---- стандартный алгоритм: всё локально, модель не вызывается ----
            ChkAuto.Visibility = Visibility.Collapsed;
            TxtAlgoNote.Text =
                "Классическая 2-точечная калибровка Планка (FLIR/Testo practice). 1) Два опорных " +
                $"тела с КОНТАКТНО измеренной температурой, ΔT ≥ {MinDeltaT:0} °C (тёплая вода " +
                "~50 °C и лёд/ледяная вода ~0 °C — самые доступные). Блестящую посуду оклейте " +
                "матовной чёрной изолентой (ε≈0.95) — на неё и наводьте. 2) Стенка/лента должна " +
                "заполнить центр кадра (голубое перекрестие) без границ и бликов; дайте показаниям " +
                "стабилизироваться (~10 с после наведения). 3) «Зафиксировать точку». 4) То же для " +
                "второго тела. 5) «Калибровать» — коэффициенты Планка применятся и сохранятся. " +
                $"6) «Проверить»: любое третье тело + его контактная температура, допуск ±{VerifyTolC:0.#} °C. " +
                "Совет: камере после включения дайте прогреться ≥ 5 мин — дрейф матрицы влияет на результат.";
            BtnCheck.IsEnabled = false;
            _main.SetCalibHint("Калибровка: стандартный режим — наведите центр на первое опорное тело.");
            TxtHint.Text = "Стандартный режим: наведите центр кадра на первое опорное тело и ждите стабилизации.";
            TxtStatus.Text = "Точек: 0/2. LLM не участвует.";
            return;
        }
        // ---- LLM-режим ----
        ChkAuto.Visibility = _llm.Enabled ? Visibility.Visible : Visibility.Collapsed;
        if (!_llm.Enabled)
        {
            TxtAlgoNote.Text = "LLM не настроен — откройте «Настройки LLM» (шестерёнка в тулбаре) " +
                               "или калибруйте стандартным алгоритмом.";
            TxtHint.Text = "LLM не настроен: выберите «Стандартный» или настройте LLM.";
            TxtStatus.Text = "LLM не настроен.";
            BtnGrab.IsEnabled = false;
            return;
        }
        TxtAlgoNote.Text =
            "Модель получает телеметрию каждые 5 с и подсказывает, что делать. «Авто» — модель " +
            "ПРЕДЛАГАЕТ точку и её температуру (лёд 0 °C, кожа лба ~34 °C), но фиксируете вы " +
            "кнопкой «Зафиксировать точку»; без «Авто» — фиксируете сами по её готовности.";
        BtnGrab.IsEnabled = true;
        _hist.Add(new LlmClient.Msg("system", Sys));
        _timer.Start();
        Ask();
    }

    private void OnClosedWin(object? sender, EventArgs e) => _timer.Stop();
    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private const string Sys =
        "Ты — эксперт по температурному контролю и ИК-термографии. Ты ведёшь оператора " +
        "через калибровку тепловизора Seek CompactPRO по двум опорным точкам (метод чёрного " +
        "тела): подбираются два стабильных объекта с известной ИСТИННОЙ температурой, " +
        "разнесённой минимум на 10 °C (например стакан тёплой воды ~50 °C и лёд/холодная " +
        "бутылка ~2 °C; человек ~36 °C как вторая точка). Оператор наводит ГОЛУБОЕ " +
        "перекрестие в центре кадра на объект; усредняется центр 10x10. " +
        "Условия пригодности кадра: объект заполняет центр кадра (без границ/отражений), " +
        "показания стабилизировались (стабилизация=да), нет бликов; для холодных тел — стёк " +
        "конденсат, для жидкостей — перемешаны, блестящая посуда закрыта тёмной тканью (ε~1). " +
        "РЕЖИМ РУКИ (по умолчанию, в кадре нет или оператор вводит trueC сам): оцени кадр и " +
        "отвечай СТРОГО JSON: {\"ready\": true|false, \"hint\": \"одно короткое действие\"}. " +
        "ready=true только когда объект пригоден для фиксации. " +
        "РЕЖИМ АВТО (в сообщении есть слово АВТО и приложен кадр): ты сама выбираешь опорные " +
        "точки по изображению, используя ТИПОВЫЕ физические температуры: тающий лёд/ледяная " +
        "вода=0 °C; кипящая вода в открытом сосуде=98-100 °C (осторожно); открытый стакан " +
        "воды комнатной температуры≈T_возд (указан в телеметрии) — слабая точка, лучше не; " +
        "голая кожа лба человека в комфорте=34±1.5 °C (не лоб в очках/с кремом/потом); " +
        "черный матовый корпус техники в комнате≈T_возд. Действуй только если центр кадра — " +
        "уверенный опорный объект И стабилизация=да; иначе жди. Отвечай СТРОГО JSON: " +
        "{\"action\": \"wait|grab\", \"trueC\": число, \"hint\": \"одно короткое указание\"}. " +
        "action=grab и trueC=твоя оценка истинной температуры только при полной уверенности в " +
        "объекте; иначе action=wait без trueC. Не выдумывай объекты, которых нет в кадре. " +
        "Пиши hint по-русски, одно действие, без рассуждений.";

    // ---- цикл указаний ----
    private async void Ask()
    {
        if (_busy || _done || !_llm.Enabled || !LlmMode) return;
        _busy = true;
        try
        {
            bool auto = ChkAuto.IsChecked == true;
            var s = _main.CalibSnapshot();
            string state = $"Точек зафиксировано: {_pts.Count}/2" +
                (_pts.Count > 0 ? " (" + string.Join("; ", _pts.Select(p => $"{p.TrueC:0.#} °C → сигнал {p.Sig:F0}")) + ")" : "") +
                $"\nТелеметрия сейчас: {s.Facts}\nЦентр: сигнал {s.SigCenter:F0}, температура {s.TCenter:F1} °C, стабилизация: {(s.Stable ? "да" : "нет")}";
            string a;
            if (auto)
            {
                _hist.Add(new LlmClient.Msg("user", state + "\nРЕЖИМ АВТО" +
                    (s.Png.Length > 0 ? " (кадр приложен)" : "")));
                a = await Task.Run(() => s.Png.Length > 0
                    ? _llm.ChatAsync(_hist, state + "\nРЕЖИМ АВТО", s.Png) : _llm.ChatAsync(_hist));
                _hist.Add(new LlmClient.Msg("assistant", a));
                var av = ParseAuto(a);
                TxtHint.Text = av.Hint;
                if (av.Action == "grab" && av.TrueC is > -40 and < 120 && s.Stable && _pts.Count < 2)
                {
                    // модель ПРЕДЛАГАЕТ точку, но калибровку фиксирует только оператор:
                    // подставляем предложенное значение в поле и ждём явного нажатия кнопки
                    TxtTrueC.Text = av.TrueC.Value.ToString("0.0", CultureInfo.InvariantCulture);
                    TxtStatus.Text = $"Точек: {_pts.Count}/2. Модель предлагает {av.TrueC.Value:F1} °C — подтвердите «Зафиксировать точку».";
                    _main.SetCalibHint(av.Hint + " Подтвердите точку кнопкой «Зафиксировать точку».");
                }
                else if (_pts.Count < 2)
                {
                    _main.SetCalibHint(av.Hint);
                    TxtStatus.Text = $"Точек: {_pts.Count}/2. Действие модели: {av.Action}.";
                }
            }
            else
            {
                _hist.Add(new LlmClient.Msg("user", state));
                a = await Task.Run(() => _llm.ChatAsync(_hist));
                _hist.Add(new LlmClient.Msg("assistant", a));
                var (hint, ready) = Parse(a);
                TxtHint.Text = hint;
                _main.SetCalibHint(_pts.Count < 2 ? hint : "Точки собраны — нажмите «Калибровать».");
                TxtStatus.Text = $"Точек: {_pts.Count}/2. Готовность к фиксации: {(ready ? "ДА" : "нет")}.";
                if (ready && _pts.Count < 2) TxtTrueC.Focus();
            }
            ChatScroll.ScrollToEnd();
        }
        catch (Exception ex) { TxtStatus.Text = "LLM: " + ex.Message; }
        finally { _busy = false; }
    }

    private static (string Action, double? TrueC, string Hint) ParseAuto(string a)
    {
        try
        {
            int i = a.IndexOf('{'), j = a.LastIndexOf('}');
            if (i >= 0 && j > i)
            {
                using var d = JsonDocument.Parse(a[i..(j + 1)]);
                var r = d.RootElement;
                string act = r.TryGetProperty("action", out var q) ? q.GetString() ?? "wait" : "wait";
                double? tc = r.TryGetProperty("trueC", out var t) && t.TryGetDouble(out var v) ? v : null;
                string hint = r.TryGetProperty("hint", out var h) ? h.GetString() ?? a : a;
                return (act, tc, hint);
            }
        }
        catch { }
        return ("wait", null, a.Trim());
    }

    private static (string Hint, bool Ready) Parse(string a)
    {
        try
        {
            int i = a.IndexOf('{'), j = a.LastIndexOf('}');
            if (i >= 0 && j > i)
            {
                using var d = JsonDocument.Parse(a[i..(j + 1)]);
                var r = d.RootElement;
                string hint = r.TryGetProperty("hint", out var h) ? h.GetString() ?? a : a;
                bool ready = r.TryGetProperty("ready", out var q) &&
                             (q.ValueKind == JsonValueKind.True ||
                              (q.ValueKind == JsonValueKind.String && q.GetString() == "true"));
                return (hint, ready);
            }
        }
        catch { }
        return (a.Trim(), false);
    }

    // ---- фиксация точек ----
    private void OnGrab(object sender, RoutedEventArgs e)
    {
        if (_pts.Count >= 2) return;
        if (!double.TryParse(TxtTrueC.Text.Replace(',', '.'), NumberStyles.Float,
                CultureInfo.InvariantCulture, out double trueC) || trueC is < -40 or > 120)
        { TxtStatus.Text = "Введите истинную температуру опорного тела (°C)."; return; }
        var snap = _main.CalibSnapshot();
        if (!LlmMode)
        {
            // стандартный алгоритм: жёсткие локальные гейты
            if (!snap.Stable)
            { TxtStatus.Text = "Сигнал не стабилизировался — держите камеру неподвижно и повторите."; return; }
            if (_pts.Count == 1 && Math.Abs(trueC - _pts[0].TrueC) < MinDeltaT)
            {
                TxtStatus.Text = $"ΔT с первой точкой {_pts[0].TrueC:F1} °C меньше {MinDeltaT:0} °C — " +
                                 "возьмите тело с заметно другой температурой.";
                return;
            }
            if (_pts.Count == 1 && (snap.SigCenter - _pts[0].Sig) * (trueC - _pts[0].TrueC) <= 0)
            {
                TxtStatus.Text = "Рассогласование: сигнал центра изменился НЕ в ту же сторону, что " +
                                 "истинная температура. Проверьте, что камера наведена на второе тело.";
                return;
            }
        }
        GrabPoint(snap, trueC, LlmMode ? "вручную" : "стандарт");
        if (LlmMode && _llm.Enabled) Ask();
    }

    private void GrabPoint(Snap s, double trueC, string how)
    {
        _pts.Add((s.SigCenter, trueC));
        LogLine($"Точка {_pts.Count} ({how}): истинная {trueC:F1} °C ↔ сигнал {s.SigCenter:F0}");
        if (_pts.Count == 1)
        {
            TxtTrueC.Text = "50.0";
            TxtStatus.Text = "Точка 1/2. Подготовьте второе тело (ΔT ≥ 10 °C).";
        }
        else
        {
            BtnGrab.IsEnabled = false;
            BtnFit.IsEnabled = true;
            TxtStatus.Text = "Точки собраны — нажмите «Калибровать».";
            _main.SetCalibHint("Точки собраны — нажмите «Калибровать».");
        }
    }

    private void OnFit(object sender, RoutedEventArgs e) => FitAndGate();

    /// <summary>Фит + включение кнопки проверки. true = применён.</summary>
    private bool FitAndGate()
    {
        if (_pts.Count != 2) return false;
        string? err = _main.CalibFit(_pts[0].Sig, _pts[0].TrueC, _pts[1].Sig, _pts[1].TrueC);
        BtnFit.IsEnabled = false;
        LogLine(err == null ? "Планк-коэффициенты применены и сохранены (planck.calib)." : "Фит отклонён: " + err);
        if (err == null)
        {
            if (!LlmMode)
            {
                // стандартный алгоритм: контрольная точка локально
                BtnCheck.IsEnabled = true;
                _main.SetCalibHint("Калибровка применена. Контроль: наведите центр на любое тело, введите контакт — «Проверить».");
                TxtHint.Text = $"Контроль: наведите центр на любое тело, введите его контактную температуру и нажмите «Проверить» (допуск ±{VerifyTolC:0.#} °C).";
                TxtStatus.Text = "Калибровка применена. Ожидание контрольной точки.";
                return true;
            }
            BtnCheck.IsEnabled = _llm.Enabled;
            _main.SetCalibHint("Калибровка применена. Нажмите «Проверить (LLM)».");
            TxtHint.Text = "Калибровка применена. Нажмите «Проверить (LLM)».";
            return true;
        }
        return false;
    }

    // ---- проверка адекватности ----
    private void OnCheck(object sender, RoutedEventArgs e)
    {
        if (LlmMode) { CheckAsync(); return; }
        // стандартный алгоритм: локальный контроль третьей точкой
        if (!double.TryParse(TxtTrueC.Text.Replace(',', '.'), NumberStyles.Float,
                CultureInfo.InvariantCulture, out double trueC) || trueC is < -40 or > 120)
        { TxtStatus.Text = "Введите контактную температуру тела в поле и повторите."; return; }
        var s = _main.CalibSnapshot();
        double dev = s.TCenter - trueC;
        string verdict = Math.Abs(dev) <= VerifyTolC
            ? $"ОК: расхождение {dev:+0.0;-0.0} °C ≤ допуска {VerifyTolC:0.#} °C."
            : $"ВНИМАНИЕ: расхождение {dev:+0.0;-0.0} °C больше допуска {VerifyTolC:0.#} °C — " +
              "проверьте ε/отражение, истинность опорных точек, повторите калибровку.";
        LogLine($"Контроль: контакт {trueC:F1} °C ↔ камера {s.TCenter:F1} °C. {verdict}");
        TxtHint.Text = verdict;
        _main.SetCalibHint(verdict);
    }

    private async void CheckAsync()
    {
        if (_busy || !_llm.Enabled) return;
        _busy = true; BtnCheck.IsEnabled = false;
        try
        {
            var s = _main.CalibSnapshot();
            string prompt =
                "Калибровка по точкам " + string.Join(" и ", _pts.Select(p => $"{p.TrueC:0.#} °C")) +
                " применена. Тот же/похожий кадр, телеметрия после калибровки: " + s.Facts +
                $"\nЦентр: {s.TCenter:F1} °C (ожидание оператора по контактному термометру: {TxtTrueC.Text} °C)." +
                "\nОцени адекватность результата (зона/распределение/числа). Ответь СТРОГО JSON без markdown: " +
                "{\"ok\": true|false, \"comment\": \"1-2 предложения на русском\"}";
            string a = await Task.Run(() => _llm.ChatAsync(
                [new LlmClient.Msg("system", CheckSys), new LlmClient.Msg("user", prompt)], prompt, s.Png));
            _done = true; _timer.Stop();
            LogLine("Проверка: " + a.Trim());
            TxtHint.Text = a.Trim();
            _main.SetCalibHint("Калибровка проверена моделью.");
        }
        catch (Exception ex) { TxtStatus.Text = "LLM: " + ex.Message; BtnCheck.IsEnabled = true; }
        finally { _busy = false; }
    }

    private const string CheckSys =
        "Ты — эксперт по температурному контролю. Проверяешь результат планк-калибровки " +
        "тепловизора по двум точкам: сопоставь числа телеметрии после калибровки с ожиданиями " +
        "для снятого объекта; аномалии — инверсия градиентов, физически невозможные значения, " +
        "несовпадение с контактным замером более чем на 2 °C. Отвечай строго JSON.";

    private void LogLine(string s)
    {
        Log.Items.Add(new TextBlock
        {
            Text = DateTime.Now.ToString("HH:mm:ss") + "  " + s,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 3, 0, 0),
            Foreground = (Brush)FindResource("CFgBrush"),
        });
        ChatScroll.ScrollToEnd();
    }
}
