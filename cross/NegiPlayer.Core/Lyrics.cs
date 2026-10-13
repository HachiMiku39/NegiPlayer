using System.Globalization;
using System.Text.RegularExpressions;

namespace NegiPlayer.Core;
public static partial class Lyrics
{
    [GeneratedRegex(@"\[(\d+):(\d{1,2}(?:\.\d+)?)\]")] private static partial Regex Times();
    [GeneratedRegex(@"\[offset:([+-]?\d+)\]", RegexOptions.IgnoreCase)] private static partial Regex Offset();
    public static RemoteLyrics Parse(string text)
    {
        double offset = 0;
        var tag = Offset().Match(text);
        if (tag.Success && double.TryParse(tag.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var ms)) offset = ms / 1000;
        List<(double Time, string Text)> lines = [];
        foreach (string row in text.Replace("\r", "").Split('\n'))
        {
            var matches = Times().Matches(row); if (matches.Count == 0) continue;
            string lyric = Times().Replace(row, "").Trim();
            foreach (Match match in matches)
            {
                double seconds = double.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture);
                if (seconds >= 60) continue;
                double time = double.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) * 60 + seconds + offset;
                if (double.IsFinite(time)) lines.Add((time, lyric));
            }
        }
        return new(lines.OrderBy(x => x.Time).Take(10000).Select((x, i) => new LyricLine(i, x.Time, x.Text)).ToArray());
    }
    public static int Active(IReadOnlyList<LyricLine> lines, double position)
    {
        int result = -1;
        for (int i = 0; i < lines.Count; i++) if (lines[i].Time is { } t && t <= position) result = i;
        return result;
    }
}
