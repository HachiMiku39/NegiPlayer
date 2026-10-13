using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NegiPlayer.Core;
using NegiPlayer.WindowsAudio;

string root = Path.Combine(Path.GetTempPath(), "NegiPlayer-Windows-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    string path = Path.Combine(root, "Signal.wav");
    using (var f = new BinaryWriter(File.Create(path)))
    {
        f.Write("RIFF"u8); f.Write(4096 * 4 + 36); f.Write("WAVEfmt "u8); f.Write(16); f.Write((short)1); f.Write((short)2);
        f.Write(48000); f.Write(192000); f.Write((short)4); f.Write((short)16); f.Write("data"u8); f.Write(4096 * 4);
        for (int i = 0; i < 4096; i++) { f.Write((short)(((i % 97) - 48) * 100)); f.Write((short)(((i % 97) - 48) * 50)); }
    }
    await File.WriteAllTextAsync(Path.ChangeExtension(path, ".lrc"), "[offset:200]\n[00:01.00]Original signal\n[00:02.00]音楽 · Music · 🌱");
    byte[] before = SHA256.HashData(await File.ReadAllBytesAsync(path));
    var library = new WindowsLibrary(); await library.ScanAsync([root]);
    var track = library.Tracks(0, 200, "", null).Tracks.Single();
    var info = await library.InfoAsync(track.Id, default);
    if (info.SampleRate != 48000 || info.Channels != 2 || info.Frames != 4096) throw new Exception("Windows PCM metadata differs.");
    byte[] expected = Pcm.Encode(Conformance.Signal());
    foreach (var range in new[] { new ByteRange(0, 32768), new ByteRange(7, 1031), new ByteRange(16000, 1200) })
    {
        var actual = await library.PcmAsync(track.Id, range, default);
        if (!actual.SequenceEqual(expected.AsSpan((int)range.Start, (int)range.Count).ToArray())) throw new Exception("Windows decoded PCM range differs.");
    }
    var lyrics = await library.LyricsAsync(track.Id, default);
    if (lyrics.Lines[0].Time != 1.2 || lyrics.Lines[1].Text != "音楽 · Music · 🌱") throw new Exception("Windows LRC differs.");
    byte[] after = SHA256.HashData(await File.ReadAllBytesAsync(path));
    if (!before.SequenceEqual(after)) throw new Exception("Source file changed.");
    await File.WriteAllTextAsync(path, "changed");
    try { await library.InfoAsync(track.Id, default); throw new Exception("Changed source accepted."); }
    catch (HttpFailure e) when (e.Status == 503) { }
    Console.WriteLine("PASS: Windows WAV decoder, exact unaligned PCM ranges, LRC, read-only source and stale-source rejection.");
    Console.WriteLine("Hardware WASAPI/USB playback is not measured by this hosted runner.");
}
finally { Directory.Delete(root, true); }
