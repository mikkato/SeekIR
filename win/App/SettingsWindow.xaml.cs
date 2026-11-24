using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;

namespace SeekIRWin.App;

/// <summary>Явные настройки LLM: эндпоинт, API-ключ, модель; проверка связи
/// (/chat/completions) и загрузка списка моделей (/models). Сохранение —
/// сразу в AppConfig (ключ в DPAPI).</summary>
public partial class SettingsWindow : Window
{
    private readonly AppConfig _cfg;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private bool _keyVisible;

    public SettingsWindow(AppConfig cfg)
    {
        InitializeComponent();
        _cfg = cfg;
        TxtUrl.Text = cfg.Llm.BaseUrl;
        TxtKey.Password = cfg.Llm.ApiKey;
        TxtModel.Text = cfg.Llm.Model;
        Loaded += (_, _) => WindowTheme.ApplyAll(Themes.IsDark);
    }

    private string BaseUrl => TxtUrl.Text.Trim().TrimEnd('/');

    private void OnKeyEye(object sender, RoutedEventArgs e)
    {
        _keyVisible = !_keyVisible;
        BtnKeyEye.Content = _keyVisible ? "●" : "…";
        // PasswordBox скрыть/показать нельзя напрямую — перекладываем в TextBox-подмену
        if (_keyVisible)
        {
            var tb = new TextBox { Text = TxtKey.Password, Height = 26, VerticalContentAlignment = VerticalAlignment.Center };
            Grid p = (Grid)TxtKey.Parent;
            p.Children.Remove(TxtKey);
            tb.SetValue(System.Windows.Controls.Grid.ColumnProperty, 0);
            p.Children.Add(tb);
            _visibleBox = tb;
        }
        else if (_visibleBox is not null)
        {
            Grid p = (Grid)_visibleBox.Parent;
            TxtKey.Password = _visibleBox.Text;
            p.Children.Remove(_visibleBox);
            p.Children.Add(TxtKey);
            _visibleBox = null;
        }
    }
    private TextBox? _visibleBox;

    private string CurrentKey => _visibleBox is not null ? _visibleBox.Text : TxtKey.Password;

    private void ApplyFields()
    {
        _cfg.Llm.BaseUrl = BaseUrl;
        _cfg.Llm.ApiKey = CurrentKey;
        _cfg.Llm.Model = TxtModel.Text.Trim();
    }

    private async void OnFetchModels(object sender, RoutedEventArgs e)
    {
        if (BaseUrl.Length == 0) { TxtStatus.Text = "Укажите эндпоинт."; return; }
        BtnFetch.IsEnabled = false;
        TxtStatus.Text = "Запрашиваю /models…";
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, BaseUrl + "/models");
            if (CurrentKey.Length > 0)
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", CurrentKey);
            using var resp = await Http.SendAsync(req);
            string text = await resp.Content.ReadAsStringAsync();
            if (!resp.IsSuccessStatusCode)
            {
                TxtStatus.Text = $"models: HTTP {(int)resp.StatusCode} — {Trunc(text, 160)}";
                return;
            }
            using var doc = JsonDocument.Parse(text);
            var names = new List<string>();
            if (doc.RootElement.TryGetProperty("data", out var data))
                foreach (var m in data.EnumerateArray())
                    if (m.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String)
                        names.Add(id.GetString()!);
            if (names.Count == 0) { TxtStatus.Text = "Список пуст (формат /models не распознан)."; return; }
            // подсветка: список в статус + подсказка-тултип; текущее поле не трогаем
            TxtStatus.Text = "Модели: " + string.Join(", ", names);
            TxtModel.ToolTip = string.Join("\n", names);
        }
        catch (Exception ex) { TxtStatus.Text = "models: " + Trunc(ex.Message, 200); }
        finally { BtnFetch.IsEnabled = true; }
    }

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        // AUD-R2: «Тест» больше НЕ мутирует живой _cfg — тестовый клиент строится
        // из полей окна; применение — только через «ОК».
        if (BaseUrl.Length == 0) { TxtStatus.Text = "Укажите эндпоинт."; return; }
        BtnTest.IsEnabled = false;
        TxtStatus.Text = "Тестовый запрос…";
        try
        {
            var probe = new AppConfig.LlmSection
            { BaseUrl = BaseUrl, ApiKey = CurrentKey, Model = TxtModel.Text.Trim() };
            var llm = new LlmClient(probe);
            string answer = await llm.ChatAsync(new[]
            {
                new LlmClient.Msg("system", "Ответь ровно: ОК"),
                new LlmClient.Msg("user", "проверка связи"),
            });
            TxtStatus.Text = $"Связь есть. Модель «{probe.Model}» ответила: {Trunc(answer.Trim(), 120)}";
        }
        catch (Exception ex) { TxtStatus.Text = "Ошибка: " + Trunc(ex.Message, 250); }
        finally { BtnTest.IsEnabled = true; }
    }

    private void OnOk(object sender, RoutedEventArgs e)
    {
        ApplyFields();
        _cfg.Save();
        DialogResult = true;
    }

    private void OnCancel(object sender, RoutedEventArgs e) => DialogResult = false;

    private static string Trunc(string s, int n) => s.Length <= n ? s : s[..n] + "…";
}
