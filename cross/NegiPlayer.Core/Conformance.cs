using System.Security.Cryptography;
namespace NegiPlayer.Core;

/// <summary>Public, synthetic interoperability fixture. No user library or credentials in reports.</summary>
public static class Conformance
{
    public static float[] Signal(int frames = 4096)
    {
        var values = new float[frames * 2];
        for (int i = 0; i < frames; i++) { values[2 * i] = ((i % 97) - 48) * 100 / 32768f; values[2 * i + 1] = ((i % 97) - 48) * 50 / 32768f; }
        return values;
    }
    public static async Task<Dictionary<string, object>> VerifyPeerAsync(LanClient client, string code, string name, CancellationToken cancel = default)
    {
        await client.PairAsync(code, name, cancel);
        return await VerifyConnectedPeerAsync(client, cancel);
    }
    public static async Task<Dictionary<string, object>> VerifyConnectedPeerAsync(LanClient client, CancellationToken cancel = default)
    {
        var page = await client.JsonAsync<TrackPage>("/v1/tracks", cancel: cancel);
        var track = page.Tracks.Single(t => t.Id == "signal-1");
        var info = await client.JsonAsync<StreamInfo>("/v1/tracks/signal-1/stream-info", cancel: cancel); info.Validate();
        if (info.SampleRate != 48000 || info.Channels != 2 || info.Frames != 4096) throw new InvalidDataException("Unexpected fixture format.");
        byte[] expected = Pcm.Encode(Signal());
        foreach (var range in new[] { new ByteRange(0, expected.Length), new ByteRange(7, 1031), new ByteRange(16000, 1200) })
        {
            var got = await client.RangeAsync(track.Id, info, range, cancel);
            if (!got.SequenceEqual(expected.AsSpan((int)range.Start, (int)range.Count).ToArray())) throw new InvalidDataException("Source PCM differs.");
        }
        var lyrics = await client.JsonAsync<RemoteLyrics>("/v1/tracks/signal-1/lyrics", cancel: cancel);
        if (lyrics.Lines.Length != 2 || Math.Abs((lyrics.Lines[0].Time ?? -1) - 1.2) > 0.000001 || lyrics.Lines[1].Text != "音楽 · Music · 🌱") throw new InvalidDataException("LRC offset/text differs.");
        byte[] cover = await client.AssetAsync("signal-1", cancel: cancel); if (cover.Length == 0) throw new InvalidDataException("Missing fixture cover.");
        await client.ReportAsync(new("Conformance endpoint", 48000, true, false, "Original signal"), cancel);
        return new() { ["passed"] = true, ["protocolVersion"] = 1, ["sourceRate"] = 48000, ["channels"] = 2,
            ["frames"] = 4096, ["exactRanges"] = 3, ["pcmSha256"] = Convert.ToHexStringLower(SHA256.HashData(expected)),
            ["artwork"] = true, ["lrcOffsetAndUnicode"] = true, ["stateReport"] = true };
    }
}
