using NegiPlayer.Core;
namespace NegiPlayer.Conformance;
public sealed class FixtureLibrary(int count = 1) : IMediaLibrary
{
    private readonly byte[] pcm = Pcm.Encode(Core.Conformance.Signal());
    public static readonly byte[] Cover = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=");
    private RemoteTrack Track(int i) => new(i == 0 ? "signal-1" : $"signal-{i+1}", $"Signal {i}", "NegiPlayer Original Signal",
        "Album " + i / 10 + (count > 1 ? new string('音', 80) : ""), "album-" + i / 10, "PCM 16-bit", 48000, 4096d / 48000, i % 10 + 1, 1, true);
    public AlbumPage Albums() => new(Enumerable.Range(0, count).Select(Track).GroupBy(t => t.AlbumID)
        .Select(g => new RemoteAlbum(g.Key, g.First().Album, g.First().Artist, g.First().Id, g.Count())).ToArray(), "fixture-v1");
    public TrackPage Tracks(int offset, int limit, string query, string? album)
    {
        var all = Enumerable.Range(0, count).Select(Track).Where(t => (album == null || t.AlbumID == album) &&
            (query.Length == 0 || t.Title.Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
        return new(all.Skip(offset).Take(limit).ToArray(), all.Length, Math.Min(offset, all.Length), "fixture-v1");
    }
    private void Check(string id) { if (!Enumerable.Range(0, count).Any(i => Track(i).Id == id)) throw new HttpFailure(404); }
    public Task<StreamInfo> InfoAsync(string id, CancellationToken cancel) { Check(id); return Task.FromResult(new StreamInfo(48000, 2, 4096, new() { ["REPLAYGAIN_TRACK_GAIN"] = ["-6 dB"] })); }
    public Task<byte[]> PcmAsync(string id, ByteRange range, CancellationToken cancel) { Check(id); return Task.FromResult(pcm.AsSpan((int)range.Start, (int)range.Count).ToArray()); }
    public Task<byte[]?> ArtworkAsync(string id, CancellationToken cancel) { Check(id); return Task.FromResult<byte[]?>(Cover); }
    public Task<RemoteLyrics> LyricsAsync(string id, CancellationToken cancel) { Check(id); return Task.FromResult(Lyrics.Parse("[offset:200]\n[00:01.00]Original signal\n[00:02.00]音楽 · Music · 🌱\n")); }
}
