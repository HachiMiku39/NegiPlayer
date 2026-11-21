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
    private readonly object transport = new();
    private long pauseVersion;
    private CancellationTokenSource? streamCancel; private Task? pump;
    private LanClient? client; private StreamInfo? info; private long startFrame;
    private volatile bool playing;
    public RemoteTrack? Track { get; private set; }
    public bool Playing => playing;
    public bool Buffering { get; private set; }
    public string? Error { get; private set; }
    public double Duration => info is { } format ? format.Frames / format.SampleRate : 0;
    public double Position
    {
        get
        {
            lock (transport)
            {
                if (info is not { } format) return 0;
                return Math.Min(format.Frames, startFrame + sink.PlayedFrames) / format.SampleRate;
            }
        }
    }
    public string Output => sink.OutputDescription;
    public double ClientRate => sink.ClientRate;
    public double SourceRate => info?.SampleRate ?? 0;
    public ListeningSettings Settings { get; private set; } = new();
    public IReadOnlyList<AudioOutput> Outputs => sink.Outputs;
    public event Action? Ended;
    public event Action? Changed;
    public StreamingPlayer(IAudioSink sink)
    {
        this.sink = sink;
        sink.OutputRemoved += HandleOutputRemoval;
    }
    public void Apply(ListeningSettings raw)
    {
        lock (transport)
        {
            Settings = raw.Sanitized();
            sink.Volume(Settings.Volume);
            if (info is { } format) dsp.Configure(format, Settings);
        }
        Changed?.Invoke();
    }
    public async Task LoadAsync(LanClient session, RemoteTrack track)
    {
        if (!track.Playable || !LanProtocol.ValidID(track.Id)) throw new InvalidDataException("Track cannot be played by this endpoint.");
        long autoplay;
        lock (transport) autoplay = pauseVersion;
        await mutations.WaitAsync();
        try
        {
            await CancelPumpAsync();
            lock (transport)
            {
                sink.Pause();
                info = null;
                Track = track;
                client = session;
                Error = null;
                Buffering = true;
                playing = autoplay == pauseVersion;
            }
            Changed?.Invoke();
            var format = await session.JsonAsync<StreamInfo>($"/v1/tracks/{track.Id}/stream-info");
            format.Validate();
            Begin(format, 0);
        }
        catch
        {
            lock (transport) { Buffering = false; playing = false; }
            throw;
        }
        finally { mutations.Release(); Changed?.Invoke(); }
    }
    public async Task SeekAsync(double seconds)
    {
        if (!double.IsFinite(seconds)) return;
        await mutations.WaitAsync();
        try
        {
            if (info is not { } format) return;
            await CancelPumpAsync();
            Begin(format, seconds);
        }
        finally { mutations.Release(); Changed?.Invoke(); }
    }
    public async Task ChangeOutputAsync(string id)
    {
        double at = Position;
        Pause();
        lock (transport) Settings = Settings with { OutputID = id };
        await SeekAsync(at);
    }
    private void Begin(StreamInfo format, double seconds)
    {
        long first;
        lock (transport)
        {
            sink.Configure(format, Settings.OutputID);
            dsp.Configure(format, Settings);
            sink.Volume(Settings.Volume);
            info = format;
            first = startFrame = Math.Clamp((long)(Math.Max(0, seconds) * format.SampleRate), 0, format.Frames - 1);
            Buffering = true;
        }
        streamCancel = new();
        var cancel = streamCancel.Token;
        var session = client!;
        var track = Track!;
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
                    var samples = Pcm.Decode(bytes, format.Channels);
                    dsp.Process(samples, format.Channels);
                    PlayIfRequested(cancel);
                    await sink.WriteAsync(samples, cancel);
                    next += frames;
                    Buffering = false;
                    PlayIfRequested(cancel);
                    Changed?.Invoke();
                }
                while (sink.QueuedFrames > 0) await Task.Delay(100, cancel);
                bool endedWhilePlaying;
                lock (transport)
                {
                    cancel.ThrowIfCancellationRequested();
                    endedWhilePlaying = playing;
                    playing = false;
                    sink.Pause();
                    Buffering = false;
                }
                Changed?.Invoke();
                if (endedWhilePlaying) Ended?.Invoke();
            }
            catch (OperationCanceledException) { }
            catch (Exception e)
            {
                lock (transport)
                {
                    playing = false;
                    sink.Pause();
                    Buffering = false;
                    Error = e.Message;
                }
                Changed?.Invoke();
            }
        }, cancel);
    }
    private void PlayIfRequested(CancellationToken cancel)
    {
        lock (transport)
        {
            cancel.ThrowIfCancellationRequested();
            if (playing) sink.Play();
        }
    }
    private void PauseOutput()
    {
        pauseVersion++;
        playing = false;
        sink.Pause();
    }
    private void HandleOutputRemoval()
    {
        lock (transport)
        {
            PauseOutput();
            Error = "Audio output disconnected; select an output before resuming.";
        }
        Changed?.Invoke();
    }
    public void Pause() => SetPlayback(false);
    public void Resume() => SetPlayback(true);
    public void Toggle() => SetPlayback(null);
    private void SetPlayback(bool? requested)
    {
        bool restart = false;
        lock (transport)
        {
            if (!(requested ?? !playing)) PauseOutput();
            else if (info != null)
            {
                restart = Position >= Duration - 0.001;
                if (!restart) sink.Play();
                playing = true;
            }
            else if (Buffering) playing = true;
            else return;
        }
        if (restart) _ = RestartAsync();
        else Changed?.Invoke();
    }
    private async Task RestartAsync()
    {
        try { await SeekAsync(0); }
        catch (Exception e)
        {
            lock (transport) { playing = false; Error = e.Message; }
            Changed?.Invoke();
        }
    }
    private async Task CancelPumpAsync()
    {
        streamCancel?.Cancel(); if (pump != null) { try { await pump; } catch (OperationCanceledException) { } }
        streamCancel?.Dispose(); streamCancel = null; pump = null;
    }
    public async Task StopAsync()
    {
        lock (transport) PauseOutput();
        await mutations.WaitAsync();
        try
        {
            await CancelPumpAsync();
            lock (transport)
            {
                playing = false;
                sink.Pause();
                Buffering = false;
                Track = null;
                info = null;
            }
        }
        finally { mutations.Release(); Changed?.Invoke(); }
    }
    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        sink.OutputRemoved -= HandleOutputRemoval;
        sink.Dispose();
        mutations.Dispose();
    }
}
