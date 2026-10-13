# NegiPlayer 0.5 cross-platform LAN preview

Windows and Android use native .NET MAUI controls and the shared C# Negi LAN v1 client. The existing macOS and iOS applications remain native SwiftUI applications. Windows also implements the same read-only host protocol; macOS can connect to a Windows host as a playback endpoint.

| Host | Windows endpoint | macOS endpoint | iOS endpoint | Android endpoint |
| --- | --- | --- | --- | --- |
| macOS | LAN v1 | LAN v1 | LAN v1 | LAN v1 |
| Windows | LAN v1 | LAN v1 | LAN v1 | LAN v1 |

Mobile devices browse the host's API without receiving a writable database or storing music files. Hosts import folder references and read existing metadata/artwork/LRC without writing tags or copying the music. Each endpoint has its own software volume, 10-band EQ, ReplayGain/headroom and native output route. macOS/iOS video support is unchanged; new Windows/Android endpoints initially use artwork and lyrics.

Windows uses WASAPI shared mode with an explicit output-device selector. Android uses AudioTrack float PCM, audio focus, a foreground playback service and a preferred USB/system-device request. Windows displays the output mix format; Android displays its client format and routed device because the hardware clock is not exposed by this API. Neither promises exclusive or bit-perfect output. Removing the selected output pauses playback.

Windows hosts start manually, use TLS certificate pinning, five-minute one-use pairing codes with a ten-failure lock, hashed paired tokens, and source streams bounded to 256 KiB per request. Windows private keys and endpoint credentials use the OS-protected MAUI SecureStorage store; Android uses Android Keystore-backed SecureStorage and disables backup. Certificate fingerprints must be matched in full. Do not forward the LAN service port to the Internet.

## Build

GitHub Actions builds the Windows portable application and a bundled Android development APK, and runs protocol tests. Install .NET 10 and the matching MAUI workload to reproduce. The workflow pins action commits and publishes only application binaries and synthetic test reports.

```powershell
dotnet workload install maui-windows
dotnet publish cross/NegiPlayer.Mobile -f net10.0-windows10.0.19041.0 -c Release -r win-x64 -p:NegiWindowsOnly=true -p:WindowsPackageType=None -p:WindowsAppSDKSelfContained=true --self-contained true
```

```sh
dotnet workload install maui-android
dotnet build cross/NegiPlayer.Mobile -f net10.0-android -c Debug -p:EmbedAssembliesIntoApk=true
dotnet run --project cross/NegiPlayer.Conformance -c Release
```

The Android development APK has an ephemeral CI debug signature; it is for testing, not a Play Store release. A new CI run can use a different debug key and require uninstalling the previous development APK. Stable release signing requires the owner's signing configuration. Windows ZIPs are portable, self-contained development builds without a publisher signature.

Compiled successfully does not mean that physical USB DACs, Bluetooth routing, long-duration/background playback, or every Media Foundation codec have been verified. See the workflow results and interoperability reports for the actual validation scope.
