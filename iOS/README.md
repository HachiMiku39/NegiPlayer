# NegiPlayer iOS

Native iPhone/iPad endpoint for the NegiPlayer Mac library. Open `NegiPlayeriOS.xcodeproj` with Xcode 27.1 or later for iPhone Duo's native window and navigation adaptation. The deployment target is iOS 17. The project directly references shared LAN protocol, appearance, translations and listening preferences in the repository; it does not download packages or a Mac SQLite database.

## Build and install

Select `NegiPlayeriOS`, choose your iPhone/iPad, and choose your own development team in Signing & Capabilities. Change the bundle identifier if required by your team, then build and run. A signed device build or TestFlight distribution needs your Apple developer signing configuration. No unsigned IPA is provided as an installable release.

An unsigned compilation check:

```sh
xcodebuild -project iOS/NegiPlayeriOS.xcodeproj -scheme NegiPlayeriOS \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/NegiPlayer-iOS CODE_SIGNING_ALLOWED=NO build
```

## Pairing

1. On Mac, reference your music folder, open **iOS connection**, and turn on the LAN service. The default HTTPS port is 40439. Allow the expected Local Network permission and app firewall access.
2. On iOS, open Settings → Pairing. Search for the Mac or enter the HTTPS `.local` address and port shown on the Mac.
3. Compare the **entire SHA-256 certificate fingerprint** on both screens. Bonjour discovery is a convenience, not trust verification. Confirm the match, generate the Mac's eight-digit code and pair within five minutes. Each code works once and locks after ten failed attempts.
4. The iOS token stays in this device's Keychain. The Mac stores only its hash. Mac can revoke an endpoint; iOS can disconnect and remove pairing. Mac must remain awake with the drive mounted and service enabled.

The Mac service never starts automatically. There is no internet relay or cloud login. The client requires the confirmed certificate, rejects redirects, and sends bearer credentials in HTTPS headers. This is a local music service, not a general file browser or remote database editor.

## Audio and video

Mac reads authorized audio files and exposes seekable float32 little-endian interleaved PCM, retaining the decoded source rate and mono/stereo channels. Mac volume, EQ, ReplayGain and output-device processing are bypassed for this stream. iOS deinterleaves PCM into AVAudioPlayerNode → three bounded metadata-gain stages → 10-band AVAudioUnitEQ → mixer/system output. It handles local EQ, preamp, ReplayGain, peak-tag protection, headroom, software volume, queue, seek and background audio. In-memory prefetch is bounded to four seconds plus one response. There is no deliberate offline music cache.

USB audio uses the iOS AVAudioSession route. The UI shows the real active route and sample rate; the selected preferred rate is only a request. Removing an audio device pauses playback. Hardware support, power requirements and sample-rate conversion depend on iOS and the connected DAC. Exclusive, DoP and bit-perfect output are not claimed. DSD, ISO and unsupported multichannel files cannot enter the mobile playback queue.

Default listening shows album artwork and matched Mac LRC. With sufficient current window width and height, artwork/controls sit left and scrolling lyrics sit right. Without lyrics, the cover remains centered. Scroll manually to pause following; tap a timed line to seek. Compact windows stack the content.

MV is available only for a unique same-stem `.mp4`, `.m4v` or `.mov` in the audio folder, within its authorized root. Tap MV to opt in. The player composition inserts **only the video track**, and additionally enforces mute and zero volume. Song PCM remains the sole audio source. The video follows the audio clock; failed or absent video falls back to the cover and lyrics. No downloaded, online or character video is bundled.

## Appearance and iPhone Duo

Both apps offer Negi (teal/pink), Day (light neutral) and Night (dark neutral), with Chinese, Japanese and English UI selection. Song tags and lyric text retain their original language. Theme/language changes keep the audio model alive. Both platforms use the same neutral N/leaf/play icon.

Duo layouts use the current SwiftUI window size, never a fixed screen, orientation, device name or UIScreen.main. The expanded window can show a library split view and a player/lyrics split view; compact cover windows use the same audio session in a single-column view. This follows [Apple's iPhone Duo preparation guidance](https://developer.apple.com/iphone-duo/prepare/). Open/closed window changes were checked in the iPhone Duo simulator. Physical folding, background transitions and iOS USB DAC output still require device testing.

## Verification status

Unsigned iOS device SDK and locally signed simulator builds passed. The shared HTTPS client and Mac server passed pairing, wrong-pin rejection, range/seek, LRC offset and revoke integration tests; source PCM was compared sample-for-sample. Device Hub ran the iPhone Duo iOS 27.1 simulator: Bonjour discovery, fingerprint pairing, Keychain pairing restoration, artwork/LRC playback, EQ settings, a video-only MV synchronized to a 12.2-second lyric seek, and Day/Night/Negi with English/Japanese/Chinese UI were checked. The simulator does not validate iOS USB hardware, physical folding or physical Local Network permission prompts. No physical endpoint has been signed or tested yet. See [VALIDATION.md](../VALIDATION.md).

Apple references: [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine), [AVAudioSession preferences](https://developer.apple.com/library/archive/qa/qa1631/_index.html), [USB route](https://developer.apple.com/documentation/avfaudio/avaudiosession/port/usbaudio), [Local Network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [manual server trust](https://developer.apple.com/documentation/Foundation/performing-manual-server-trust-authentication).
