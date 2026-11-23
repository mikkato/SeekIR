using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace SeekIRWin.App;

/// <summary>Минимальный клиент OpenAI-совместимого chat/completions API
/// (подходит OpenAI, OpenRouter, Ollama /v1, vLLM, LM Studio и т.п.).
/// Vision: PNG отдаётся как data-URL в content-массиве.</summary>
public sealed class LlmClient
{
    private readonly AppConfig.LlmSection _cfg;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(180) };

    public bool Enabled => !string.IsNullOrWhiteSpace(_cfg.BaseUrl);
    public string Model => _cfg.Model;

    public LlmClient(AppConfig.LlmSection cfg) => _cfg = cfg;

    public sealed record Msg(string Role, string Text);

    private string Url => _cfg.BaseUrl.TrimEnd('/') + "/chat/completions";

    public async Task<string> ChatAsync(IEnumerable<Msg> msgs, CancellationToken ct = default)
        => await SendAsync(BuildBody(msgs, null), ct);

    /// <summary>Вопрос по термограмме: png — визуализированный кадр.</summary>
    public async Task<string> AskImageAsync(string prompt, byte[] png, CancellationToken ct = default)
        => await SendAsync(BuildBody([new Msg("user", "")], prompt, png), ct);

    private JsonElement BuildBody(IEnumerable<Msg> msgs, string? imgPrompt, byte[]? png = null)
    {
        var arr = new List<object>();
        bool first = true;
        foreach (var m in msgs)
        {
            object content = m.Text;
            if (first && png is not null && imgPrompt is not null)
            {
                content = new object[]
                {
                    new { type = "text", text = imgPrompt },
                    new { type = "image_url",
                          image_url = new { url = "data:image/png;base64," + Convert.ToBase64String(png) } },
                };
            }
            arr.Add(new { role = m.Role, content });
            first = false;
        }
        var body = new Dictionary<string, object>
        {
            ["model"] = _cfg.Model,
            ["messages"] = arr,
            ["temperature"] = 0.3,
        };
        return JsonDocument.Parse(JsonSerializer.Serialize(body)).RootElement;
    }

    private async Task<string> SendAsync(JsonElement body, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, Url);
        if (!string.IsNullOrWhiteSpace(_cfg.ApiKey))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _cfg.ApiKey);
        req.Content = new StringContent(body.GetRawText(), Encoding.UTF8, "application/json");
        using var resp = await Http.SendAsync(req, ct);
        string text = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"LLM HTTP {(int)resp.StatusCode}: {Trunc(text, 400)}");
        using var doc = JsonDocument.Parse(text);
        return doc.RootElement.GetProperty("choices")[0].GetProperty("message")
                   .GetProperty("content").GetString() ?? "";
    }

    private static string Trunc(string s, int n) => s.Length <= n ? s : s[..n] + "…";
}
