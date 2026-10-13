using System.Text;
using System.Text.Json;
using NegiPlayer.Core;
using NegiPlayer.Conformance;

static void Require(bool ok, string message) { if (!ok) throw new Exception(message); }
static void Reject(Action action) { try { action(); } catch { return; } throw new Exception("Invalid input was accepted."); }
static async Task RejectAsync(Func<Task> action) { try { await action(); } catch { return; } throw new Exception("Invalid request was accepted."); }
string? Option(string key) { int i = Array.IndexOf(args, key); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }

if (args.Contains("--serve"))
{
    using var cert = LanHost.NewCertificate(); await using var host = new LanHost(new FixtureLibrary(), cert, "conformance-host", "NegiPlayer synthetic host");
    host.Start(0); string address = Option("--address") ?? "127.0.0.1";
    var data = new { baseURL = $"https://{address}:{host.Port}", fingerprint = host.Fingerprint, code = host.Pairings.Renew() };
    string path = Option("--ready") ?? throw new ArgumentException("--ready is required.");
    await File.WriteAllTextAsync(path, JsonSerializer.Serialize(data));
    if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    Console.WriteLine("Synthetic HTTPS conformance host ready.");
    await Task.Delay(TimeSpan.FromSeconds(int.Parse(Option("--seconds") ?? "240"))); return;
}
if (Option("--peer") is { } peer)
{
    using var json = JsonDocument.Parse(await File.ReadAllTextAsync(peer)); var root = json.RootElement;
    using var client = new LanClient(root.GetProperty("baseURL").GetString()!, root.GetProperty("fingerprint").GetString()!);
    var report = await NegiPlayer.Core.Conformance.VerifyPeerAsync(client, root.GetProperty("code").GetString()!, "C# conformance client");
    await client.RevokeAsync();
    await File.WriteAllTextAsync(Option("--report") ?? "conformance-client.json", JsonSerializer.Serialize(report));
    Console.WriteLine("PASS: C# client / peer host, three exact PCM ranges, artwork, LRC and state."); return;
}

int passed = 0;
void Test(string name, Action action) { action(); passed++; Console.WriteLine("PASS: " + name); }
async Task TestAsync(string name, Func<Task> action) { await action(); passed++; Console.WriteLine("PASS: " + name); }
Test("private IPv4/IPv6", () => {
    foreach (string ip in new[] { "127.0.0.1", "10.0.2.2", "172.16.0.1", "192.168.1.2", "::1", "fd11::2", "fe80::1", "::ffff:192.168.1.2" }) Require(LanProtocol.LocalAddress(System.Net.IPAddress.Parse(ip)), ip);
    foreach (string ip in new[] { "8.8.8.8", "172.32.0.1", "2001:4860::1" }) Require(!LanProtocol.LocalAddress(System.Net.IPAddress.Parse(ip)), ip);
});
Test("origin boundary", () => { foreach (string u in new[] { "http://localhost:40439", "https://example.com:443", "https://u:p@localhost:40439", "https://localhost:40439/x", "https://localhost", "https://localhost:40439?q=1" }) Reject(() => LanProtocol.BaseURL(u)); });
Test("range boundary", () => { Require(ByteRange.Parse("bytes=7-1037", 32768) == new ByteRange(7, 1031), "unaligned range");
    Require(ByteRange.Parse("bytes=-5", 100) == new ByteRange(95, 5), "suffix");
    foreach (string r in new[] { "bytes=1-0", "bytes=100-", "bytes=0-1,3-4", "bytes=-0", "bytes=+1-2", "bytes=9223372036854775808-" }) Reject(() => ByteRange.Parse(r, 100)); });
Test("HTTP framing", () => { Require(HttpRequest.Parse("GET /v1/info HTTP/1.1\r\nHost: x\r\n"u8.ToArray()) == null, "partial header");
    foreach (string s in new[] { "GET //evil HTTP/1.1\r\nHost:x\r\n\r\n", "GET /v1/info HTTP/1.1\r\nHost:x\r\nHost:y\r\n\r\n", "POST /v1/pair HTTP/1.1\r\nHost:x\r\nTransfer-Encoding:chunked\r\n\r\n", "POST /v1/pair HTTP/1.1\r\nHost:x\r\nContent-Length:4097\r\n\r\n" }) Reject(() => HttpRequest.Parse(Encoding.UTF8.GetBytes(s))); });
Test("float32 source wire", () => { var samples = new[] { 0f, .25f, -.5f, float.NaN }; var actual = Pcm.Decode(Pcm.Encode(samples), 2); Require(actual.SequenceEqual(new[] { 0f, .25f, -.5f, 0f }), "endianness/finite samples"); Reject(() => Pcm.Decode([1, 2, 3], 2)); });
Test("stream-info limits", () => { foreach (var info in new[] { new StreamInfo(0, 2, 5, []), new StreamInfo(48000, 3, 5, []), new StreamInfo(48000, 2, long.MaxValue, []), new StreamInfo(48000, 2, 0, []) }) Reject(info.Validate); });
Test("Swift JSON contract", () => { var track = new RemoteTrack("signal-1", "音楽", "Test", "Album", "album-1", "FLAC", 48000, 1, 1, 1, true);
    string text = Encoding.UTF8.GetString(WireJson.Encode(track)); Require(text.Contains("\"albumID\"") && WireJson.Decode<RemoteTrack>(WireJson.Encode(track)) == track, "camelCase wire fields"); });
Test("LRC Unicode and offset", () => { var lines = Lyrics.Parse("[offset:200]\n[00:01.00][00:02.00]音楽 · 🌱").Lines;
    Require(lines.Length == 2 && lines[0].Time == 1.2 && lines[1].Time == 2.2 && lines[0].Text == "音楽 · 🌱", "LRC timestamps"); });
Test("paired-token persistence and lock", () => { var store = new PairingStore(); var now = DateTimeOffset.UtcNow;
    var expired = store.Renew(now); Reject(() => store.Pair(new(expired, "Device"), now.AddMinutes(6)));
    var code = store.Renew(now); for (int i = 0; i < 10; i++) Reject(() => store.Pair(new("wrong", "Device"), now)); Reject(() => store.Pair(new(code, "Device"), now));
    code = store.Renew(); var pair = store.Pair(new(code, "Device")); Reject(() => store.Pair(new(code, "Device")));
    Require(!Encoding.UTF8.GetString(store.Save()).Contains(pair.Token), "plaintext token persisted"); var restored = new PairingStore(); restored.Restore(store.Save());
    Require(restored.Authorize("Bearer " + pair.Token) == pair.Device.Id, "restore"); restored.Revoke(pair.Device.Id); Require(restored.Authorize("Bearer " + pair.Token) == null, "revoke"); });
Test("DSP gain, bypass and finite values", () => { var info = new StreamInfo(48000, 2, 4096, new() { ["REPLAYGAIN_TRACK_GAIN"] = ["-6 dB"] });
    var dsp = new PcmDsp(); dsp.Configure(info, new() { LoudnessMode = "track" }); var values = Enumerable.Repeat(.01f, 200).ToArray(); dsp.Process(values, 2);
    Require(Math.Abs(values[100] / .01 - Math.Pow(10, -6d / 20)) < .00001, "gain");
    dsp.Configure(info, new() { EqEnabled = true, EqPreamp = -6, Gains = new double[10] }); values = Enumerable.Repeat(.01f, 200).ToArray(); dsp.Process(values, 2);
    Require(Math.Abs(values[100] / .01 - Math.Pow(10, -6d / 20)) < .00001, "EQ preamp"); });

await TestAsync("TLS pin, PCM, artwork/LRC, readonly and revoke", async () => {
    using var cert = LanHost.NewCertificate(); await using var host = new LanHost(new FixtureLibrary(), cert, "conformance-host", "Fixture"); host.Start(0);
    using var client = new LanClient($"https://127.0.0.1:{host.Port}", host.Fingerprint);
    await RejectAsync(async () => await client.JsonAsync<ServerInfo>("/v1/info"));
    await NegiPlayer.Core.Conformance.VerifyPeerAsync(client, host.Pairings.Renew(), "Test");
    using var wrong = new LanClient(client.BaseURL.AbsoluteUri, new string('0', 64));
    await RejectAsync(async () => await wrong.JsonAsync<ServerInfo>("/v1/info"));
    await RejectAsync(async () => await client.SendAsync("/v1/tracks", "POST"));
    await RejectAsync(async () => await client.SendAsync("/v1/tracks/signal-1/stream", range: new(0, 300000)));
    Require(host.Outputs.Values.Single().EqEnabled, "device state");
    await client.RevokeAsync(); await RejectAsync(async () => await client.JsonAsync<ServerInfo>("/v1/info"));
});
await TestAsync("large TLS response and pagination", async () => {
    using var cert = LanHost.NewCertificate(); await using var host = new LanHost(new FixtureLibrary(14000), cert, "large-host", "Fixture"); host.Start(0);
    using var client = new LanClient($"https://127.0.0.1:{host.Port}", host.Fingerprint); await client.PairAsync(host.Pairings.Renew(), "Test");
    for (int i = 0; i < 3; i++) { var albums = await client.JsonAsync<AlbumPage>("/v1/albums"); Require(albums.Albums.Length == 1400, "large albums");
        var tracks = await client.JsonAsync<TrackPage>("/v1/tracks?offset=13500&limit=500"); Require(tracks.Tracks.Length == 500 && tracks.Total == 14000, "large tracks"); }
});
Console.WriteLine($"PASS: {passed} conformance groups. Hardware playback is not part of this portable test.");
