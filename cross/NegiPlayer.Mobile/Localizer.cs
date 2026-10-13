using System.Text.Json;
namespace NegiPlayer.Mobile;
public static class Localizer
{
    private static JsonDocument? strings;
    public static string Language { get; set; } = Preferences.Get("language", "zh");
    public static async Task InitializeAsync()
    {
        using var input = await FileSystem.OpenAppPackageFileAsync("PlayerStrings.json");
        strings = await JsonDocument.ParseAsync(input);
    }
    public static string L(string text) => Language != "zh" && strings != null &&
        strings.RootElement.TryGetProperty(text, out var value) && value.TryGetProperty(Language, out var translation)
        ? translation.GetString() ?? text : text;
}
