using System.Globalization;
using System.Windows;
using System.Windows.Controls;

namespace SeekIRWin.App;

/// <summary>Уставки радиометрии сцены (ТЗ §3): ε с пресетами материалов,
/// T_refl, T_воздух, дистанция, влажность. Значения живут в AppConfig.Scene
/// и применяются через skcap_set_scene при открытии и здесь же.</summary>
public partial class SceneWindow : Window
{
    // пресеты по ТЗ F2/§3 (CompactPRO, ~8–14 мкм)
    private static readonly (string Name, double Eps)[] Presets =
    [
        ("Кожа человека", 0.98),
        ("Вода", 0.96),
        ("Матовая краска", 0.95),
        ("Изолента ПВХ", 0.95),
        ("Бетон / кирпич", 0.95),
        ("Дерево", 0.90),
        ("Стекло (прозрачно в ИК!)", 0.87),
        ("Окисленная сталь", 0.80),
        ("Полированный металл", 0.10),
        ("Ручной ввод", -1),
    ];

    private readonly AppConfig _cfg;

    public SceneWindow(AppConfig cfg)
    {
        _cfg = cfg;
        InitializeComponent();
        CmbMat.ItemsSource = Presets.Select(p => p.Name).ToList();
        int idx = Array.FindIndex(Presets, p => p.Name == cfg.Scene.Material);
        CmbMat.SelectedIndex = idx >= 0 ? idx : Presets.Length - 1;
        TxtEps.Text = cfg.Scene.Emissivity.ToString("0.00", CultureInfo.InvariantCulture);
        ChkReflAir.IsChecked = cfg.Scene.TReflEqualsAir;
        TxtRefl.Text = cfg.Scene.TReflC.ToString("0.0", CultureInfo.InvariantCulture);
        TxtAtm.Text = cfg.Scene.TAtmC.ToString("0.0", CultureInfo.InvariantCulture);
        TxtDist.Text = cfg.Scene.DistanceM.ToString("0.0", CultureInfo.InvariantCulture);
        TxtRh.Text = cfg.Scene.RelHumidity.ToString("0", CultureInfo.InvariantCulture);
        TxtRefl.IsEnabled = !cfg.Scene.TReflEqualsAir;
    }

    private void OnMaterial(object sender, SelectionChangedEventArgs e)
    {
        if (TxtEps is null || CmbMat.SelectedIndex < 0) return;
        var (_, eps) = Presets[CmbMat.SelectedIndex];
        if (eps > 0) TxtEps.Text = eps.ToString("0.00", CultureInfo.InvariantCulture);
        else CmbMat.Focus(); // ручной ввод — не трогаем ε
    }

    private void OnReflAir(object sender, RoutedEventArgs e) =>
        TxtRefl.IsEnabled = ChkReflAir.IsChecked != true;

    private static double D(TextBox tb, double fallback) =>
        double.TryParse(tb.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : fallback;

    private void OnOk(object sender, RoutedEventArgs e)
    {
        var s = _cfg.Scene;
        s.Material = CmbMat.SelectedIndex >= 0 ? Presets[CmbMat.SelectedIndex].Name : "Ручной ввод";
        s.Emissivity = Math.Clamp(D(TxtEps, s.Emissivity), 0.01, 1.0);
        s.TReflEqualsAir = ChkReflAir.IsChecked == true;
        s.TReflC = Math.Clamp(D(TxtRefl, s.TReflC), -40, 100);
        s.TAtmC = Math.Clamp(D(TxtAtm, s.TAtmC), -40, 100);
        s.DistanceM = Math.Clamp(D(TxtDist, s.DistanceM), 0.1, 30);
        s.RelHumidity = Math.Clamp(D(TxtRh, s.RelHumidity), 0, 100);
        _cfg.Save();
        DialogResult = true;
    }
}
