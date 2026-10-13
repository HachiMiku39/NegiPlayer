using Android.App;
using Android.Content;
using Android.OS;
namespace NegiPlayer.Mobile;
[Service(Exported = false, ForegroundServiceType = Android.Content.PM.ForegroundService.TypeMediaPlayback)]
public sealed class PlaybackService : Service
{
    public override IBinder? OnBind(Intent? intent) => null;
    public override StartCommandResult OnStartCommand(Intent? intent, StartCommandFlags flags, int startId)
    {
        const string channel = "negiplayer-playback";
        var notifications = (NotificationManager)GetSystemService(NotificationService)!;
        notifications.CreateNotificationChannel(new NotificationChannel(channel, "NegiPlayer", NotificationImportance.Low));
        var launch = PackageManager?.GetLaunchIntentForPackage(PackageName!);
        var pending = PendingIntent.GetActivity(this, 0, launch, PendingIntentFlags.Immutable | PendingIntentFlags.UpdateCurrent);
        var notification = new Notification.Builder(this, channel).SetContentTitle("NegiPlayer")
            .SetContentText("LAN audio playback").SetSmallIcon(Android.Resource.Drawable.IcMediaPlay)
            .SetContentIntent(pending).SetOngoing(true).Build();
        StartForeground(39, notification); return StartCommandResult.NotSticky;
    }
    public override void OnDestroy() { AppModel.Shared.Player.Pause(); base.OnDestroy(); }
}
