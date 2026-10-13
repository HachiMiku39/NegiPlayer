using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;
using NegiPlayer.Core;
using NativeDeviceState = NAudio.CoreAudioApi.DeviceState;

namespace NegiPlayer.WindowsAudio;

public sealed class WindowsSink : IAudioSink, IMMNotificationClient
{
    private readonly MMDeviceEnumerator devices = new();
    private readonly object gate = new();
    private WasapiOut? output; private BufferedWaveProvider? buffer;
    private StreamInfo? info; private MMDevice? device;
    private long submitted; private double volume = 0.5; private bool removed;
    public event Action? OutputRemoved;
    public WindowsSink() => devices.RegisterEndpointNotificationCallback(this);
    public IReadOnlyList<AudioOutput> Outputs => devices.EnumerateAudioEndPoints(DataFlow.Render, NativeDeviceState.Active)
        .Select(d => new AudioOutput(d.ID, d.FriendlyName)).ToArray();
    public string OutputDescription => device == null ? "WASAPI shared" :
        $"{device.FriendlyName} · WASAPI shared · mix {device.AudioClient.MixFormat.SampleRate} Hz";
    public double ClientRate => info?.SampleRate ?? 0;
    public long PlayedFrames { get { lock (gate) { if (output == null || info == null) return 0;
        return Math.Clamp((long)(output.GetPosition() * info.SampleRate / output.OutputWaveFormat.AverageBytesPerSecond), 0, submitted); } } }
    public long QueuedFrames { get { lock (gate) return Math.Max(0, submitted - PlayedFrames); } }
    public void Configure(StreamInfo format, string preferredOutput)
    {
        lock (gate)
        {
            output?.Stop(); output?.Dispose(); device?.Dispose(); info = format; removed = false;
            device = string.IsNullOrEmpty(preferredOutput) ? devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia) : devices.GetDevice(preferredOutput);
            if (device.State != NativeDeviceState.Active) throw new InvalidOperationException("Selected output is offline.");
            var wave = WaveFormat.CreateIeeeFloatWaveFormat((int)format.SampleRate, format.Channels);
            buffer = new BufferedWaveProvider(wave) { BufferDuration = TimeSpan.FromSeconds(4), DiscardOnBufferOverflow = false, ReadFully = true };
            output = new WasapiOut(device, AudioClientShareMode.Shared, true, 100);
            output.Init(new VolumeProvider(buffer, () => volume)); submitted = 0;
            output.PlaybackStopped += (_, e) => { if (e.Exception != null) { removed = true; OutputRemoved?.Invoke(); } };
        }
    }
    public Task WriteAsync(float[] samples, CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested(); byte[] bytes = Pcm.Encode(samples);
        lock (gate) { if (removed || buffer == null || info == null) throw new InvalidOperationException("Audio output disconnected.");
            buffer.AddSamples(bytes, 0, bytes.Length); submitted += samples.Length / info.Channels; }
        return Task.CompletedTask;
    }
    public void Play() { lock (gate) { if (removed) throw new InvalidOperationException("Select an output after disconnecting."); if (output?.PlaybackState != PlaybackState.Playing) output?.Play(); } }
    public void Pause() { lock (gate) output?.Pause(); }
    public void Volume(double value) => volume = double.IsFinite(value) ? Math.Clamp(value, 0, 1) : 0;
    public void Dispose() { devices.UnregisterEndpointNotificationCallback(this); lock (gate) { output?.Dispose(); device?.Dispose(); devices.Dispose(); } }
    public void OnDeviceStateChanged(string id, NativeDeviceState state) { if (id == device?.ID && state != NativeDeviceState.Active) { removed = true; OutputRemoved?.Invoke(); } }
    public void OnDeviceRemoved(string id) { if (id == device?.ID) { removed = true; OutputRemoved?.Invoke(); } }
    public void OnDefaultDeviceChanged(DataFlow flow, Role role, string id) { }
    public void OnDeviceAdded(string id) { }
    public void OnPropertyValueChanged(string id, PropertyKey key) { }
    private sealed class VolumeProvider(BufferedWaveProvider source, Func<double> level) : IWaveProvider
    {
        public WaveFormat WaveFormat => source.WaveFormat;
        public int Read(byte[] bytes, int offset, int count)
        {
            int n = source.Read(bytes, offset, count); double v = level();
            for (int i = offset; i + 4 <= offset + n; i += 4)
            { float f = System.Buffers.Binary.BinaryPrimitives.ReadSingleLittleEndian(bytes.AsSpan(i));
                System.Buffers.Binary.BinaryPrimitives.WriteSingleLittleEndian(bytes.AsSpan(i), (float)(f * v)); }
            return n;
        }
    }
}
