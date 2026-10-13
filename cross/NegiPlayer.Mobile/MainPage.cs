using NegiPlayer.Core;
using Microsoft.Maui.Controls.Shapes;
using static NegiPlayer.Mobile.Localizer;
namespace NegiPlayer.Mobile;

public sealed class MainPage : ContentPage
{
    private readonly AppModel model;
    private readonly Grid root = new() { RowDefinitions = { new(GridLength.Auto), new(GridLength.Star), new(GridLength.Auto) }, Padding = 16, RowSpacing = 12 };
    private readonly ContentView content = new();
    private readonly Label status = new() { FontSize = 12, LineBreakMode = LineBreakMode.TailTruncation };
    private readonly Label song = new() { FontSize = 20, FontAttributes = FontAttributes.Bold };
    private readonly Label artist = new() { FontSize = 14 };
    private readonly Label path = new() { FontSize = 11, LineBreakMode = LineBreakMode.WordWrap };
    private readonly Label time = new() { FontSize = 12 };
    private readonly Image cover = new() { Source = "cover_placeholder.png", Aspect = Aspect.AspectFit, HeightRequest = 280, WidthRequest = 280 };
    private readonly Slider progress = new() { Minimum = 0, Maximum = 1 };
    private readonly Button play = new() { Text = "▶", FontSize = 24 };
    private readonly CollectionView lyrics = new() { SelectionMode = SelectionMode.None };
    private readonly Grid playerGrid = new() { ColumnSpacing = 30, RowSpacing = 24 };
    private readonly VerticalStackLayout controls = new() { Spacing = 14, HorizontalOptions = LayoutOptions.Center };
    private readonly ScrollView controlsScroll;
    private readonly Grid compactHeader = new() { ColumnDefinitions = { new(68), new(GridLength.Star) }, RowDefinitions = { new(GridLength.Auto), new(GridLength.Auto) }, ColumnSpacing = 12 };
    private readonly VerticalStackLayout compactFooter = new() { Spacing = 2 };
    private readonly HorizontalStackLayout transport = new() { Spacing = 24, HorizontalOptions = LayoutOptions.Center };
    private readonly Slider volume = new() { Minimum = 0, Maximum = 1, WidthRequest = 240, HorizontalOptions = LayoutOptions.Center };
    private CollectionView? albums, tracks;
    private bool initialized, dragging, follow = true;
    private int activeLyric = -1;
    private byte[]? displayedCover;
    private string page = "albums";
    private CancellationTokenSource? searchDelay;
    private readonly IDispatcherTimer timer;
    private Color accent = Color.FromArgb("#37BFB5"), foreground = Colors.White, surface = Color.FromArgb("#202D33");
    private readonly Label hostSummary = new() { FontSize = 12, LineBreakMode = LineBreakMode.CharacterWrap };
    private int ticks;
    private readonly Label softwareVolume = new() { FontSize = 12 };
    private readonly List<WeakReference<Label>> lyricLabels = [];
    public MainPage(AppModel model)
    {
        this.model = model; controlsScroll = new ScrollView { Content = controls }; Content = root; Title = "NegiPlayer";
        model.PropertyChanged += (_, _) => Tick();
        model.PlayerRequested += () => Show("playing");
        root.Add(content, 0, 1); root.Add(status, 0, 2);
        progress.DragStarted += (_, _) => dragging = true;
        progress.DragCompleted += async (_, _) => { dragging = false; await Run(() => model.Player.SeekAsync(progress.Value)); };
        play.Clicked += (_, _) => { try { model.Player.Toggle(); } catch (Exception e) { status.Text = e.Message; } };
        controls.Add(cover); controls.Add(song); controls.Add(artist); controls.Add(progress); controls.Add(time);
        transport.Add(B("◀", () => model.NextAsync(-1))); transport.Add(play); transport.Add(B("▶▶", () => model.NextAsync(1))); controls.Add(transport);
        volume.Value = model.Player.Settings.Volume;
        volume.ValueChanged += (_, e) => model.ApplySettings(model.Player.Settings with { Volume = e.NewValue });
        controls.Add(softwareVolume); controls.Add(volume); controls.Add(path);
        lyrics.ItemTemplate = new DataTemplate(() =>
        {
            var label = new Label { FontSize = 23, Margin = new Thickness(8, 16), LineBreakMode = LineBreakMode.WordWrap };
            label.SetBinding(Label.TextProperty, nameof(LyricLine.Text));
            lyricLabels.Add(new(label));
            label.TextColor = foreground;
            var tap = new TapGestureRecognizer(); tap.Tapped += async (_, _) => {
                if (label.BindingContext is LyricLine { Time: { } at }) await Run(() => model.Player.SeekAsync(at)); };
            label.GestureRecognizers.Add(tap); return label;
        });
        lyrics.ItemsSource = model.LyricLines;
        timer = Dispatcher.CreateTimer(); timer.Interval = TimeSpan.FromMilliseconds(250); timer.Tick += (_, _) => Tick(); timer.Start();
        SizeChanged += (_, _) => { if (page == "playing") LayoutPlayer(); if (page == "albums") LayoutAlbums(); };
        RebuildHeader(); ApplyTheme(); Show("albums");
    }
    protected override async void OnAppearing()
    {
        base.OnAppearing(); if (initialized) return; initialized = true;
        await model.InitializeAsync(); RebuildHeader(); ApplyTheme(); Show(page);
    }
    private Label T(string text, int size = 14) => new() { Text = L(text), FontSize = size, TextColor = foreground, LineBreakMode = LineBreakMode.WordWrap };
    private Button B(string text, Func<Task> action)
    {
        var button = new Button { Text = L(text), BackgroundColor = Colors.Transparent, TextColor = accent,
            FontSize = 13, Padding = new Thickness(8, 8), CornerRadius = 12 };
        button.Clicked += async (_, _) => await Run(action); return button;
    }
    private async Task Run(Func<Task> action)
    {
        try { await action(); Tick(); } catch (Exception e) { status.Text = e.Message; }
    }
    private void RebuildHeader()
    {
        var header = new VerticalStackLayout { Spacing = 8 };
        var top = new Grid { ColumnDefinitions = { new(GridLength.Star), new(GridLength.Auto) } };
        top.Add(new Label { Text = "NegiPlayer", FontSize = 26, FontAttributes = FontAttributes.Bold, TextColor = foreground });
        top.Add(B("刷新", () => model.ReloadAsync()), 1); header.Add(top);
        var nav = new HorizontalStackLayout { Spacing = 5 };
        foreach (var (key, text) in new[] { ("albums", "专辑"), ("tracks", "所有曲目"), ("playing", "正在播放"), ("lan", "LAN 连接"), ("settings", "输出与均衡器") })
            nav.Add(B(text, () => { Show(key); return Task.CompletedTask; }));
        header.Add(new ScrollView { Orientation = ScrollOrientation.Horizontal, Content = nav });
        var old = root.Children.OfType<View>().FirstOrDefault(v => Grid.GetRow(v) == 0); if (old != null) root.Remove(old);
        root.Add(header, 0, 0);
    }
    private void Show(string target)
    {
        page = target;
        content.Content = target switch { "playing" => PlayerView(), "lan" => ConnectionView(), "settings" => SettingsView(), "tracks" => TracksView(), _ => AlbumsView() };
        Tick();
    }
    private View AlbumsView()
    {
        var layout = new Grid { RowDefinitions = { new(GridLength.Auto), new(GridLength.Star) }, RowSpacing = 16 };
        var picker = new Picker { Title = L("专辑显示方式"), TextColor = foreground, ItemsSource = new[] { L("封面网格"), L("缩略图列表") }, SelectedIndex = model.AlbumMode == "list" ? 1 : 0 };
        picker.SelectedIndexChanged += (_, _) => { model.AlbumMode = picker.SelectedIndex == 1 ? "list" : "grid"; Preferences.Set("album-mode", model.AlbumMode); Show("albums"); };
        layout.Add(picker);
        albums = new CollectionView { ItemsSource = model.Albums, SelectionMode = SelectionMode.Single, BackgroundColor = Colors.Transparent };
        albums.EmptyView = T(model.Connected ? "没有匹配的专辑" : "连接音乐主机");
        bool list = model.AlbumMode == "list";
        albums.ItemTemplate = new DataTemplate(() => AlbumCell(list));
        albums.SelectionChanged += async (_, e) => { if (e.CurrentSelection.FirstOrDefault() is RemoteAlbum album) {
            await Run(() => model.SelectAsync(album)); Show("tracks"); } };
        layout.Add(albums, 0, 1); LayoutAlbums(); return layout;
    }
    private View AlbumCell(bool list)
    {
        var image = new Image { Source = "cover_placeholder.png", Aspect = Aspect.AspectFill,
            HeightRequest = list ? 60 : 160, WidthRequest = list ? 60 : 160 };
        var title = new Label { FontSize = 15, FontAttributes = FontAttributes.Bold, TextColor = foreground, MaxLines = 2 };
        title.SetBinding(Label.TextProperty, nameof(RemoteAlbum.Title), converter: new EmptyText(L("未标记专辑")));
        var performer = new Label { FontSize = 12, TextColor = foreground.WithAlpha(0.65f), MaxLines = 1 };
        performer.SetBinding(Label.TextProperty, nameof(RemoteAlbum.Artist), converter: new EmptyText(L("未知艺人")));
        var count = new Label { FontSize = 12, TextColor = accent };
        count.SetBinding(Label.TextProperty, nameof(RemoteAlbum.Count), stringFormat: L("%d 首曲目").Replace("%d", "{0}"));
        var text = new VerticalStackLayout { Spacing = 5, Children = { title, performer, count } };
        Grid cell = list ? new Grid { ColumnDefinitions = { new(76), new(GridLength.Star) }, Padding = new Thickness(0, 10) } :
            new Grid { RowDefinitions = { new(GridLength.Auto), new(GridLength.Auto) }, RowSpacing = 9, Padding = 10 };
        cell.Add(image); if (list) cell.Add(text, 1); else cell.Add(text, 0, 1);
        cell.BindingContextChanged += async (_, _) => {
            image.Source = "cover_placeholder.png";
            if (cell.BindingContext is not RemoteAlbum a) return; string id = a.Id;
            try { var bytes = await model.CoverAsync(a.CoverTrackID);
                if (bytes != null && cell.BindingContext is RemoteAlbum current && current.Id == id)
                    image.Source = ImageSource.FromStream(() => new MemoryStream(bytes)); } catch (Exception e) when (e is HttpRequestException or HttpFailure or TaskCanceledException) { } };
        return cell;
    }
    private void LayoutAlbums()
    {
        if (albums == null) return;
        albums.ItemsLayout = model.AlbumMode == "list" ? new LinearItemsLayout(ItemsLayoutOrientation.Vertical) :
            new GridItemsLayout(Math.Max(1, (int)(Math.Max(320, Width) - 32) / 190), ItemsLayoutOrientation.Vertical) { HorizontalItemSpacing = 10, VerticalItemSpacing = 18 };
    }
    private View TracksView()
    {
        var layout = new Grid { RowDefinitions = { new(GridLength.Auto), new(GridLength.Auto), new(GridLength.Star), new(GridLength.Auto) } };
        var search = new SearchBar { Placeholder = L("搜索音乐库"), TextColor = foreground };
        search.TextChanged += async (_, e) => {
            searchDelay?.Cancel(); searchDelay = new(); var cancel = searchDelay.Token;
            try { await Task.Delay(250, cancel); await Run(() => model.SearchAsync((e.NewTextValue ?? "")[..Math.Min(e.NewTextValue?.Length ?? 0, 200)])); }
            catch (OperationCanceledException) { } };
        layout.Add(search);
        layout.Add(B(model.SelectedAlbum == null ? "全部专辑" : "返回专辑", async () => { await model.SelectAsync(null); Show("albums"); }), 0, 1);
        tracks = new CollectionView { ItemsSource = model.Tracks, SelectionMode = SelectionMode.Single };
        tracks.EmptyView = T("没有可播放曲目");
        tracks.ItemTemplate = new DataTemplate(() => {
            var grid = new Grid { RowDefinitions = { new(GridLength.Auto), new(GridLength.Auto) }, Padding = new Thickness(6, 12) };
            var title = new Label { FontSize = 16, TextColor = foreground, MaxLines = 2 }; title.SetBinding(Label.TextProperty, nameof(RemoteTrack.Title));
            var subtitle = new Label { FontSize = 12, TextColor = foreground.WithAlpha(0.65f) };
            subtitle.SetBinding(Label.TextProperty, nameof(RemoteTrack.Artist), converter: new EmptyText(L("未知艺人"))); grid.Add(title); grid.Add(subtitle, 0, 1); return grid; });
        tracks.SelectionChanged += async (_, e) => { if (e.CurrentSelection.FirstOrDefault() is RemoteTrack track && track.Playable) await Run(() => model.PlayAsync(track)); };
        layout.Add(tracks, 0, 2); layout.Add(B("加载更多", () => model.SearchAsync(search.Text ?? "", true)), 0, 3); return layout;
    }
    private View PlayerView()
    {
        lyrics.ItemsSource = model.LyricLines;
        LayoutPlayer(); return playerGrid;
    }
    private bool lastLyricsPresent;
    private void LayoutPlayer()
    {
        controls.Clear(); compactHeader.Clear(); compactFooter.Clear();
        playerGrid.Clear(); playerGrid.ColumnDefinitions.Clear(); playerGrid.RowDefinitions.Clear();
        lastLyricsPresent = model.LyricLines.Count > 0;
        Grid.SetRowSpan(cover, 1);
        if (Width < 720 && lastLyricsPresent)
        {
            playerGrid.RowSpacing = 8;
            playerGrid.RowDefinitions.Add(new(GridLength.Auto)); playerGrid.RowDefinitions.Add(new(GridLength.Star)); playerGrid.RowDefinitions.Add(new(GridLength.Auto));
            cover.WidthRequest = cover.HeightRequest = 60;
            compactHeader.Add(cover); Grid.SetRowSpan(cover, 2); compactHeader.Add(song, 1); compactHeader.Add(artist, 1, 1);
            compactFooter.Add(progress); compactFooter.Add(time); compactFooter.Add(transport); compactFooter.Add(volume);
            playerGrid.Add(compactHeader); playerGrid.Add(lyrics, 0, 1); playerGrid.Add(compactFooter, 0, 2);
            return;
        }
        playerGrid.RowSpacing = 16;
        foreach (var view in new View[] { cover, song, artist, progress, time, transport, softwareVolume, volume, path }) controls.Add(view);
        bool split = Width >= 720 && lastLyricsPresent;
        if (split) { playerGrid.ColumnDefinitions.Add(new(GridLength.Star)); playerGrid.ColumnDefinitions.Add(new(GridLength.Star)); playerGrid.Add(controlsScroll); playerGrid.Add(lyrics, 1); }
        else {
            playerGrid.RowDefinitions.Add(new(GridLength.Auto)); playerGrid.RowDefinitions.Add(new(GridLength.Star));
            playerGrid.Add(controlsScroll);
            if (model.LyricLines.Count > 0) playerGrid.Add(lyrics, 0, 1);
        }
        double available = Width < 720 && lastLyricsPresent ? Height * 0.28 : Height - 320;
        double limit = Math.Clamp(Math.Min(Width >= 720 ? Width * 0.38 : Width - 64, available), 120, 380);
        cover.WidthRequest = cover.HeightRequest = limit;
    }
    private View ConnectionView()
    {
        var panel = new VerticalStackLayout { Spacing = 14 };
        panel.Add(T("连接音乐主机", 22)); panel.Add(T("曲库只读 · 音频在本机处理"));
        var address = new Entry { Placeholder = "https://192.168.1.10:40439", Keyboard = Keyboard.Url, TextColor = foreground };
        var fingerprint = new Editor { Placeholder = L("证书 SHA-256 指纹"), AutoSize = EditorAutoSizeOption.TextChanges, TextColor = foreground, FontSize = 12 };
        var code = new Entry { Placeholder = L("8 位配对码"), Keyboard = Keyboard.Numeric, MaxLength = 8, TextColor = foreground };
        var verified = new CheckBox();
        panel.Add(address); panel.Add(fingerprint);
        var confirmation = new HorizontalStackLayout { Children = { verified, T("已核对主机完整证书指纹") } }; panel.Add(confirmation); panel.Add(code);
        address.TextChanged += (_, _) => verified.IsChecked = false; fingerprint.TextChanged += (_, _) => verified.IsChecked = false;
        panel.Add(B("配对并连接", async () => { await model.PairAsync(address.Text ?? "", fingerprint.Text ?? "", code.Text ?? "", verified.IsChecked); Show("albums"); }));
        if (model.Connected) panel.Add(B("断开并撤销配对", () => model.DisconnectAsync()));
#if WINDOWS
        panel.Add(new BoxView { HeightRequest = 1, Color = surface }); panel.Add(T("此电脑的曲库服务", 22));
        panel.Add(T("只读引用音乐，保留原文件")); panel.Add(B("导入文件夹", () => model.ImportAsync()));
        panel.Add(B("浏览本机曲库", async () => { await model.BrowseLocalAsync(); Show("albums"); }));
        panel.Add(B(model.Host == null ? "开启局域网服务" : "关闭服务", async () => { await model.ToggleHostAsync(); Show("lan"); }));
        if (model.Host != null) {
            panel.Add(hostSummary); panel.Add(B("复制连接地址", () => Clipboard.SetTextAsync(model.HostAddress)));
            panel.Add(B("复制完整指纹", () => Clipboard.SetTextAsync(model.Host.Fingerprint)));
            panel.Add(B("生成 5 分钟配对码", () => { model.RenewCode(); return Task.CompletedTask; }));
            foreach (var device in model.Host.Pairings.Snapshot()) {
                panel.Add(T(device.Name)); if (model.Host.Outputs.TryGetValue(device.Id, out var output))
                    panel.Add(new Label { Text = $"{output.Output} · {output.SampleRate:N0} Hz · EQ {output.EqEnabled} · {output.Playing}", FontSize = 12, TextColor = foreground });
                panel.Add(B("撤销配对", async () => { await model.RevokeDeviceAsync(device.Id); Show("lan"); })); }
        }
#endif
        return new ScrollView { Content = panel };
    }
    private View SettingsView()
    {
        var panel = new VerticalStackLayout { Spacing = 16 };
        panel.Add(T("外观与语言", 22));
        var theme = new Picker { Title = L("主题"), ItemsSource = new[] { "Negi", L("日间"), L("夜间") }, SelectedIndex = model.Theme == "Day" ? 1 : model.Theme == "Night" ? 2 : 0, TextColor = foreground };
        theme.SelectedIndexChanged += (_, _) => { model.Theme = theme.SelectedIndex == 1 ? "Day" : theme.SelectedIndex == 2 ? "Night" : "Negi"; Preferences.Set("theme", model.Theme); ApplyTheme(); RebuildHeader(); Show("settings"); };
        panel.Add(theme);
        var language = new Picker { Title = L("语言"), ItemsSource = new[] { "中文", "日本語", "English" }, SelectedIndex = Localizer.Language == "ja" ? 1 : Localizer.Language == "en" ? 2 : 0, TextColor = foreground };
        language.SelectedIndexChanged += (_, _) => { Localizer.Language = language.SelectedIndex == 1 ? "ja" : language.SelectedIndex == 2 ? "en" : "zh"; Preferences.Set("language", Localizer.Language); RebuildHeader(); Show("settings"); };
        panel.Add(language); panel.Add(T("输出设备", 22));
        var outputs = model.Player.Outputs;
        var output = new Picker { ItemsSource = new[] { L("系统默认输出") }.Concat(outputs.Select(x => x.Name)).ToArray(), TextColor = foreground,
            SelectedIndex = Math.Max(0, outputs.ToList().FindIndex(x => x.Id == model.Player.Settings.OutputID) + 1) };
        output.SelectedIndexChanged += async (_, _) => { string id = output.SelectedIndex > 0 ? outputs[output.SelectedIndex - 1].Id : "";
            await Run(() => model.Player.ChangeOutputAsync(id)); model.ApplySettings(model.Player.Settings); };
        panel.Add(output); panel.Add(T("采样率转换由系统处理，不宣称独占或逐比特输出"));
        panel.Add(T("10 段均衡器", 22)); var eq = new Switch { IsToggled = model.Player.Settings.EqEnabled };
        eq.Toggled += (_, e) => model.ApplySettings(model.Player.Settings with { EqEnabled = e.Value });
        panel.Add(new HorizontalStackLayout { Children = { T("启用 EQ"), eq } });
        for (int i = 0; i < 10; i++) { int band = i;
            var slider = new Slider { Minimum = -12, Maximum = 12, Value = model.Player.Settings.Gains[i] };
            var value = T($"{slider.Value:+0.0;-0.0;0.0} dB");
            slider.ValueChanged += (_, e) => { var gains = (double[])model.Player.Settings.Gains.Clone(); gains[band] = e.NewValue;
                model.ApplySettings(model.Player.Settings with { Gains = gains }); value.Text = $"{e.NewValue:+0.0;-0.0;0.0} dB"; };
            panel.Add(T(PcmDsp.Frequencies[i] < 1000 ? $"{PcmDsp.Frequencies[i]} Hz" : $"{PcmDsp.Frequencies[i] / 1000} kHz")); panel.Add(slider); panel.Add(value); }
        var preamp = new Slider { Minimum = -24, Maximum = 0, Value = model.Player.Settings.EqPreamp };
        preamp.ValueChanged += (_, e) => model.ApplySettings(model.Player.Settings with { EqPreamp = e.NewValue }); panel.Add(T("前级增益")); panel.Add(preamp);
        var loudness = new Picker { Title = L("响度统一"), ItemsSource = new[] { L("关闭"), L("逐曲响度"), L("专辑响度") },
            SelectedIndex = model.Player.Settings.LoudnessMode == "album" ? 2 : model.Player.Settings.LoudnessMode == "track" ? 1 : 0, TextColor = foreground };
        loudness.SelectedIndexChanged += (_, _) => model.ApplySettings(model.Player.Settings with { LoudnessMode = loudness.SelectedIndex == 2 ? "album" : loudness.SelectedIndex == 1 ? "track" : "off" }); panel.Add(loudness);
        var headroom = new Slider { Minimum = 0, Maximum = 24, Value = model.Player.Settings.Headroom };
        headroom.ValueChanged += (_, e) => model.ApplySettings(model.Player.Settings with { Headroom = e.NewValue }); panel.Add(T("数字余量")); panel.Add(headroom);
        panel.Add(B("重置 EQ", () => { model.ApplySettings(model.Player.Settings with { Gains = new double[10], EqPreamp = -6 }); Show("settings"); return Task.CompletedTask; }));
        return new ScrollView { Content = panel };
    }
    private void ApplyTheme()
    {
        bool day = model.Theme == "Day"; foreground = Color.FromArgb(day ? "#1F2937" : "#EDF2F5");
        surface = Color.FromArgb(day ? "#E9EEF2" : "#202D33"); accent = Color.FromArgb(model.Theme == "Negi" ? "#37BFB5" : day ? "#2779BD" : "#7DC5F2");
        BackgroundColor = Color.FromArgb(day ? "#F7F9FB" : model.Theme == "Negi" ? "#101E21" : "#11151D");
        status.TextColor = foreground.WithAlpha(0.65f); song.TextColor = artist.TextColor = path.TextColor = time.TextColor = foreground;
        play.TextColor = accent; progress.MinimumTrackColor = accent;
    }
    private void Tick()
    {
        if (!MainThread.IsMainThread) { MainThread.BeginInvokeOnMainThread(Tick); return; }
        song.Text = model.Current?.Title ?? L("未选择曲目"); artist.Text = model.Current?.Artist ?? "";
        softwareVolume.Text = L("软件音量"); softwareVolume.TextColor = foreground;
        volume.Maximum = Math.Max(0.001, model.Player.Settings.VolumeLimit);
        if (Math.Abs(volume.Value - model.Player.Settings.Volume) > 0.0001) volume.Value = model.Player.Settings.Volume;
        path.Text = model.Current == null ? model.Player.Output : $"{model.Player.SourceRate:N0} Hz PCM → {(model.Player.Settings.EqEnabled ? "EQ · " : "")}{L("软件音量")} → {model.Player.Output}";
        status.Text = model.Player.Error ?? L(model.Status); play.Text = model.Player.Playing ? "Ⅱ" : "▶";
        if (!dragging) { progress.Maximum = Math.Max(0.01, model.Player.Duration); progress.Value = Math.Min(progress.Maximum, model.Player.Position); }
        static string Clock(double seconds) => $"{(int)Math.Max(0, seconds) / 60}:{(int)Math.Max(0, seconds) % 60:D2}";
        time.Text = Clock(model.Player.Position) + " / " + Clock(model.Player.Duration);
        if (displayedCover != model.Cover) { displayedCover = model.Cover; var image = displayedCover;
            cover.Source = image == null ? "cover_placeholder.png" : ImageSource.FromStream(() => new MemoryStream(image)); }
        if (page == "playing" && lastLyricsPresent != (model.LyricLines.Count > 0)) LayoutPlayer();
        int next = Lyrics.Active(model.LyricLines, model.Player.Position);
        int activeID = next >= 0 ? model.LyricLines[next].Id : -1;
        lyricLabels.RemoveAll(reference => !reference.TryGetTarget(out _));
        foreach (var reference in lyricLabels)
            if (reference.TryGetTarget(out var label) && label.BindingContext is LyricLine line) {
                label.TextColor = line.Id == activeID ? accent : foreground.WithAlpha(0.6f);
                label.FontAttributes = line.Id == activeID ? FontAttributes.Bold : FontAttributes.None;
            }
        if (follow && next >= 0 && next != activeLyric && page == "playing") { activeLyric = next; lyrics.ScrollTo(next, position: ScrollToPosition.Center, animate: true); }
#if WINDOWS
        if (model.Host != null) hostSummary.Text = model.HostAddress + "\n" + model.Host.Fingerprint + "\n" + model.HostCode;
#endif
        if (++ticks % 40 == 0) _ = model.ReportAsync();
    }
    private sealed class EmptyText(string placeholder) : IValueConverter
    {
        public object Convert(object? value, Type type, object? parameter, System.Globalization.CultureInfo culture) =>
            string.IsNullOrWhiteSpace(value?.ToString()) ? placeholder : value!.ToString()!;
        public object ConvertBack(object? value, Type type, object? parameter, System.Globalization.CultureInfo culture) => throw new NotSupportedException();
    }
}
