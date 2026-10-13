using Android.Content;
using Android.Media;
using Android.OS;
using NegiPlayer.Core;
using AudioEncoding = Android.Media.Encoding;

namespace NegiPlayer.Mobile;
public sealed class AndroidSink : Java.Lang.Object, IAudioSink, AudioManager.IOnAudioFocusChangeListener
{
    private readonly AudioManager manager = (AudioManager)Android.App.Application.Context.GetSystemService(Context.AudioService)!;
    private readonly object gate = new(); private AudioTrack? track; private AudioFocusRequestClass? focus;
    private StreamInfo? info; private long submitted, wrap; private uint previous;
    private bool removed; private int chosenID; private double volume = 0.5;
    private readonly DeviceEvents events;
    public event Action? OutputRemoved;
    public AndroidSink() { events = new DeviceEvents(this); manager.RegisterAudioDeviceCallback(events, new Handler(Looper.MainLooper!)); }
    public IReadOnlyList<AudioOutput> Outputs => manager.GetDevices(GetDevicesTargets.Outputs)
        .Select(d => new AudioOutput(d.Id.ToString(), d.ProductName?.ToString() ?? d.Type.ToString())).ToArray();
    public string OutputDescription => $"{track?.RoutedDevice?.ProductName?.ToString() ?? "Android system route"} · AudioTrack PCM float; hardware clock not exposed";
    public double ClientRate => track?.SampleRate ?? 0;
    public long PlayedFrames { get { lock (gate) {
        if (track == null) return 0; uint current = unchecked((uint)track.PlaybackHeadPosition);
        if (current < previous && previous - current > uint.MaxValue / 2) wrap += 1L << 32;
        previous = current; return Math.Min(submitted, wrap + current);
    } } }
    public long QueuedFrames { get { lock (gate) return Math.Max(0, submitted - PlayedFrames); } }
    public void Configure(StreamInfo format, string preferredOutput)
    {
        lock (gate)
        {
            track?.Pause(); track?.Flush(); track?.Dispose(); info = format; removed = false; submitted = wrap = 0; previous = 0;
            var channels = format.Channels == 1 ? ChannelOut.Mono : ChannelOut.Stereo;
            int minimum = AudioTrack.GetMinBufferSize((int)format.SampleRate, channels, AudioEncoding.PcmFloat);
            if (minimum <= 0) throw new InvalidOperationException("Android does not support this client PCM rate.");
            var attributes = new AudioAttributes.Builder().SetUsage(AudioUsageKind.Media).SetContentType(AudioContentType.Music).Build()!;
            var audio = new AudioFormat.Builder().SetEncoding(AudioEncoding.PcmFloat).SetSampleRate((int)format.SampleRate).SetChannelMask(channels).Build()!;
            track = new AudioTrack.Builder().SetAudioAttributes(attributes).SetAudioFormat(audio)
                .SetTransferMode(AudioTrackMode.Stream).SetBufferSizeInBytes(Math.Max(minimum * 2, (int)format.SampleRate * format.BytesPerFrame / 2)).Build();
            if (track.State != AudioTrackState.Initialized) throw new InvalidOperationException("AudioTrack initialization failed.");
            chosenID = int.TryParse(preferredOutput, out var id) ? id : 0;
            if (chosenID != 0)
            {
                var selected = manager.GetDevices(GetDevicesTargets.Outputs).FirstOrDefault(d => d.Id == chosenID)
                    ?? throw new InvalidOperationException("Selected USB/output device is offline.");
                if (!track.SetPreferredDevice(selected)) throw new InvalidOperationException("Android rejected the preferred output.");
            }
            track.SetVolume((float)volume);
            focus?.Dispose(); focus = new AudioFocusRequestClass.Builder(AudioFocus.Gain).SetAudioAttributes(attributes)
                .SetOnAudioFocusChangeListener(this, new Handler(Looper.MainLooper!)).Build();
        }
    }
    public async Task WriteAsync(float[] samples, CancellationToken cancel)
    {
        int offset = 0;
        while (offset < samples.Length)
        {
            cancel.ThrowIfCancellationRequested(); int written;
            lock (gate) {
                if (removed || track == null || info == null) throw new InvalidOperationException("Output is unavailable.");
                written = track.Write(samples, offset, samples.Length - offset, WriteMode.NonBlocking);
                if (written > 0) submitted += written / info.Channels;
            }
            if (written < 0) throw new IOException($"AudioTrack rejected PCM ({written}).");
            if (written == 0) await Task.Delay(20, cancel); else offset += written;
        }
    }
    public void Play()
    {
        lock (gate) {
            if (removed) throw new InvalidOperationException("Select an output after disconnecting.");
            if (track == null || track.PlayState == PlayState.Playing) return;
            if (focus == null || manager.RequestAudioFocus(focus) != AudioFocusRequest.Granted) throw new InvalidOperationException("Audio focus was not granted.");
            var context = Android.App.Application.Context;
            context.StartForegroundService(new Intent(context, typeof(PlaybackService))); track.Play();
        }
    }
    public void Pause() { lock (gate) track?.Pause(); }
    public void Volume(double value) { lock (gate) { volume = double.IsFinite(value) ? Math.Clamp(value, 0, 1) : 0; track?.SetVolume((float)volume); } }
    public void OnAudioFocusChange(AudioFocus change) { if (change != AudioFocus.Gain) OutputRemoved?.Invoke(); }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { manager.UnregisterAudioDeviceCallback(events); if (focus != null) manager.AbandonAudioFocusRequest(focus);
            track?.Dispose(); events.Dispose(); focus?.Dispose(); }
        base.Dispose(disposing);
    }
    private sealed class DeviceEvents(AndroidSink owner) : AudioDeviceCallback
    {
        public override void OnAudioDevicesRemoved(AudioDeviceInfo[]? removed)
        {
            int active = owner.track?.RoutedDevice?.Id ?? owner.chosenID;
            if (removed?.Any(d => d.Id == active) == true) { owner.removed = true; owner.OutputRemoved?.Invoke(); }
        }
    }
}
