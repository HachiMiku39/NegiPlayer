namespace NegiPlayer.Core;

public sealed record AudioOutput(string Id, string Name);
public interface IAudioSink : IDisposable
{
    void Configure(StreamInfo info, string preferredOutput);
    long PlayedFrames { get; }
    long QueuedFrames { get; }
    string OutputDescription { get; }
    double ClientRate { get; }
    IReadOnlyList<AudioOutput> Outputs { get; }
    Task WriteAsync(float[] samples, CancellationToken cancel);
    void Play();
    void Pause();
    void Volume(double volume);
    event Action? OutputRemoved;
}

/// <summary>One playback endpoint; at most four seconds of source PCM plus one in-flight range.</summary>
public sealed class StreamingPlayer : IAsyncDisposable
{
    private readonly IAudioSink sink; private readonly PcmDsp dsp = new();
    private readonly SemaphoreSlim mutations = new(1);
    private CancellationTokenSource? streamCancel; private Task? pump;
    private LanClient? client; private StreamInfo? info; private long startFrame;
    private volatile bool playing;
    public RemoteTrack? Track { get; private set; }
    public bool Playing => playing;
    public bool Buffering { get; private set; }
    public string? Error { get; private set; }
    public double Duration => info is null ? 0 : info.Frames / info.SampleRate;
    public double Position => info is null ? 0 : Math.Min(Duration, (startFrame + sink.PlayedFrames) / info.SampleRate);
    public string Output => sink.OutputDescription;
    public double ClientRate => sink.ClientRate;
    public ListeningSettings Settings { get; private set; } = new();
    public IReadOnlyList<AudioOutput> Outputs => sink.Outputs;
    public event Action? Ended;
    public event Action? Changed;
    public StreamingPlayer(IAudioSink sink)
    {
        this.sink = sink;
        sink.OutputRemoved += () => { Pause(); Error = "Audio output disconnected; select an output before resuming."; Changed?.Invoke(); };
    }
    public void Apply(ListeningSettings raw)
    {
        Settings = raw.Sanitized(); sink.Volume(Settings.Volume);
        if (info != null) dsp.Configure(info, Settings);
        Changed?.Invoke();
    }
    public async Task LoadAsync(LanClient session, RemoteTrack track)
    {
        if (!track.Playable || !LanProtocol.ValidID(track.Id)) throw new InvalidDataException("Track cannot be played by this endpoint.");
        await mutations.WaitAsync();
        try
        {
            await CancelPumpAsync(); sink.Pause(); info = null; Track = track; client = session;
            Error = null; Buffering = true; playing = false;
            var format = await session.JsonAsync<StreamInfo>($"/v1/tracks/{track.Id}/stream-info"); format.Validate();
            info = format; await BeginAsync(0, true);
        }
        catch { Buffering = false; playing = false; throw; }
        finally { mutations.Release(); Changed?.Invoke(); }
    }
    public async Task SeekAsync(double seconds)
    {
        if (info == null || !double.IsFinite(seconds)) return;
        await mutations.WaitAsync();
        try { await CancelPumpAsync(); await BeginAsync(seconds, playing); }
        finally { mutations.Release(); Changed?.Invoke(); }
    }
    public async Task ChangeOutputAsync(string id)
    {
        double at = Position; Pause(); Settings.OutputID = id; await SeekAsync(at);
    }
    private Task BeginAsync(double seconds, bool run)
    {
        var format = info!; startFrame = Math.Clamp((long)(Math.Max(0, seconds) * format.SampleRate), 0, format.Frames - 1);
        sink.Configure(format, Settings.OutputID); dsp.Configure(format, Settings); sink.Volume(Settings.Volume);
        playing = run; Buffering = true; streamCancel = new();
        var cancel = streamCancel.Token; var session = client!; var track = Track!; long first = startFrame;
        pump = Task.Run(async () =>
        {
            long next = first;
            try
            {
                while (next < format.Frames)
                {
                    cancel.ThrowIfCancellationRequested();
                    int frames = (int)Math.Min(Math.Min(32768, (long)format.SampleRate), format.Frames - next);
                    while (sink.QueuedFrames + frames > format.SampleRate * 4)
                        await Task.Delay(50, cancel);
                    var range = new ByteRange(next * format.BytesPerFrame, frames * format.BytesPerFrame);
                    byte[] bytes = await session.RangeAsync(track.Id, format, range, cancel);
                    var samples = Pcm.Decode(bytes, format.Channels); dsp.Process(samples, format.Channels);
                    if (playing) sink.Play();
                    await sink.WriteAsync(samples, cancel); next += frames; Buffering = false;
                    if (playing) sink.Play(); Changed?.Invoke();
                }
                while (sink.QueuedFrames > 0) await Task.Delay(100, cancel);
                playing = false; sink.Pause(); Buffering = false; Changed?.Invoke(); Ended?.Invoke();
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { playing = false; sink.Pause(); Buffering = false; Error = e.Message; Changed?.Invoke(); }
        }, cancel);
        return Task.CompletedTask;
    }
    public void Pause() { playing = false; sink.Pause(); Changed?.Invoke(); }
    public void Resume()
    {
        if (info == null) return;
        if (Position >= Duration - 0.001) { playing = true; _ = RestartAsync(); return; }
        sink.Play(); playing = true; Changed?.Invoke();
    }
    private async Task RestartAsync()
    {
        try { await SeekAsync(0); }
        catch (Exception e) { playing = false; Error = e.Message; Changed?.Invoke(); }
    }
    public void Toggle() { if (playing) Pause(); else Resume(); }
    private async Task CancelPumpAsync()
    {
        streamCancel?.Cancel(); if (pump != null) { try { await pump; } catch (OperationCanceledException) { } }
        streamCancel?.Dispose(); streamCancel = null; pump = null;
    }
    public async Task StopAsync()
    {
        await mutations.WaitAsync();
        try { await CancelPumpAsync(); sink.Pause(); playing = false; Buffering = false; Track = null; info = null; }
        finally { mutations.Release(); Changed?.Invoke(); }
    }
    public async ValueTask DisposeAsync() { await StopAsync(); sink.Dispose(); mutations.Dispose(); }
}
