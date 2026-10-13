using System.Collections.Concurrent;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json.Serialization;

namespace NegiPlayer.Core;

public interface IMediaLibrary
{
    AlbumPage Albums();
    TrackPage Tracks(int offset, int limit, string query, string? album);
    Task<StreamInfo> InfoAsync(string id, CancellationToken cancel);
    Task<byte[]> PcmAsync(string id, ByteRange range, CancellationToken cancel);
    Task<byte[]?> ArtworkAsync(string id, CancellationToken cancel);
    Task<RemoteLyrics> LyricsAsync(string id, CancellationToken cancel);
}
public sealed record SavedPair(string Id, string Name, string TokenHash);

public sealed class PairingStore
{
    private readonly object gate = new();
    private readonly Dictionary<string, SavedPair> pairs = [];
    private string? code; private DateTimeOffset expires; private int failures;
    public string Renew(DateTimeOffset? now = null)
    {
        lock (gate) { code = RandomNumberGenerator.GetInt32(100000000).ToString("D8");
            expires = (now ?? DateTimeOffset.UtcNow).AddMinutes(5); failures = 0; return code; }
    }
    public void Close() { lock (gate) code = null; }
    public (string Token, SavedPair Device) Pair(PairRequest request, DateTimeOffset? now = null)
    {
        lock (gate)
        {
            if (code == null || failures >= 10 || (now ?? DateTimeOffset.UtcNow) >= expires)
                throw new HttpFailure(403);
            if (request.Code != code) { failures++; throw new HttpFailure(403); }
            code = null;
            string token = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
            string name = new((request.DeviceName ?? "Endpoint").Where(c => !char.IsControl(c)).Take(120).ToArray());
            var saved = new SavedPair(Guid.NewGuid().ToString("N"), name,
                Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(token))));
            pairs[saved.Id] = saved; return (token, saved);
        }
    }
    public string? Authorize(string? header)
    {
        if (header == null || !header.StartsWith("Bearer ") || header.Length > 512) return null;
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(header[7..]));
        lock (gate) return pairs.Values.FirstOrDefault(p =>
            CryptographicOperations.FixedTimeEquals(Convert.FromHexString(p.TokenHash), hash))?.Id;
    }
    public SavedPair[] Snapshot() { lock (gate) return pairs.Values.ToArray(); }
    public void Revoke(string id) { lock (gate) pairs.Remove(id); }
    public byte[] Save() => WireJson.Encode(Snapshot());
    public void Restore(byte[] bytes)
    {
        var saved = WireJson.Decode<SavedPair[]>(bytes);
        if (saved.Length > 128 || saved.Any(p => !LanProtocol.ValidID(p.Id) || !LanProtocol.ValidFingerprint(p.TokenHash)))
            throw new InvalidDataException("Invalid paired-device store.");
        lock (gate) { pairs.Clear(); foreach (var p in saved) pairs[p.Id] = p; }
    }
}

public sealed record HttpRequest(string Method, string Target, Dictionary<string, string> Headers, byte[] Body)
{
    public static HttpRequest? Parse(byte[] bytes)
    {
        int end = bytes.AsSpan().IndexOf("\r\n\r\n"u8);
        if (end < 0) { if (bytes.Length > 32768) throw new HttpFailure(431); return null; }
        if (end > 32768) throw new HttpFailure(431);
        var rows = Encoding.UTF8.GetString(bytes, 0, end).Split("\r\n");
        var start = rows[0].Split(' ');
        if (start.Length != 3 || start[2] != "HTTP/1.1" || start[0] is not ("GET" or "HEAD" or "POST" or "DELETE") ||
            !start[1].StartsWith('/') || start[1].StartsWith("//") || start[1].Contains('#')) throw new HttpFailure(400);
        Dictionary<string, string> headers = new(StringComparer.OrdinalIgnoreCase);
        foreach (string row in rows.Skip(1))
        {
            int colon = row.IndexOf(':'); if (colon <= 0) throw new HttpFailure(400);
            string key = row[..colon], value = row[(colon + 1)..].Trim(' ', '\t');
            if (!key.All(c => char.IsAsciiLetterOrDigit(c) || c == '-') ||
                value.Any(c => c < 32 || c == 127) || !headers.TryAdd(key, value)) throw new HttpFailure(400);
        }
        if (!headers.ContainsKey("Host") || headers.ContainsKey("Transfer-Encoding")) throw new HttpFailure(400);
        int length = 0;
        if (headers.TryGetValue("Content-Length", out var raw) &&
            (raw.Length == 0 || !raw.All(char.IsAsciiDigit) || !int.TryParse(raw, out length) || length > 4096))
            throw new HttpFailure(413);
        if (bytes.Length < end + 4 + length) return null;
        if (bytes.Length != end + 4 + length) throw new HttpFailure(400);
        return new(start[0], start[1], headers, bytes[(end + 4)..]);
    }
}

public sealed class LanHost : IAsyncDisposable
{
    private readonly IMediaLibrary library;
    private readonly X509Certificate2 certificate;
    private readonly SemaphoreSlim clients = new(24);
    private readonly ConcurrentDictionary<long, TcpClient> active = new();
    private readonly ConcurrentDictionary<long, string> owners = new();
    private CancellationTokenSource? lifetime; private TcpListener? listener; private Task? accept;
    private long counter;
    public string ServerID { get; }
    public string Name { get; }
    public string Fingerprint => LanProtocol.Fingerprint(certificate.RawData);
    public int Port { get; private set; }
    public PairingStore Pairings { get; } = new();
    public ConcurrentDictionary<string, DeviceState> Outputs { get; } = new();
    public Func<byte[], Task>? PersistPairings { get; set; }
    public async Task RevokeAsync(string device, long exceptConnection = -1)
    {
        Pairings.Revoke(device); Outputs.TryRemove(device, out _);
        foreach (var c in owners.Where(c => c.Value == device && c.Key != exceptConnection))
            if (active.TryGetValue(c.Key, out var tcp)) tcp.Dispose();
        if (PersistPairings != null) await PersistPairings(Pairings.Save());
    }
    public LanHost(IMediaLibrary library, X509Certificate2 certificate, string serverID, string name)
    {
        if (!certificate.HasPrivateKey || !LanProtocol.ValidID(serverID)) throw new ArgumentException("Invalid host identity.");
        this.library = library; this.certificate = certificate; ServerID = serverID; Name = name;
    }
    public static X509Certificate2 NewCertificate()
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=NegiPlayer LAN", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        using var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(5));
        return X509CertificateLoader.LoadPkcs12(cert.Export(X509ContentType.Pfx), null);
    }
    public void Start(int port = 40439, bool loopbackOnly = false)
    {
        if (lifetime != null) return;
        lifetime = new(); listener = new TcpListener(loopbackOnly ? IPAddress.Loopback : IPAddress.IPv6Any, port);
        if (!loopbackOnly) listener.Server.DualMode = true;
        listener.Start(24);
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        accept = AcceptAsync(lifetime.Token);
    }
    private async Task AcceptAsync(CancellationToken cancel)
    {
        try {
            while (!cancel.IsCancellationRequested)
            {
                var client = await listener!.AcceptTcpClientAsync(cancel);
                if (client.Client.RemoteEndPoint is not IPEndPoint peer || !LanProtocol.LocalAddress(peer.Address) || !clients.Wait(0))
                { client.Dispose(); continue; }
                long id = Interlocked.Increment(ref counter); active[id] = client;
                _ = HandleAsync(id, client, cancel);
            }
        } catch (OperationCanceledException) { } catch (ObjectDisposedException) { }
    }
    private async Task HandleAsync(long id, TcpClient client, CancellationToken lifetime)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        deadline.CancelAfter(TimeSpan.FromSeconds(25)); var cancel = deadline.Token;
        await using var tls = new SslStream(client.GetStream());
        try
        {
            await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {
                ServerCertificate = certificate, EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                ClientCertificateRequired = false }, cancel);
            using var bytes = new MemoryStream(); var buffer = new byte[8192]; HttpRequest? request = null;
            while (request == null) { int n = await tls.ReadAsync(buffer, cancel); if (n == 0) return;
                if (bytes.Length + n > 36864) throw new HttpFailure(413); bytes.Write(buffer, 0, n); request = HttpRequest.Parse(bytes.ToArray()); }
            Reply reply;
            try { reply = await RouteAsync(id, request, cancel); }
            catch (HttpFailure e) { reply = new(e.Status, "application/json", "{\"error\":\"request failed\"}"u8.ToArray()); }
            catch (Exception e) when (e is not OperationCanceledException) { reply = new(503, "application/json", "{\"error\":\"media unavailable\"}"u8.ToArray()); }
            await tls.WriteAsync(reply.Bytes(request.Method == "HEAD"), cancel);
            await tls.FlushAsync(cancel);
            await tls.ShutdownAsync();
        }
        catch (Exception e) when (e is IOException or AuthenticationException or OperationCanceledException or HttpFailure or ObjectDisposedException) { }
        finally { active.TryRemove(id, out _); owners.TryRemove(id, out _); client.Dispose(); clients.Release(); }
    }
    private async Task<Reply> RouteAsync(long connection, HttpRequest request, CancellationToken cancel)
    {
        var uri = new Uri("https://localhost" + request.Target); string path = uri.AbsolutePath;
        if (path == "/v1/pair")
        {
            if (request.Method != "POST" || !request.Headers.GetValueOrDefault("Content-Type", "").StartsWith("application/json")) throw new HttpFailure(400);
            var pair = Pairings.Pair(WireJson.Decode<PairRequest>(request.Body));
            if (PersistPairings != null) await PersistPairings(Pairings.Save());
            return Reply.Json(new PairResponse(pair.Token, ServerID));
        }
        string device = Pairings.Authorize(request.Headers.GetValueOrDefault("Authorization")) ?? throw new HttpFailure(401);
        owners[connection] = device;
        if (path == "/v1/device" && request.Method == "DELETE")
        {
            await RevokeAsync(device, connection); return new(204, "application/json", []);
        }
        if (path == "/v1/device/state" && request.Method == "POST")
        {
            var s = WireJson.Decode<DeviceState>(request.Body);
            Outputs[device] = s with { Output = (s.Output ?? "")[..Math.Min(s.Output?.Length ?? 0, 120)],
                TrackTitle = (s.TrackTitle ?? "")[..Math.Min(s.TrackTitle?.Length ?? 0, 200)],
                SampleRate = double.IsFinite(s.SampleRate) && s.SampleRate is >= 0 and <= 384000 ? s.SampleRate : 0 };
            return new(204, "application/json", []);
        }
        if (request.Method is not ("GET" or "HEAD")) throw new HttpFailure(405);
        if (path == "/v1/info") return Reply.Json(new ServerInfo(ServerID, Name));
        if (path == "/v1/albums") return Reply.Json(library.Albums());
        if (path == "/v1/tracks")
        {
            var q = new Dictionary<string, string>();
            foreach (string pair in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
            { var kv = pair.Split('=', 2); if (!q.TryAdd(Uri.UnescapeDataString(kv[0]), kv.Length == 2 ? Uri.UnescapeDataString(kv[1]) : "")) throw new HttpFailure(400); }
            if (!int.TryParse(q.GetValueOrDefault("offset", "0"), out int offset) || offset < 0 ||
                !int.TryParse(q.GetValueOrDefault("limit", "200"), out int limit) || limit is < 1 or > 500 ||
                q.GetValueOrDefault("q", "").Length > 200) throw new HttpFailure(400);
            return Reply.Json(library.Tracks(offset, limit, q.GetValueOrDefault("q", ""), q.GetValueOrDefault("album")));
        }
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 4 || parts[0] != "v1" || parts[1] != "tracks" || !LanProtocol.ValidID(parts[2])) throw new HttpFailure(404);
        string track = parts[2];
        switch (parts[3])
        {
            case "stream-info": return Reply.Json(await library.InfoAsync(track, cancel));
            case "stream":
                var info = await library.InfoAsync(track, cancel); info.Validate();
                if (request.Method == "HEAD") return new(200, "application/octet-stream", [], Length: info.Length, Headers: new() { ["Accept-Ranges"] = "bytes" });
                if (!request.Headers.TryGetValue("Range", out var raw)) throw new HttpFailure(400);
                var range = ByteRange.Parse(raw, info.Length); if (range.Count > LanProtocol.MaxRange) throw new HttpFailure(413);
                var data = await library.PcmAsync(track, range, cancel);
                if (data.LongLength != range.Count) throw new HttpFailure(503);
                return new(206, "application/octet-stream", data, Headers: new() {
                    ["Accept-Ranges"] = "bytes", ["Content-Range"] = $"bytes {range.Start}-{range.End}/{info.Length}" });
            case "artwork":
                var image = await library.ArtworkAsync(track, cancel) ?? throw new HttpFailure(404);
                string mime = image.Length >= 3 && image[0] == 0xff && image[1] == 0xd8 ? "image/jpeg" :
                    image.Length >= 12 && image.AsSpan(0, 4).SequenceEqual("RIFF"u8) && image.AsSpan(8, 4).SequenceEqual("WEBP"u8) ? "image/webp" : "image/png";
                return new(200, mime, image);
            case "lyrics": return Reply.Json(await library.LyricsAsync(track, cancel));
            case "video-info": return Reply.Json(new VideoInfo(false));
            default: throw new HttpFailure(404);
        }
    }
    public async ValueTask DisposeAsync()
    {
        Pairings.Close(); lifetime?.Cancel(); listener?.Stop();
        foreach (var c in active.Values) c.Dispose();
        if (accept != null) await accept;
        lifetime?.Dispose(); lifetime = null; listener = null;
    }
    private sealed record Reply(int Status, string Type, byte[] Body, long? Length = null, Dictionary<string, string>? Headers = null)
    {
        public static Reply Json<T>(T value) => new(200, "application/json", WireJson.Encode(value));
        public byte[] Bytes(bool head)
        {
            string reason = Status switch { 200 => "OK", 206 => "Partial Content", 204 => "No Content", _ => "Request Failed" };
            var text = new StringBuilder($"HTTP/1.1 {Status} {reason}\r\nContent-Type: {Type}\r\nContent-Length: {Length ?? Body.LongLength}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n");
            if (Headers != null) foreach (var h in Headers) text.Append($"{h.Key}: {h.Value}\r\n");
            text.Append("\r\n"); var header = Encoding.UTF8.GetBytes(text.ToString());
            return head ? header : [.. header, .. Body];
        }
    }
}
