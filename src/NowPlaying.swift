import Foundation
import MediaPlayer

enum RemoteAction {
    case play, pause, togglePlayPause, next, previous, stop
    case seek(to: TimeInterval)
    case skip(by: TimeInterval)
}

enum NowPlaying {
    private static var tokens: [Any] = []
    private static var installed = false
    private static var lastPublish = Date.distantPast

    static func installCommands() {
        guard !installed else { return }
        installed = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]

        tokens.append(center.playCommand.addTarget { _ in
            dispatch(.play); return .success
        })
        tokens.append(center.pauseCommand.addTarget { _ in
            dispatch(.pause); return .success
        })
        tokens.append(center.togglePlayPauseCommand.addTarget { _ in
            dispatch(.togglePlayPause); return .success
        })
        tokens.append(center.stopCommand.addTarget { _ in
            dispatch(.stop); return .success
        })
        tokens.append(center.nextTrackCommand.addTarget { _ in
            dispatch(.next); return .success
        })
        tokens.append(center.previousTrackCommand.addTarget { _ in
            dispatch(.previous); return .success
        })
        tokens.append(center.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            dispatch(.seek(to: e.positionTime)); return .success
        })
        tokens.append(center.skipForwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            dispatch(.skip(by: interval)); return .success
        })
        tokens.append(center.skipBackwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            dispatch(.skip(by: -interval)); return .success
        })
    }

    private static func dispatch(_ action: RemoteAction) {
        Task { @MainActor in
            handle(action)
        }
    }

    @MainActor
    static func handle(_ action: RemoteAction) {
        let player = CommanderStore.shared.player
        switch action {
        case .play:
            if player.currentTrack != nil, !player.isPlaying { player.togglePause() }
        case .pause:
            if player.isPlaying { player.togglePause() }
        case .togglePlayPause:
            player.togglePause()
        case .next:
            player.next()
        case .previous:
            player.previous()
        case .stop:
            player.stopPlayback()
        case .seek(let t):
            player.seek(to: t)
        case .skip(let delta):
            player.seek(to: player.currentTime + delta)
        }
    }

    @MainActor
    static func publish(track: FileItem?, elapsed: TimeInterval, duration: TimeInterval,
                        rate: Double, sourcePane: String?, hasNext: Bool, hasPrevious: Bool) {
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard let track else {
            clear()
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: (track.name as NSString).deletingPathExtension,
            MPMediaItemPropertyArtist: sourcePane ?? "AudioCommander",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id,
            MPMediaItemPropertyPlaybackDuration: max(0, duration)
        ]
        info[MPMediaItemPropertyAssetURL] = track.url
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = rate > 0 ? .playing : .paused
        lastPublish = Date()

        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = hasNext
        center.previousTrackCommand.isEnabled = hasPrevious
        center.changePlaybackPositionCommand.isEnabled = duration > 0
    }

    @MainActor
    static func clear() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    /// Throttled refresh for the elapsed-time scrubber, called from the
    /// player ticker. Non-playing engines are published by their own paths.
    @MainActor
    static func tickPosition(elapsed: TimeInterval, duration: TimeInterval) {
        guard Date().timeIntervalSince(lastPublish) >= 1.0 else { return }
        let player = CommanderStore.shared.player
        publish(track: player.currentTrack, elapsed: elapsed, duration: duration,
                rate: player.isActivelyPlaying ? 1.0 : 0.0,
                sourcePane: player.sourcePane,
                hasNext: player.hasNext, hasPrevious: player.hasPrevious)
    }
}
