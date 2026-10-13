using System.Buffers.Binary;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NegiPlayer.Core;

public sealed record RemoteTrack(string Id, string Title, string Artist, string Album, string AlbumID,
    string Codec, double SampleRate, double Duration, int TrackNumber, int DiscNumber, bool Playable);
public sealed record RemoteAlbum(string Id, string Title, string Artist, string CoverTrackID, int Count);
public sealed record TrackPage(RemoteTrack[] Tracks, int Total, int Offset, string Revision);
public sealed record AlbumPage(RemoteAlbum[] Albums, string Revision);
public sealed record LyricLine(int Id, double? Time, string Text);
public sealed record RemoteLyrics(LyricLine[] Lines);
public sealed record PairRequest(string Code, string DeviceName);
public sealed record PairResponse(string Token, string ServerID, int ProtocolVersion = 1);
public sealed record ServerInfo(string Id, string Name, int ProtocolVersion = 1);
public sealed record Credentials(string BaseURL, string Fingerprint, string Token, string ServerID);
public sealed record DeviceState(string Output, double SampleRate, bool EqEnabled, bool Playing, string TrackTitle);
public sealed record VideoInfo(bool Available, long Length = 0, string ContentType = "video/mp4");
public sealed record StreamInfo(double SampleRate, int Channels, long Frames,
    Dictionary<string, string[]> Tags, string Format = "float32-le-interleaved")
{
    [JsonIgnore] public int BytesPerFrame => Channels * 4;
    [JsonIgnore] public long Length => checked(Frames * BytesPerFrame);
    public void Validate()
    {
        if (Format != "float32-le-interleaved" || !double.IsFinite(SampleRate) ||
            SampleRate < 8000 || SampleRate > 384000 || Channels is < 1 or > 2 ||
            Frames <= 0 || Frames > long.MaxValue / (Channels * 4L))
            throw new InvalidDataException("Unsupported LAN PCM format.");
    }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(RemoteTrack))]
[JsonSerializable(typeof(RemoteAlbum))]
[JsonSerializable(typeof(TrackPage))]
[JsonSerializable(typeof(AlbumPage))]
[JsonSerializable(typeof(RemoteLyrics))]
[JsonSerializable(typeof(PairRequest))]
[JsonSerializable(typeof(PairResponse))]
[JsonSerializable(typeof(ServerInfo))]
[JsonSerializable(typeof(StreamInfo))]
[JsonSerializable(typeof(Credentials))]
[JsonSerializable(typeof(DeviceState))]
[JsonSerializable(typeof(VideoInfo))]
[JsonSerializable(typeof(ListeningSettings))]
[JsonSerializable(typeof(SavedPair[]))]
public partial class WireJson : JsonSerializerContext
{
    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, typeof(T), Default);
    public static T Decode<T>(byte[] bytes) => (T)(JsonSerializer.Deserialize(bytes, typeof(T), Default)
        ?? throw new InvalidDataException("Empty LAN response."));
}

public static class LanProtocol
{
    public const int Version = 1;
    public const int MaxRange = 262144;
    public const string ServiceType = "_negiplayer._tcp";
    public static bool ValidID(string value) => value.Length is > 0 and <= 128 &&
        value.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');
    public static bool ValidFingerprint(string value) => value.Length == 64 &&
        value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    public static string Fingerprint(ReadOnlySpan<byte> certificate) => Convert.ToHexStringLower(SHA256.HashData(certificate));
    public static bool LocalAddress(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        if (IPAddress.IsLoopback(ip)) return true;
        var b = ip.GetAddressBytes();
        return b.Length == 4 ? b[0] == 10 || b[0] == 172 && b[1] is >= 16 and <= 31 ||
            b[0] == 192 && b[1] == 168 || b[0] == 169 && b[1] == 254 :
            (b[0] & 0xfe) == 0xfc || b[0] == 0xfe && (b[1] & 0xc0) == 0x80;
    }
    public static Uri BaseURL(string text)
    {
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment) || uri.AbsolutePath != "/" ||
            uri.Port is < 1 or > 65535 || !uri.Authority.Contains(':'))
            throw new ArgumentException("Enter the host's LAN HTTPS address including its port.");
        string host = uri.DnsSafeHost.Trim('[', ']').ToLowerInvariant();
        if (!(host == "localhost" || host.EndsWith(".local") || host.EndsWith(".local.") ||
            IPAddress.TryParse(host, out var ip) && LocalAddress(ip)))
            throw new ArgumentException("A local/private network address is required.");
        return new Uri(uri.GetLeftPart(UriPartial.Authority));
    }
}

public readonly record struct ByteRange(long Start, long Count)
{
    public long End => checked(Start + Count - 1);
    public static ByteRange Parse(string? value, long length)
    {
        if (length <= 0 || value is null || !value.StartsWith("bytes=") || value.Contains(','))
            throw new HttpFailure(416);
        var p = value[6..].Split('-');
        static long Number(string s) => s.Length > 0 && s.All(char.IsAsciiDigit) &&
            long.TryParse(s, out var n) ? n : throw new HttpFailure(416);
        if (p.Length != 2) throw new HttpFailure(416);
        if (p[0].Length == 0)
        {
            long n = Number(p[1]); if (n == 0) throw new HttpFailure(416);
            n = Math.Min(n, length); return new(length - n, n);
        }
        long start = Number(p[0]), end = p[1].Length == 0 ? length - 1 : Number(p[1]);
        if (start >= length || end < start) throw new HttpFailure(416);
        end = Math.Min(end, length - 1); return new(start, end - start + 1);
    }
}
public sealed class HttpFailure(int status) : Exception($"LAN HTTP {status}") { public int Status { get; } = status; }

public static class Pcm
{
    public static byte[] Encode(float[] samples)
    {
        var bytes = new byte[samples.Length * 4];
        for (int i = 0; i < samples.Length; i++)
            BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(i * 4), float.IsFinite(samples[i]) ? samples[i] : 0);
        return bytes;
    }
    public static float[] Decode(byte[] bytes, int channels)
    {
        if (channels is < 1 or > 2 || bytes.Length % (channels * 4) != 0 || bytes.Length > LanProtocol.MaxRange)
            throw new InvalidDataException("Incomplete or oversized PCM range.");
        var samples = new float[bytes.Length / 4];
        for (int i = 0; i < samples.Length; i++)
        {
            float f = BinaryPrimitives.ReadSingleLittleEndian(bytes.AsSpan(i * 4));
            samples[i] = float.IsFinite(f) ? f : 0;
        }
        return samples;
    }
}
