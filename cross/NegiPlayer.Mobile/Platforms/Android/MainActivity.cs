using Android.App;
using Android.Content.PM;
using Android.OS;
namespace NegiPlayer.Mobile;
[Activity(Name = "com.negiplayer.mobile.MainActivity", Theme = "@style/Maui.SplashTheme", MainLauncher = true, Exported = true,
    ConfigurationChanges = ConfigChanges.ScreenSize | ConfigChanges.Orientation | ConfigChanges.UiMode |
        ConfigChanges.ScreenLayout | ConfigChanges.SmallestScreenSize | ConfigChanges.Density)]
public class MainActivity : MauiAppCompatActivity
{
#if DEBUG
    private bool smokeStarted;
    protected override void OnResume()
    {
        base.OnResume();
        if (!smokeStarted && Intent?.GetBooleanExtra("negi_conformance", false) == true &&
            (Build.Hardware == "ranchu" || Build.Hardware == "goldfish"))
        {
            smokeStarted = true;
            _ = EmulatorConformance.RunAsync(Intent, FilesDir!.AbsolutePath);
        }
    }
#endif
}
