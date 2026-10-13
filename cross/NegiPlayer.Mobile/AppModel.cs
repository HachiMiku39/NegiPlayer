using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using NegiPlayer.Core;
#if WINDOWS
using NegiPlayer.WindowsAudio;
#endif
namespace NegiPlayer.Mobile;

public sealed class AppModel : INotifyPropertyChanged
{
    public static AppModel Shared { get; } = new();
    public StreamingPlayer Player { get; }
    public LanClient? Client { get; private set; }
    public ObservableCollection<RemoteAlbum> Albums { get; } = [];
    public ObservableCollection<RemoteTrack> Tracks { get; } = [];
    public ObservableCollection<LyricLine> LyricLines { get; } = [];
    public RemoteAlbum? SelectedAlbum { get; private set; }
    public RemoteTrack? Current => Player.Track;
    public byte[]? Cover { get; private set; }
    public string Status { get; private set; } = "连接音乐主机";
    public bool Busy { get; private set; }
    public int Total { get; private set; }
    public bool Connected => Client?.Credentials != null;
    public bool LocalLibrary { get; private set; }
    public string Theme { get; set; } = Preferences.Get("theme", "Negi");
    public string AlbumMode { get; set; } = Preferences.Get("album-mode", "grid");
    private readonly Dictionary<string, byte[]> covers = [];
    private long coverBytes; private int browseGeneration, assetGeneration;
    private string query = "";
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? PlayerRequested;
#if WINDOWS
    public WindowsLibrary Library { get; } = new();
    public LanHost? Host { get; private set; }
    private LanHost? localHost;
    public string HostCode { get; private set; } = "";
    public string HostAddress { get; private set; } = "";
    public List<string> Roots { get; } = [];
    private X509Certificate2? identity;
#endif
    private AppModel()
    {
#if WINDOWS
        Player = new StreamingPlayer(new WindowsSink());
#else
        Player = new StreamingPlayer(new AndroidSink());
#endif
        Player.Changed += () => MainThread.BeginInvokeOnMainThread(() => Notify());
        Player.Ended += () => MainThread.BeginInvokeOnMainThread(async () => await NextAsync(1));
    }
    public async Task InitializeAsync()
    {
        try
        {
            await Localizer.InitializeAsync();
            var settings = Preferences.Get("listening", "");
            if (settings.Length > 0) Player.Apply(WireJson.Decode<ListeningSettings>(Encoding.UTF8.GetBytes(settings)));
#if WINDOWS
            var roots = Preferences.Get("music-roots", "");
            if (roots.Length > 0) Roots.AddRange(WireJson.Decode<string[]>(Encoding.UTF8.GetBytes(roots)));
#endif
            var raw = await SecureStorage.GetAsync("lan-client");
            if (raw != null) { var c = WireJson.Decode<Credentials>(Encoding.UTF8.GetBytes(raw));
                await ConnectAsync(new LanClient(c.BaseURL, c.Fingerprint), c); }
        }
        catch (Exception e) { Status = e.Message; }
        Notify();
    }
    public void ApplySettings(ListeningSettings settings)
    {
        Player.Apply(settings); Preferences.Set("listening", Encoding.UTF8.GetString(WireJson.Encode(Player.Settings)));
    }
    public async Task PairAsync(string address, string fingerprint, string code, bool confirmed)
    {
        if (!confirmed) throw new InvalidOperationException(Localizer.L("请核对完整证书指纹"));
        var client = new LanClient(address, fingerprint);
        try { var c = await client.PairAsync(code, DeviceInfo.Name);
            await SecureStorage.SetAsync("lan-client", Encoding.UTF8.GetString(WireJson.Encode(c)));
            await ConnectAsync(client, c); }
        catch { client.Dispose(); throw; }
    }
    private async Task ConnectAsync(LanClient client, Credentials credentials, bool local = false)
    {
        await client.RestoreAsync(credentials); await Player.StopAsync(); Client?.Dispose(); Client = client;
        LocalLibrary = local; SelectedAlbum = null; query = ""; covers.Clear(); coverBytes = 0;
        await ReloadAsync(); Status = "曲库只读 · 音频在本机处理"; Notify();
    }
    public async Task DisconnectAsync()
    {
        await Player.StopAsync(); assetGeneration++; browseGeneration++;
        if (Client != null) { try { await Client.RevokeAsync(); } catch (HttpRequestException) { } catch (HttpFailure) { } }
        SecureStorage.Remove("lan-client"); Client?.Dispose(); Client = null; LocalLibrary = false;
        Albums.Clear(); Tracks.Clear(); LyricLines.Clear(); Cover = null; Status = "连接音乐主机"; Notify();
    }
    public async Task ReloadAsync()
    {
        if (Client == null) return; var client = Client;
        var page = await client.JsonAsync<AlbumPage>("/v1/albums");
        if (client != Client) return;
        Albums.Clear(); foreach (var album in page.Albums) Albums.Add(album); await SearchAsync(query);
    }
    public async Task SearchAsync(string text, bool more = false)
    {
        if (Client == null) return; int generation = ++browseGeneration;
        query = text; Busy = true; Notify();
        try
        {
            int offset = more ? Tracks.Count : 0;
            string path = $"/v1/tracks?offset={offset}&limit=200&q={Uri.EscapeDataString(text)}";
            if (SelectedAlbum != null) path += "&album=" + Uri.EscapeDataString(SelectedAlbum.Id);
            var page = await Client.JsonAsync<TrackPage>(path);
            if (generation != browseGeneration) return;
            if (!more) Tracks.Clear(); foreach (var track in page.Tracks) Tracks.Add(track); Total = page.Total;
        }
        finally { if (generation == browseGeneration) { Busy = false; Notify(); } }
    }
    public async Task SelectAsync(RemoteAlbum? album) { SelectedAlbum = album; await SearchAsync(""); }
    public async Task PlayAsync(RemoteTrack track)
    {
        if (Client == null) return; var client = Client; int generation = ++assetGeneration;
        LyricLines.Clear(); Cover = null; PlayerRequested?.Invoke(); await Player.LoadAsync(client, track);
        var coverTask = CoverAsync(track.Id); var lyricTask = client.JsonAsync<RemoteLyrics>($"/v1/tracks/{track.Id}/lyrics");
        try { var image = await coverTask; if (generation == assetGeneration) Cover = image; } catch (HttpFailure) { }
        try { var lines = await lyricTask; if (generation == assetGeneration) foreach (var line in lines.Lines) LyricLines.Add(line); } catch (HttpFailure) { }
        Notify();
    }
    public async Task<byte[]?> CoverAsync(string id)
    {
        if (covers.TryGetValue(id, out var cached)) return cached;
        var client = Client; if (client == null) return null;
        try {
            var image = await client.AssetAsync(id); if (client != Client) return null;
            if (covers.Count >= 32 || coverBytes + image.Length > 32_000_000) { covers.Clear(); coverBytes = 0; }
            covers[id] = image; coverBytes += image.Length; return image;
        } catch (HttpFailure e) when (e.Status == 404) { return null; }
    }
    public async Task NextAsync(int step)
    {
        var playable = Tracks.Where(t => t.Playable).ToArray(); int index = Array.FindIndex(playable, t => t.Id == Current?.Id);
        int next = index + step; if (next >= 0 && next < playable.Length) await PlayAsync(playable[next]);
    }
    public async Task ReportAsync()
    {
        if (Client == null || !Connected) return;
        try { await Client.ReportAsync(new(Player.Output, Player.ClientRate, Player.Settings.EqEnabled, Player.Playing, Current?.Title ?? "")); }
        catch (Exception e) when (e is HttpRequestException or HttpFailure or TaskCanceledException) { }
    }
#if WINDOWS
    private async Task EnsureIdentityAsync()
    {
        if (identity != null) return;
        var pfx = await SecureStorage.GetAsync("host-pfx");
        identity = pfx == null ? LanHost.NewCertificate() : X509CertificateLoader.LoadPkcs12(Convert.FromBase64String(pfx), null);
        if (pfx == null) await SecureStorage.SetAsync("host-pfx", Convert.ToBase64String(identity.Export(X509ContentType.Pfx)));
    }
    public async Task ImportAsync()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker(); picker.FileTypeFilter.Add("*");
        var window = Application.Current!.Windows[0].Handler!.PlatformView;
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        var folder = await picker.PickSingleFolderAsync(); if (folder == null) return;
        if (!Roots.Contains(folder.Path, StringComparer.OrdinalIgnoreCase)) Roots.Add(folder.Path);
        Preferences.Set("music-roots", Encoding.UTF8.GetString(WireJson.Encode(Roots.ToArray())));
        await BrowseLocalAsync();
    }
    public async Task BrowseLocalAsync()
    {
        Busy = true; Status = "只读扫描音乐文件夹"; Notify();
        try
        {
            await Library.ScanAsync(Roots); await EnsureIdentityAsync();
            if (localHost != null) await localHost.DisposeAsync();
            localHost = new LanHost(Library, identity!, Guid.NewGuid().ToString("N"), "NegiPlayer Windows · Local");
            localHost.Start(0, true);
            var client = new LanClient($"https://127.0.0.1:{localHost.Port}", localHost.Fingerprint);
            var credentials = await client.PairAsync(localHost.Pairings.Renew(), "Local playback");
            await ConnectAsync(client, credentials, true);
        }
        finally { Busy = false; Notify(); }
    }
    public async Task ToggleHostAsync()
    {
        if (Host != null) { await Host.DisposeAsync(); Host = null; HostCode = ""; Notify(); return; }
        await EnsureIdentityAsync(); await Library.ScanAsync(Roots);
        string id = Preferences.Get("host-id", Guid.NewGuid().ToString("N")); Preferences.Set("host-id", id);
        var host = new LanHost(Library, identity!, id, DeviceInfo.Name + " · NegiPlayer");
        string? pairs = await SecureStorage.GetAsync("host-pairs"); if (pairs != null) host.Pairings.Restore(Convert.FromBase64String(pairs));
        host.PersistPairings = bytes => SecureStorage.SetAsync("host-pairs", Convert.ToBase64String(bytes));
        host.Start(); Host = host;
        string address = System.Net.Dns.GetHostAddresses(System.Net.Dns.GetHostName()).FirstOrDefault(p =>
            p.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && LanProtocol.LocalAddress(p) && !System.Net.IPAddress.IsLoopback(p))?.ToString() ?? "127.0.0.1";
        HostAddress = $"https://{address}:{host.Port}"; HostCode = host.Pairings.Renew(); Notify();
    }
    public void RenewCode() { if (Host != null) HostCode = Host.Pairings.Renew(); Notify(); }
    public async Task RevokeDeviceAsync(string id)
    {
        if (Host == null) return; await Host.RevokeAsync(id); Notify();
    }
#endif
    private void Notify([CallerMemberName] string? property = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
}
