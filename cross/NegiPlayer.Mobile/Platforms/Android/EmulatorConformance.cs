#if DEBUG
using Android.Content;
using NegiPlayer.Core;
using System.Text.Json;
namespace NegiPlayer.Mobile;

// Synthetic CI fixture only. This entry point is absent from Release builds and rejects real devices.
internal static class EmulatorConformance
{
    public static async Task RunAsync(Intent intent, string directory)
    {
        var report = new Dictionary<string, object> { ["passed"] = false };
        try
        {
            string address = intent.GetStringExtra("negi_address") ?? "";
            if (LanProtocol.BaseURL(address).Host != "10.0.2.2") throw new InvalidDataException("Emulator host required.");
            await Task.Delay(1500);
            var model = AppModel.Shared;
            await model.PairAsync(address, intent.GetStringExtra("negi_fingerprint") ?? "", intent.GetStringExtra("negi_code") ?? "", true);
            report = await NegiPlayer.Core.Conformance.VerifyConnectedPeerAsync(model.Client!);
            model.ApplySettings(new ListeningSettings { EqEnabled = true, EqPreamp = -6, Volume = 0.05, Headroom = 3 });
            var signal = model.Tracks.Single(t => t.Id == "signal-1");
            await model.PlayAsync(signal);
            for (int i = 0; i < 100 && model.Player.Position < 0.02 && model.Player.Error == null; i++) await Task.Delay(50);
            if (model.Player.Error != null || model.Player.Position < 0.02) throw new InvalidDataException("AudioTrack did not advance.");
            if (model.Cover == null || model.LyricLines.Count != 2) throw new InvalidDataException("Player assets did not load.");
            report["audioTrackVirtualOutput"] = true;
            report["endpointEqEnabled"] = model.Player.Settings.EqEnabled;
            report["playerArtworkAndLyrics"] = true;
            await model.DisconnectAsync();
            report["readonlyEndpointDisconnected"] = true;
        }
        catch (Exception e) {
            report["passed"] = false; report["errorType"] = e.GetType().Name;
            string message = e.Message;
            foreach (string key in new[] { "negi_address", "negi_fingerprint", "negi_code" }) {
                string value = intent.GetStringExtra(key) ?? ""; if (value.Length > 0) message = message.Replace(value, "[fixture]");
            }
            if (AppModel.Shared.Client?.Credentials?.Token is { } token) message = message.Replace(token, "[fixture token]");
            report["error"] = message[..Math.Min(message.Length, 500)];
        }
        await File.WriteAllTextAsync(Path.Combine(directory, "conformance-result.json"), JsonSerializer.Serialize(report));
    }
}
#endif
