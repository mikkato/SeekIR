using QuestPDF.Fluent;
using QuestPDF.Infrastructure;
using QuestPDF.Helpers;

QuestPDF.Settings.License = LicenseType.Community;
string outPath = Path.Combine(Path.GetTempPath(), "seekprobe.pdf");
File.WriteAllBytes(Path.Combine(Path.GetTempPath(), "seekprobe_src.png"),
    new byte[] { 0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A }); // заведомо битый png не берём — сгенерируем нормальный
// нормальный 1x1 png base64
byte[] png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==");
try
{
    Document.Create(doc => doc.Page(page =>
    {
        page.Size(PageSizes.A4);
        page.Margin(30);
        page.DefaultTextStyle(x => x.FontSize(10));
        page.Content().Column(col =>
        {
            col.Item().Text("Тепловизионный отчёт").Bold().FontSize(16);
            col.Item().PaddingTop(8).Row(r =>
            {
                r.ConstantItem(220).Image(png).FitWidth();
                r.ConstantItem(20);
                r.RelativeItem().Column(c => c.Item().Text("Параметры съёмки").Bold());
            });
            col.Item().PaddingTop(12).Text("Заключение").Bold();
            col.Item().Text("Проверка кириллицы в PDF.");
            col.Item().PaddingTop(20).Text("Сноска мелким шрифтом.")
                .FontSize(7).FontColor(QuestPDF.Helpers.Colors.Grey.Darken1);
        });
    })).GeneratePdf(outPath);
    Console.WriteLine("OK " + new FileInfo(outPath).Length + " bytes");
}
catch (Exception ex)
{
    Console.WriteLine("FAIL: " + ex);
}
