using System.Security.Cryptography;
using System.Text;
using NAudio.Wave;
using NegiPlayer.Core;

namespace NegiPlayer.WindowsAudio;

public sealed class WindowsLibrary : IMediaLibrary
{
    private sealed record Entry(RemoteTrack Track, string Root, string Path, long Size, DateTime Modified);
    private Entry[] entries = []; private string revision = Guid.NewGuid().ToString("N");
    public int Count => entries.Length;
    public async Task ScanAsync(IEnumerable<string> roots, CancellationToken cancel = default)
    {
        var found = await Task.Run(() =>
        {
            List<Entry> result = [];
            foreach (string selected in roots.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                string root = Path.GetFullPath(selected); if (!Directory.Exists(root) || Reparse(root)) continue;
                var folders = new Stack<string>(); folders.Push(root);
                while (folders.Count > 0 && result.Count < 100000)
                {
                    cancel.ThrowIfCancellationRequested(); string folder = folders.Pop(); string[] children;
                    try { children = Directory.GetFileSystemEntries(folder); } catch (IOException) { continue; } catch (UnauthorizedAccessException) { continue; }
                    foreach (string path in children)
                    {
                        cancel.ThrowIfCancellationRequested();
                        try { if (Reparse(path)) continue; } catch (IOException) { continue; } catch (UnauthorizedAccessException) { continue; }
                        if (Directory.Exists(path)) { folders.Push(path); continue; }
                        if (!new[] { ".wav", ".flac", ".mp3", ".m4a", ".aac", ".aiff", ".aif" }.Contains(Path.GetExtension(path).ToLowerInvariant())) continue;
                        try
                        {
                            using var tags = TagLib.File.Create(new ReadOnlyTags(path));
                            using var pcm = new AudioFileReader(path);
                            var t = tags.Tag; var p = pcm.WaveFormat;
                            string album = string.IsNullOrWhiteSpace(t.Album) ? "" : t.Album;
                            string artist = string.Join(" · ", t.Performers ?? []);
                            string id = Stable(root + "\0" + Path.GetRelativePath(root, path)), albumID = Stable(root + "\0" + Path.GetDirectoryName(path) + "\0" + album + "\0" + (t.FirstAlbumArtist ?? artist));
                            var track = new RemoteTrack(id, string.IsNullOrWhiteSpace(t.Title) ? Path.GetFileNameWithoutExtension(path) : t.Title,
                                artist, album, albumID, Path.GetExtension(path).TrimStart('.').ToUpperInvariant(), p.SampleRate,
                                pcm.Length / (double)p.AverageBytesPerSecond, (int)Math.Min(t.Track, int.MaxValue), (int)Math.Min(t.Disc, int.MaxValue),
                                p.Channels is 1 or 2 && p.SampleRate is >= 8000 and <= 384000);
                            var f = new FileInfo(path); result.Add(new(track, root, path, f.Length, f.LastWriteTimeUtc));
                        }
                        catch (Exception e) when (e is IOException or UnauthorizedAccessException or TagLib.CorruptFileException or TagLib.UnsupportedFormatException or System.Runtime.InteropServices.COMException) { }
                    }
                }
            }
            return result.OrderBy(e => e.Track.Album).ThenBy(e => e.Track.DiscNumber).ThenBy(e => e.Track.TrackNumber).ThenBy(e => e.Track.Title).ToArray();
        }, cancel);
        entries = found; revision = Guid.NewGuid().ToString("N");
    }
    private static string Stable(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value.Normalize(NormalizationForm.FormC))));
    private static bool Reparse(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    private Entry Resolve(string id)
    {
        var entry = entries.FirstOrDefault(e => e.Track.Id == id) ?? throw new HttpFailure(404);
        string path = Path.GetFullPath(entry.Path), root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(entry.Root));
        if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new HttpFailure(404);
        for (string? p = path; p != null && p.Length >= root.Length; p = Path.GetDirectoryName(p)) if (Reparse(p)) throw new HttpFailure(404);
        var f = new FileInfo(path);
        if (!f.Exists || f.Length != entry.Size || f.LastWriteTimeUtc != entry.Modified) throw new HttpFailure(503);
        return entry;
    }
    public AlbumPage Albums() => new(entries.GroupBy(e => e.Track.AlbumID).Select(g => new RemoteAlbum(g.Key,
        g.First().Track.Album, g.First().Track.Artist, g.First().Track.Id, g.Count())).OrderBy(a => a.Title).ToArray(), revision);
    public TrackPage Tracks(int offset, int limit, string query, string? album)
    {
        var matches = entries.Select(e => e.Track).Where(t => (album == null || t.AlbumID == album) &&
            (query.Length == 0 || (t.Title + " " + t.Artist + " " + t.Album).Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
        return new(matches.Skip(offset).Take(limit).ToArray(), matches.Length, Math.Min(offset, matches.Length), revision);
    }
    public Task<StreamInfo> InfoAsync(string id, CancellationToken cancel) => Task.Run(() =>
    {
        var e = Resolve(id); if (!e.Track.Playable) throw new HttpFailure(415);
        using var pcm = new AudioFileReader(e.Path); using var tags = TagLib.File.Create(new ReadOnlyTags(e.Path));
        var info = new StreamInfo(pcm.WaveFormat.SampleRate, pcm.WaveFormat.Channels, pcm.Length / pcm.WaveFormat.BlockAlign, ReplayGain(tags));
        info.Validate(); return info;
    }, cancel);
    public Task<byte[]> PcmAsync(string id, ByteRange range, CancellationToken cancel) => Task.Run(() =>
    {
        var e = Resolve(id); using var pcm = new AudioFileReader(e.Path); int frameBytes = pcm.WaveFormat.BlockAlign;
        long first = range.Start / frameBytes; int skip = (int)(range.Start % frameBytes);
        int samples = (int)((range.Count + skip + frameBytes - 1) / frameBytes) * pcm.WaveFormat.Channels;
        pcm.Position = first * frameBytes; var floats = new float[samples]; int read = 0;
        while (read < samples) { cancel.ThrowIfCancellationRequested(); int n = pcm.Read(floats, read, samples - read); if (n == 0) break; read += n; }
        byte[] bytes = Pcm.Encode(floats); if (read * 4 < skip + range.Count) throw new HttpFailure(503);
        return bytes.AsSpan(skip, checked((int)range.Count)).ToArray();
    }, cancel);
    private static Dictionary<string, string[]> ReplayGain(TagLib.File file)
    {
        Dictionary<string, string[]> tags = [];
        if (file.GetTag(TagLib.TagTypes.Xiph) is TagLib.Ogg.XiphComment xiph)
            foreach (string key in new[] { "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_ALBUM_PEAK" })
            { var values = xiph.GetField(key); if (values.Length > 0) tags[key] = values; }
        return tags;
    }
    public Task<byte[]?> ArtworkAsync(string id, CancellationToken cancel) => Task.Run(() =>
    {
        var e = Resolve(id); using var tags = TagLib.File.Create(new ReadOnlyTags(e.Path));
        var picture = tags.Tag.Pictures.FirstOrDefault(p => p.Type == TagLib.PictureType.FrontCover) ?? tags.Tag.Pictures.FirstOrDefault();
        if (picture?.Data.Count is > 0 and <= 8_000_000) return picture.Data.Data;
        var folder = Path.GetDirectoryName(e.Path)!;
        var candidates = Directory.GetFiles(folder).Where(p => new[] { ".png", ".jpg", ".jpeg", ".webp" }.Contains(Path.GetExtension(p).ToLowerInvariant()))
            .OrderBy(p => new[] { "cover", "folder", "front", "album", "artwork" }.Contains(Path.GetFileNameWithoutExtension(p).ToLowerInvariant()) ? 0 : 1).ThenBy(p => p);
        foreach (var path in candidates) if (!Reparse(path) && new FileInfo(path).Length is > 0 and <= 8_000_000) return File.ReadAllBytes(path);
        return null;
    }, cancel);
    public Task<RemoteLyrics> LyricsAsync(string id, CancellationToken cancel) => Task.Run(() =>
    {
        var e = Resolve(id); string sidecar = Path.ChangeExtension(e.Path, ".lrc");
        if (!File.Exists(sidecar) || Reparse(sidecar) || new FileInfo(sidecar).Length > 1_000_000) return new RemoteLyrics([]);
        return Lyrics.Parse(File.ReadAllText(sidecar, Encoding.UTF8));
    }, cancel);
    private sealed class ReadOnlyTags(string path) : TagLib.File.IFileAbstraction
    {
        public string Name => path;
        public Stream ReadStream => new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        public Stream WriteStream => throw new NotSupportedException("NegiPlayer imports references without writing source tags.");
        public void CloseStream(Stream stream) => stream.Dispose();
    }
}
