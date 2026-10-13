using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace NegiPlayer.Core;

/// <summary>Trust only the full certificate fingerprint confirmed by the listener's owner.</summary>
public sealed class LanClient : IDisposable
{
    public Uri BaseURL { get; }
    public string Fingerprint { get; }
    private readonly HttpClient http;
    public Credentials? Credentials { get; private set; }
    public LanClient(string address, string fingerprint)
    {
        BaseURL = LanProtocol.BaseURL(address); Fingerprint = fingerprint.Trim().ToLowerInvariant();
        if (!LanProtocol.ValidFingerprint(Fingerprint)) throw new ArgumentException("Invalid certificate fingerprint.");
        var expected = Convert.FromHexString(Fingerprint);
        var handler = new HttpClientHandler { AllowAutoRedirect = false, MaxConnectionsPerServer = 6,
            UseCookies = false, UseProxy = false };
        handler.ServerCertificateCustomValidationCallback = (request, certificate, _, _) =>
            request.RequestUri?.Host.Equals(BaseURL.Host, StringComparison.OrdinalIgnoreCase) == true &&
            request.RequestUri.Port == BaseURL.Port && certificate != null &&
            CryptographicOperations.FixedTimeEquals(SHA256.HashData(certificate.RawData), expected);
        http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
    }
    public async Task<Credentials> PairAsync(string code, string deviceName, CancellationToken cancel = default)
    {
        if (code.Length != 8 || !code.All(char.IsAsciiDigit)) throw new ArgumentException("Pairing code must be 8 digits.");
        var pair = WireJson.Decode<PairResponse>((await SendAsync("/v1/pair", "POST",
            WireJson.Encode(new PairRequest(code, deviceName)), null, cancel: cancel)).Bytes);
        if (pair.ProtocolVersion != 1 || !LanProtocol.ValidID(pair.ServerID) || pair.Token.Length < 40)
            throw new InvalidDataException("Host identity/protocol is invalid.");
        var credentials = new Credentials(BaseURL.AbsoluteUri.TrimEnd('/'), Fingerprint, pair.Token, pair.ServerID);
        await RestoreAsync(credentials, cancel); return credentials;
    }
    public async Task RestoreAsync(Credentials credentials, CancellationToken cancel = default)
    {
        if (LanProtocol.BaseURL(credentials.BaseURL) != BaseURL || credentials.Fingerprint != Fingerprint)
            throw new InvalidDataException("Saved origin does not match.");
        var info = await JsonAsync<ServerInfo>("/v1/info", credentials.Token, cancel);
        if (info.ProtocolVersion != 1 || info.Id != credentials.ServerID) throw new InvalidDataException("Host identity changed; pair again.");
        Credentials = credentials;
    }
    public async Task<T> JsonAsync<T>(string path, string? token = null, CancellationToken cancel = default) =>
        WireJson.Decode<T>((await SendAsync(path, token: token, cancel: cancel)).Bytes);
    public async Task<byte[]> AssetAsync(string trackID, string kind = "artwork", CancellationToken cancel = default)
    {
        if (!LanProtocol.ValidID(trackID) || kind != "artwork") throw new ArgumentException("Invalid asset.");
        return (await SendAsync($"/v1/tracks/{trackID}/{kind}", cancel: cancel)).Bytes;
    }
    public async Task<byte[]> RangeAsync(string trackID, StreamInfo info, ByteRange range, CancellationToken cancel)
    {
        if (!LanProtocol.ValidID(trackID) || range.Start < 0 || range.Count is < 1 or > LanProtocol.MaxRange ||
            range.Start > info.Length - range.Count) throw new ArgumentException("Invalid PCM range.");
        var result = await SendAsync($"/v1/tracks/{trackID}/stream", range: range, cancel: cancel);
        if (result.Status != 206 || result.Bytes.LongLength != range.Count ||
            result.ContentRange != $"bytes {range.Start}-{range.End}/{info.Length}")
            throw new InvalidDataException("Host returned a different PCM range.");
        return result.Bytes;
    }
    public Task ReportAsync(DeviceState state, CancellationToken cancel = default) =>
        SendAsync("/v1/device/state", "POST", WireJson.Encode(state), cancel: cancel);
    public async Task RevokeAsync(CancellationToken cancel = default)
    {
        await SendAsync("/v1/device", "DELETE", cancel: cancel); Credentials = null;
    }
    public async Task<Response> SendAsync(string path, string method = "GET", byte[]? body = null,
        string? token = null, ByteRange? range = null, CancellationToken cancel = default)
    {
        if (!path.StartsWith("/v1/") || path.Contains('#') || path.Any(c => c is '\r' or '\n'))
            throw new ArgumentException("Invalid protocol route.");
        var uri = new Uri(BaseURL, path);
        if (uri.Host != BaseURL.Host || uri.Port != BaseURL.Port || uri.Scheme != "https")
            throw new ArgumentException("Origin changed.");
        using var request = new HttpRequestMessage(new HttpMethod(method), uri);
        request.Headers.CacheControl = new CacheControlHeaderValue { NoStore = true };
        token ??= Credentials?.Token;
        if (token != null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body != null) { request.Content = new ByteArrayContent(body); request.Content.Headers.ContentType = new("application/json"); }
        if (range is { } r) request.Headers.Range = new RangeHeaderValue(r.Start, r.End);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancel);
        if (!response.IsSuccessStatusCode) throw new HttpFailure((int)response.StatusCode);
        int maximum = range.HasValue ? LanProtocol.MaxRange : 8_000_000;
        if (response.Content.Headers.ContentLength > maximum) throw new InvalidDataException("Oversized response.");
        await using var input = await response.Content.ReadAsStreamAsync(cancel);
        using var output = new MemoryStream(); var buffer = new byte[16384];
        for (;;) { int n = await input.ReadAsync(buffer, cancel); if (n == 0) break;
            if (output.Length + n > maximum) throw new InvalidDataException("Oversized response.");
            output.Write(buffer, 0, n); }
        return new((int)response.StatusCode, output.ToArray(), response.Content.Headers.ContentRange?.ToString());
    }
    public void Dispose() => http.Dispose();
    public sealed record Response(int Status, byte[] Bytes, string? ContentRange);
}
