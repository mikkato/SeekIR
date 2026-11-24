using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SeekIRWin.App;

/// <summary>Конфиг приложения: %APPDATA%\SeekIRWin\config.json.
/// llm.base_url — OpenAI-совместимый эндпоинт (…/v1), llm.api_key — ключ,
/// llm.model — имя модели vision-чат. Пустой base_url = LLM выключен.</summary>
public sealed class AppConfig
{
    public sealed class LlmSection
    {
        [JsonPropertyName("base_url")] public string BaseUrl { get; set; } = "";
        [JsonPropertyName("api_key")] public string ApiKey { get; set; } = "";
        [JsonPropertyName("model")] public string Model { get; set; } = "gpt-4o-mini";
    }
    public LlmSection Llm { get; set; } = new();
    public string Palette { get; set; } = "ironbow";
    // оверлеи на кадре (тумблеры в тулбаре)
    public bool ShowMarks { get; set; } = true;   // температурные метки мин/макс/центр/зонд
    public bool ShowGrid { get; set; } = true;    // сетка композиции 3×3

    public sealed class SceneSection
    {
        // радиометрия FLIR-стиля: ε, отражённая и воздух, дистанция, влажность
        public double Emissivity { get; set; } = 0.95;
        public string Material { get; set; } = "Изолента ПВХ 0.95";
        public bool TReflEqualsAir { get; set; } = true;
        public double TReflC { get; set; } = 20.0;
        public double TAtmC { get; set; } = 20.0;
        public double DistanceM { get; set; } = 1.0;
        public double RelHumidity { get; set; } = 50.0;
    }
    public SceneSection Scene { get; set; } = new();

    public static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SeekIRWin");
    public static string PathJson => Path.Combine(Dir, "config.json");

    public static AppConfig Load()
    {
        try
        {
            if (File.Exists(PathJson))
            {
                var cfg = JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(PathJson)) ?? new();
                cfg.Llm.ApiKey = Unprotect(cfg.Llm.ApiKey);
                return cfg;
            }
        }
        catch { /* битый конфиг = дефолт */ }
        return new AppConfig();
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        var copy = JsonSerializer.Deserialize<AppConfig>(JsonSerializer.Serialize(this))!;
        copy.Llm.ApiKey = Protect(copy.Llm.ApiKey);
        File.WriteAllText(PathJson,
            JsonSerializer.Serialize(copy, new JsonSerializerOptions { WriteIndented = true }));
    }

    // FW3: API-ключ в config.json хранится в DPAPI (Currentuser), префикс "dpapi:".
    // Ручной правкой открытого текста тоже можно пользоваться (без префикса).
    private const string DpapiPrefix = "dpapi:";
    private static string Protect(string plain)
    {
        if (plain.Length == 0 || plain.StartsWith(DpapiPrefix)) return plain;
        try
        {
            var b = System.Security.Cryptography.ProtectedData.Protect(
                System.Text.Encoding.UTF8.GetBytes(plain), null,
                System.Security.Cryptography.DataProtectionScope.CurrentUser);
            return DpapiPrefix + Convert.ToBase64String(b);
        }
        catch { return plain; }
    }
    private static string Unprotect(string stored)
    {
        if (!stored.StartsWith(DpapiPrefix)) return stored;
        try
        {
            var b = System.Security.Cryptography.ProtectedData.Unprotect(
                Convert.FromBase64String(stored[DpapiPrefix.Length..]), null,
                System.Security.Cryptography.DataProtectionScope.CurrentUser);
            return System.Text.Encoding.UTF8.GetString(b);
        }
        catch { return ""; }
    }
}
