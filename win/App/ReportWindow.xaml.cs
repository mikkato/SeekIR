using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;
using SeekIRWin.Core;

namespace SeekIRWin.App;

/// <summary>Чат-интервью по термограмме (ТЗ F4/F5): первый ход — анализ кадра
/// vision-моделью, дальше модель задаёт уточняющие вопросы, ответы идут в чат.
/// «Отчёт в PDF» собирает снимок + Q+A + вывод в QuestPDF-документ.</summary>
public partial class ReportWindow : Window
{
    private readonly LlmClient _llm;
    private readonly byte[] _png;          // визуализация кадра (повёрнутая)
    private readonly string _facts;        // телеметрия кадра для контекста
    private readonly DateTime _shotAt;
    private readonly List<LlmClient.Msg> _hist = [];
    private bool _busy;

    public ReportWindow(LlmClient llm, byte[] png, string facts)
    {
        QuestPDF.Settings.License = QuestPDF.Infrastructure.LicenseType.Community;
        _llm = llm; _png = png; _facts = facts; _shotAt = DateTime.Now;
        InitializeComponent();
        if (!_llm.Enabled)
            TxtStatus.Text = "LLM не настроен (config.json → llm.base_url)";
        BtnSend.IsEnabled = _llm.Enabled;
        TxtInput.Focus();
    }

    private void Append(string who, string text)
    {
        Chat.Items.Add(new TextBlock
        {
            Text = who + ": " + text,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 3, 0, 0),
            Foreground = (Brush)FindResource(who == "Вы" ? "CFgBrush" : "CAccentBrush"),
        });
        ChatScroll.ScrollToEnd();
    }

    /// <summary>Системная роль: эксперт по температурному контролю.</summary>
    public const string SystemPrompt =
        "Ты — эксперт по температурному контролю и инфракрасной термографии с опытом " +
        "энергоаудитов и диагностики промышленного оборудования (ГОСТ Р 55472, серия ISO 6781). " +
        "Ты работаешь с термограммой тепловизора Seek CompactPRO (320x240, палитра ironbow: " +
        "холодное — фиолетово-синее, горячее — жёлто-белое) и радиометрической телеметрией съёмки. " +
        "Правила: опирайся только на видимые тепловые зоны и переданные числа; не выдумывай " +
        "температуры, которых нет в кадре; помни, что абсолютные значения могут иметь смещение " +
        "до ±5 °C без калибровки по чёрному телу, а низкая эмиссивность блестящих поверхностей " +
        "искажает замер; различай собственный нагрев объекта и отражённое излучение. " +
        "Формулируй выводы как специалист: зона, характер (штатный/аномальный), вероятная причина, " +
        "риск, рекомендация. Отвечай по-русски, без markdown, кратко и по делу.";

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (!_llm.Enabled) return;
        BtnSend.IsEnabled = false;
        try
        {
            string task =
                "Пользователь прислал термограмму и телеметрию. Дай краткое заключение по изображению " +
                "(что горячее/холоднее, аномалии, границы зон), затем задай ОДИН уточняющий вопрос " +
                "для отчёта (объект съёмки, цель, что проверить).";
            string prompt = task + "\n\nТелеметрия: " + _facts +
                "\nВсе температуры на изображении могут иметь систематическое смещение (без калибровки по чёрному телу ±5 °C).";
            _hist.Add(new LlmClient.Msg("system", SystemPrompt));
            _hist.Add(new LlmClient.Msg("user", prompt));
            string a = await Task.Run(() => _llm.ChatAsync(_hist, prompt, _png));
            _hist.Add(new LlmClient.Msg("assistant", a));
            Append("Агент", a);
        }
        catch (Exception ex) { TxtStatus.Text = "LLM: " + ex.Message; }
        finally { BtnSend.IsEnabled = _llm.Enabled; }
    }

    private async void OnSend(object sender, RoutedEventArgs e) => await Send();
    private void OnKey(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Enter && !TxtInput.Text.Contains('\n')) { Send(); e.Handled = true; }
    }

    private async Task Send()
    {
        string text = TxtInput.Text.Trim();
        if (text.Length == 0 || _busy || !_llm.Enabled) return;
        _busy = true; BtnSend.IsEnabled = false;
        TxtInput.Clear();
        Append("Вы", text);
        _hist.Add(new LlmClient.Msg("user", text));
        try
        {
            string a = await Task.Run(() => _llm.ChatAsync(_hist));
            _hist.Add(new LlmClient.Msg("assistant", a));
            Append("Агент", a);
        }
        catch (Exception ex) { TxtStatus.Text = "LLM: " + ex.Message; }
        finally { _busy = false; BtnSend.IsEnabled = true; TxtInput.Focus(); }
    }

    private void OnPdf(object sender, RoutedEventArgs e)
    {
        try
        {
            string outPath = Path.Combine(_snapDir(), $"Отчёт_{_shotAt:yyyyMMdd_HHmmss}.pdf");
            // пары «вопрос модели -> ответ пользователя»
            var pairs = new List<(string Q, string A)>();
            for (int i = 0; i < _hist.Count - 1; i++)
                if (_hist[i].Role == "assistant" && _hist[i + 1].Role == "user" &&
                    !_hist[i + 1].Text.StartsWith("Пользователь прислал термограмму"))
                    pairs.Add((TailQuestion(_hist[i].Text), _hist[i + 1].Text));
            string conclusion = _hist.LastOrDefault(m => m.Role == "assistant")?.Text ?? "";
            byte[] png = _png;
            DateTime at = _shotAt; string facts = _facts;
            Task.Run(() =>
            {
                Document.Create(doc => doc.Page(page =>
                {
                    page.Size(PageSizes.A4);
                    page.Margin(30);
                    page.DefaultTextStyle(x => x.FontSize(10));
                    page.Content().Column(col =>
                    {
                        col.Item().Text("Тепловизионный отчёт").Bold().FontSize(16);
                        col.Item().Text($"Дата: {at:dd.MM.yyyy HH:mm}").FontSize(9);
                        col.Item().PaddingTop(8).Row(r =>
                        {
                            r.ConstantItem(220).Image(png).FitWidth();
                            r.ConstantItem(20);
                            r.RelativeItem().Column(c =>
                            {
                                c.Item().Text("Параметры съёмки").Bold();
                                foreach (var line in facts.Split('\n'))
                                    c.Item().Text(line).FontSize(8);
                            });
                        });
                        if (pairs.Count > 0)
                        {
                            col.Item().PaddingTop(12).Text("Интервью").Bold();
                            foreach (var (q, a) in pairs)
                            {
                                col.Item().PaddingTop(6).Text(q).SemiBold();
                                col.Item().Text(a);
                            }
                        }
                        col.Item().PaddingTop(12).Text("Заключение").Bold();
                        col.Item().Text(conclusion);
                        col.Item().PaddingTop(20).Text(
                            "Температуры даны без калибровки по чёрному телу (возможное смещение до ±5 °C). " +
                            "Экспертиза носит ориентировочный характер.")
                            .FontSize(7).FontColor(QuestPDF.Helpers.Colors.Grey.Darken1);
                    });
                })).GeneratePdf(outPath);
            }).ContinueWith(t => Dispatcher.Invoke(() =>
            {
                TxtStatus.Text = t.IsFaulted ? "PDF: " + t.Exception?.GetBaseException().Message : "отчёт: " + outPath;
            }), TaskScheduler.Default);
        }
        catch (Exception ex) { TxtStatus.Text = "PDF: " + ex.Message; }
    }

    private static string TailQuestion(string assistantText)
    {
        // последний вопросительный «хвост» ответа модели
        int q = assistantText.LastIndexOf('?');
        if (q < 0) return assistantText;
        int start = assistantText.LastIndexOfAny(new[] { '\n', '.' }, q);
        return assistantText.Substring(Math.Max(start + 1, 0), q - Math.Max(start + 1, 0) + 1).Trim();
    }

    private static string _snapDir() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Термография");

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();
}
