using System.Globalization;

namespace NegiPlayer.Core;

public sealed record ListeningSettings
{
    public double Volume { get; set; } = 0.5;
    public double VolumeLimit { get; set; } = 1;
    public bool EqEnabled { get; set; }
    public double EqPreamp { get; set; } = -6;
    public double[] Gains { get; set; } = new double[10];
    public string LoudnessMode { get; set; } = "off";
    public double Headroom { get; set; }
    public bool PeakProtection { get; set; } = true;
    public string OutputID { get; set; } = "";
    public ListeningSettings Sanitized() => this with {
        VolumeLimit = Safe(VolumeLimit, 0, 1), Volume = Safe(Volume, 0, Safe(VolumeLimit, 0, 1)),
        EqPreamp = Safe(EqPreamp, -24, 0), Headroom = Safe(Headroom, 0, 24),
        Gains = Enumerable.Range(0, 10).Select(i => Safe(i < (Gains?.Length ?? 0) ? Gains![i] : 0, -12, 12)).ToArray(),
        LoudnessMode = LoudnessMode is "track" or "album" ? LoudnessMode : "off" };
    private static double Safe(double x, double low, double high) => double.IsFinite(x) ? Math.Clamp(x, low, high) : low;
}

public sealed class PcmDsp
{
    public static readonly int[] Frequencies = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    private Biquad[][] bands = [];
    private readonly object gate = new();
    private double gain = 1;
    private bool enabled;
    public void Configure(StreamInfo info, ListeningSettings raw)
    {
        info.Validate(); var settings = raw.Sanitized();
        double gainDB = -settings.Headroom;
        static double? Tag(Dictionary<string, string[]> tags, string name)
        {
            var value = tags.FirstOrDefault(x => x.Key.Equals(name, StringComparison.OrdinalIgnoreCase)).Value?.FirstOrDefault();
            if (value == null) return null;
            value = value.Trim().Replace("dB", "", StringComparison.OrdinalIgnoreCase).Trim();
            return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && double.IsFinite(n) ? n : null;
        }
        if (settings.LoudnessMode != "off")
        {
            bool album = settings.LoudnessMode == "album";
            double? rg = album ? Tag(info.Tags, "REPLAYGAIN_ALBUM_GAIN") : null;
            rg ??= Tag(info.Tags, "REPLAYGAIN_TRACK_GAIN"); gainDB += Math.Clamp(rg ?? 0, -96, 30);
            var peak = album ? Tag(info.Tags, "REPLAYGAIN_ALBUM_PEAK") : null;
            peak ??= Tag(info.Tags, "REPLAYGAIN_TRACK_PEAK");
            if (settings.PeakProtection && peak is > 0)
            {
                double eqBudget = settings.EqEnabled ? settings.EqPreamp + settings.Gains.Where(g => g > 0).Sum() : 0;
                gainDB = Math.Min(gainDB, -20 * Math.Log10(peak.Value) - eqBudget);
            }
        }
        if (settings.EqEnabled) gainDB += settings.EqPreamp;
        lock (gate)
        {
            gain = Math.Pow(10, Math.Clamp(gainDB, -180, 30) / 20); enabled = settings.EqEnabled;
            bands = Enumerable.Range(0, info.Channels).Select(_ => Frequencies.Select((f, i) =>
                new Biquad(Math.Min(f, info.SampleRate * 0.45), info.SampleRate, settings.Gains[i])).ToArray()).ToArray();
        }
    }
    public void Process(float[] samples, int channels)
    {
        lock (gate)
        {
            for (int i = 0; i < samples.Length; i++)
            {
                double x = float.IsFinite(samples[i]) ? samples[i] * gain : 0;
                if (enabled) foreach (var b in bands[i % channels]) x = b.Run(x);
                samples[i] = double.IsFinite(x) && Math.Abs(x) <= float.MaxValue ? (float)x : 0;
            }
        }
    }
    private sealed class Biquad
    {
        private readonly double b0, b1, b2, a1, a2; private double z1, z2;
        public Biquad(double f, double rate, double db)
        {
            double a = Math.Pow(10, db / 40), w = 2 * Math.PI * f / rate, alpha = Math.Sin(w) / (2 * 1.41421356);
            double a0 = 1 + alpha / a;
            b0 = (1 + alpha * a) / a0; b1 = -2 * Math.Cos(w) / a0; b2 = (1 - alpha * a) / a0;
            a1 = -2 * Math.Cos(w) / a0; a2 = (1 - alpha / a) / a0;
        }
        public double Run(double x) { double y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y; }
    }
}
