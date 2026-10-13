namespace NegiPlayer.Mobile;
public sealed class App : Application
{
    protected override Window CreateWindow(IActivationState? activationState)
    {
        var window = new Window(new MainPage(AppModel.Shared)) { Title = "NegiPlayer", Width = 1100, Height = 800 };
#if WINDOWS
        window.HandlerChanged += (_, _) => {
            if (window.Handler?.PlatformView is Microsoft.UI.Xaml.Window native && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621))
                native.SystemBackdrop = new Microsoft.UI.Xaml.Media.DesktopAcrylicBackdrop();
        };
#endif
        return window;
    }
}
