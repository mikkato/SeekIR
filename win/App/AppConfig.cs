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
                return JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(PathJson)) ?? new();
        }
        catch { /* битый конфиг = дефолт */ }
        return new AppConfig();
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(PathJson,
            JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}
