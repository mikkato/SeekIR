using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using SeekIRWin.Core;

namespace SeekIRWin.App;

/// <summary>Калибровка Планка по двум опорным точкам под управлением LLM:
/// модель видит телеметрию (каждые 5 с) и выдаёт пошаговые указания —
/// какое опорное тело, как навести, когда фиксировать; после фита проверяет
/// адекватность результата (vision + числа). Указания дублируются баннером
/// прямо на термокадре.</summary>
public partial class CalibrationWindow : Window
{
    public sealed record Snap(byte[] Png, string Facts, double SigCenter, double TCenter, bool Stable);

    private readonly MainWindow _main;
    private readonly LlmClient _llm;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(5) };
    private readonly List<LlmClient.Msg> _hist = [];
    private readonly List<(double Sig, double TrueC)> _pts = [];
    private bool _busy, _done;

    public CalibrationWindow(MainWindow main, LlmClient llm)
    {
        _main = main; _llm = llm;
        InitializeComponent();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _hist.Add(new LlmClient.Msg("system", Sys));
        if (!_llm.Enabled)
        {
            TxtHint.Text = "LLM не настроен: калибруйте вручную (2 точки + «Калибровать»).";
            BtnGrab.IsEnabled = true;
            return;
        }
        BtnGrab.IsEnabled = true;
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
        if (_busy || _done || !_llm.Enabled) return;
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
                TxtStatus.Text = $"Точек: {_pts.Count}/2. Действие модели: {av.Action}.";
                if (av.Action == "grab" && av.TrueC is > -40 and < 120 && s.Stable && _pts.Count < 2)
                {
                    GrabPoint(s, av.TrueC.Value, "авто");
                    if (_pts.Count == 2) { AutoFitAndCheck(); return; }
                }
                else if (_pts.Count < 2)
                {
                    _main.SetCalibHint(av.Hint);
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
        GrabPoint(_main.CalibSnapshot(), trueC, "вручную");
        if (_llm.Enabled) Ask();
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
        string err = _main.CalibFit(_pts[0].Sig, _pts[0].TrueC, _pts[1].Sig, _pts[1].TrueC);
        BtnFit.IsEnabled = false;
        LogLine(err == null ? "Планк-коэффициенты применены и сохранены (planck.calib)." : "Фит отклонён: " + err);
        if (err == null)
        {
            BtnCheck.IsEnabled = _llm.Enabled;
            _main.SetCalibHint("Калибровка применена. Нажмите «Проверить (LLM)».");
            TxtHint.Text = "Калибровка применена. Нажмите «Проверить (LLM)».";
            return true;
        }
        return false;
    }

    /// <summary>Авто-режим: фит и проверка без нажатий.</summary>
    private void AutoFitAndCheck()
    {
        if (!FitAndGate()) return;
        _busy = false;           // освобождаем guard — CheckAsync запустится сам
        CheckAsync();
    }

    // ---- проверка адекватности ----
    private void OnCheck(object sender, RoutedEventArgs e) => CheckAsync();

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
