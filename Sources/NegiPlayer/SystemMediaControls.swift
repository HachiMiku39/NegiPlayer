import Foundation
import MediaPlayer
import Combine
import AudioCore

/// Publishes this app's session to macOS using public APIs. It never controls other apps.
@MainActor final class SystemMediaControls {
    private weak var playback: PlaybackSession?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var publishedID: String?
    private var enabled = false
    init(playback: PlaybackSession) {
        self.playback = playback
        playback.$isPlaying.combineLatest(playback.$current)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.publish() }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        playback.onMediaControlsChanged = { [weak self] value in self?.setEnabled(value) }
        setEnabled(playback.mediaControls)
    }
    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (PlaybackSession, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let token = command.addTarget { [weak self] event in
            let perform = {
                MainActor.assumeIsolated {
                    guard let self, self.enabled, let p = self.playback, p.current != nil else { return MPRemoteCommandHandlerStatus.noSuchContent }
                    return action(p,event)
                }
            }
            return Thread.isMainThread ? perform() : DispatchQueue.main.sync(execute: perform)
        }
        targets.append((command,token))
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }; enabled = value
        let center = MPRemoteCommandCenter.shared()
        if value {
            register(center.playCommand) { p,_ in do { try p.start(); return .success } catch { return .commandFailed } }
            register(center.pauseCommand) { p,_ in p.pause(); return .success }
            register(center.togglePlayPauseCommand) { p,_ in do { try p.toggle(); return .success } catch { return .commandFailed } }
            register(center.nextTrackCommand) { p,_ in guard p.nextItem != nil else { return .noSuchContent }; p.advance(); return .success }
            register(center.previousTrackCommand) { p,_ in p.previous(); return .success }
            register(center.changePlaybackPositionCommand) { p,event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                do { try p.seek(to:event.positionTime); return .success } catch { return .commandFailed }
            }
            publish()
        } else {
            for (command,target) in targets { command.removeTarget(target); command.isEnabled = false }
            targets.removeAll(); MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped; publishedID = nil
        }
    }
    private func publish() {
        guard enabled, let p = playback, let media = p.current else { return }
        let center = MPNowPlayingInfoCenter.default()
        var info = center.nowPlayingInfo ?? [:]
        if publishedID != media.id {
            info = [MPMediaItemPropertyTitle:media.title, MPMediaItemPropertyArtist:media.artistDisplay,
                    MPMediaItemPropertyAlbumTitle:media.albumDisplay, MPMediaItemPropertyPlaybackDuration:p.duration,
                    MPNowPlayingInfoPropertyMediaType:MPNowPlayingInfoMediaType.audio.rawValue,
                    MPNowPlayingInfoPropertyExternalContentIdentifier:media.id]
            publishedID = media.id
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = p.isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        center.nowPlayingInfo = info; center.playbackState = p.isPlaying ? .playing : .paused
    }
    deinit {
        timer?.invalidate()
        for (command,target) in targets { command.removeTarget(target) }
    }
}
