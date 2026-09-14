import Foundation
@preconcurrency import AVFoundation

@MainActor
final class PlayerState: NSObject, ObservableObject {
    @Published private(set) var currentTrack: FileItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var sourcePane: String?
    @Published var volume: Double = 0.8 { didSet { applyVolume() } }
    @Published var playbackNote: String?

    private enum Engine { case none, avaudio, avplayer, embedded, midi }
    private var activeEngine: Engine = .none

    // Engine A: native AVAudioFile
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var engineFile: AVAudioFile?
    private var scheduledStartFrame: AVAudioFramePosition = 0

    // Engine B: AVPlayer fallback
    private var fallbackPlayer: AVPlayer?
    private var fallbackTimeObserver: Any?
    private var endObserver: NSObjectProtocol?

    // Engine C: embedded decoders (trackers / ogg / voc) via AVAudioSourceNode
    private var engineC: AVAudioEngine?
    private var srcNode: AVAudioSourceNode?
    private var pullDecoder: PullDecoder?
    private let engineCLock = NSLock()
    private var engineCSeekTarget: TimeInterval?
    private var engineCEnded = false
    private var engineCScratch: UnsafeMutablePointer<Float>?
    private var engineCScratchFrames = 8192

    // Engine D: MIDI
    private var midiPlayer: AVMIDIPlayer?
    private var midiPausedPosition: TimeInterval?

    private var queue: [FileItem] = []
    private var queueIndex = 0
    private var userPaused = false
    private var failuresInARow = 0
    private var ticker: Timer?

    // MARK: - Queue control

    func playQueue(items: [FileItem], index: Int, paneLabel: String) {
        guard !items.isEmpty else { return }
        queue = items
        queueIndex = min(max(0, index), items.count - 1)
        sourcePane = paneLabel
        playCurrent()
    }

    func togglePause() {
        switch activeEngine {
        case .avaudio:
            guard let node = playerNode else { return }
            if node.isPlaying {
                node.pause()
                isPlaying = false
                userPaused = true
            } else {
                node.play()
                isPlaying = true
                userPaused = false
            }
        case .avplayer:
            guard let player = fallbackPlayer else { return }
            if player.timeControlStatus == .playing {
                player.pause()
                isPlaying = false
                userPaused = true
            } else {
                player.play()
                isPlaying = true
                userPaused = false
            }
        case .embedded:
            engineCLock.lock()
            userPaused.toggle()
            let paused = userPaused
            engineCLock.unlock()
            isPlaying = !paused
        case .midi:
            guard let player = midiPlayer else { return }
            if player.isPlaying {
                midiPausedPosition = player.currentPosition
                player.stop()
                isPlaying = false
                userPaused = true
            } else {
                if let pos = midiPausedPosition { player.currentPosition = pos }
                player.play { [weak self] in
                    Task { @MainActor [weak self] in self?.midiFinished(player) }
                }
                isPlaying = true
                userPaused = false
                midiPausedPosition = nil
            }
        case .none:
            break
        }
    }

    func stopPlayback() {
        teardownPlayback()
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        queue.removeAll()
        queueIndex = 0
        failuresInARow = 0
    }

    func next() {
        guard !queue.isEmpty else { return }
        queueIndex = (queueIndex + 1) % queue.count
        playCurrent()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3.0 {
            seek(to: 0)
            return
        }
        queueIndex = (queueIndex - 1 + queue.count) % queue.count
        playCurrent()
    }

    // MARK: - Playback core

    private func playCurrent() {
        guard queue.indices.contains(queueIndex) else { return }
        let item = queue[queueIndex]
        teardownPlayback()
        currentTrack = item
        currentTime = 0
        duration = item.duration ?? 0

        let ext = (item.name as NSString).pathExtension
        let route = AudioFormats.route(forExtension: ext)
        var started = false

        switch route {
        case .midi:
            started = startEngineD(url: item.url)
            if started { activeEngine = .midi }
        case .embedded:
            started = startEngineC(url: item.url)
            if started { activeEngine = .embedded }
            if !started, startEngineB(url: item.url) {
                activeEngine = .avplayer
                started = true
            }
        case .native:
            if startEngineA(url: item.url) {
                activeEngine = .avaudio
                started = true
            } else if startEngineB(url: item.url) {
                activeEngine = .avplayer
                started = true
            } else if startEngineC(url: item.url) {
                activeEngine = .embedded
                started = true
            }
        }

        if !started {
            handleUnplayableCurrent()
            return
        }
        failuresInARow = 0
        isPlaying = true
        userPaused = false
        startTicker()
    }

    private func startEngineA(url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            engine.mainMixerNode.outputVolume = Float(volume)
            try engine.start()
            node.scheduleFile(file, at: nil)
            node.play()
            audioEngine = engine
            playerNode = node
            engineFile = file
            scheduledStartFrame = 0
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            if seconds.isFinite, seconds > 0 { duration = seconds }
            return true
        } catch {
            teardownEngineA()
            return false
        }
    }

    private func startEngineB(url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(volume)

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        fallbackTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.fallbackTicked(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.trackEnded() }
        }

        fallbackPlayer = player
        player.play()

        Task { [weak self] in
            if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
                self?.duration = d.seconds
            }
        }
        let trackId = url.path
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.activeEngine == .avplayer,
                  self.currentTrack?.id == trackId else { return }
            if self.currentTime < 0.05 && !self.userPaused {
                self.handleUnplayableCurrent()
            }
        }
        return true
    }

    /// Engine C: pull-decoder feeding an AVAudioSourceNode.
    /// All formats render as interleaved stereo f32 @44100 in C land.
    private func startEngineC(url: URL) -> Bool {
        guard let dec = PullDecoder(url: url) else { return false }

        let scratch = UnsafeMutablePointer<Float>.allocate(
            capacity: engineCScratchFrames * 2)
        scratch.initialize(repeating: 0, count: engineCScratchFrames * 2)

        let lock = engineCLock
        pullDecoder = dec
        engineCEnded = false
        engineCSeekTarget = nil
        engineCScratch = scratch

        if dec.duration > 0 { duration = dec.duration }

        let render: AVAudioSourceNodeRenderBlock = { [weak self] _, _, frameCount, abl in
            guard let self else { return noErr }
            let frames = Int(frameCount)
            var outL: UnsafeMutablePointer<Float>?
            var outR: UnsafeMutablePointer<Float>?
            let list = UnsafeMutableAudioBufferListPointer(abl)
            if list.count > 0 { outL = list[0].mData?.assumingMemoryBound(to: Float.self) }
            if list.count > 1 { outR = list[1].mData?.assumingMemoryBound(to: Float.self) }

            lock.lock()
            defer { lock.unlock() }

            guard let dec = self.pullDecoder else { return noErr }

            if let target = self.engineCSeekTarget {
                _ = dec.seek(to: target)
                self.engineCSeekTarget = nil
            }

            var produced = 0
            if !self.userPaused {
                produced = dec.render(into: scratch, frames: min(frames, self.engineCScratchFrames))
                if produced == 0 { self.engineCEnded = true }
            } else {
                self.engineCEnded = false
            }

            if let outL, let outR {
                for i in 0..<frames {
                    if i < produced {
                        outL[i] = scratch[i * 2]
                        outR[i] = scratch[i * 2 + 1]
                    } else {
                        outL[i] = 0
                        outR[i] = 0
                    }
                }
            }
            self.currentTime = dec.position
            return noErr
        }

        do {
            let engine = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let node = AVAudioSourceNode(format: format, renderBlock: render)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = Float(volume)
            try engine.start()
            engineC = engine
            srcNode = node
        } catch {
            scratch.deallocate()
            engineCScratch = nil
            pullDecoder = nil
            return false
        }
        return true
    }

    private func startEngineD(url: URL) -> Bool {
        guard let player = try? AVMIDIPlayer(contentsOf: url, soundBankURL: nil)
        else { return false }
        midiPlayer = player
        midiPausedPosition = nil
        let d = player.duration
        if d.isFinite, d > 0 { duration = d }
        player.prepareToPlay()
        player.play { [weak self] in
            Task { @MainActor [weak self] in self?.midiFinished(player) }
        }
        return true
    }

    private func midiFinished(_ player: AVMIDIPlayer) {
        guard midiPlayer === player, activeEngine == .midi,
              currentTrack != nil else { return }
        if userPaused || midiPausedPosition != nil { return }
        if duration <= 0 || currentTime >= max(0, duration - 0.5) {
            trackEnded()
        }
    }

    private func fallbackTicked(_ seconds: Double) {
        guard let item = fallbackPlayer?.currentItem else { return }
        if item.status == .failed {
            handleUnplayableCurrent()
            return
        }
        if seconds.isFinite, seconds >= 0 {
            currentTime = seconds
        }
    }

    private func handleUnplayableCurrent() {
        teardownPlayback()
        failuresInARow += 1
        let name = currentTrack?.name ?? "file"
        if failuresInARow >= max(1, queue.count) {
            playbackNote = AppSettings.shared.t("noPlayable")
            stopPlayback()
            failuresInARow = 0
        } else {
            playbackNote = AppSettings.shared.tf("cantDecode", name)
            next()
        }
    }

    private func trackEnded() {
        guard currentTrack != nil else { return }
        if queueIndex + 1 < queue.count {
            queueIndex += 1
            playCurrent()
        } else {
            stopPlayback()
        }
    }

    // MARK: - Seek & position

    func seek(to target: TimeInterval) {
        let clamped = min(max(0, target), max(0, duration))
        switch activeEngine {
        case .avaudio:
            guard let file = engineFile, let node = playerNode,
                  let engine = audioEngine, engine.isRunning else { return }
            let sampleRate = file.processingFormat.sampleRate
            let totalFrames = AVAudioFramePosition(file.length)
            var frame = AVAudioFramePosition((clamped * sampleRate).rounded())
            frame = min(max(0, frame), max(0, totalFrames - 1))
            scheduledStartFrame = frame
            node.stop()
            let remaining = AVAudioFrameCount(totalFrames - frame)
            if remaining > 0 {
                node.scheduleSegment(file, startingFrame: frame,
                                     frameCount: remaining, at: nil)
                if isPlaying && !userPaused { node.play() }
            }
            currentTime = clamped
        case .avplayer:
            guard let player = fallbackPlayer else { return }
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = clamped
        case .embedded:
            engineCLock.lock()
            engineCSeekTarget = clamped
            currentTime = clamped
            engineCEnded = false
            engineCLock.unlock()
        case .midi:
            guard let player = midiPlayer else { return }
            player.currentPosition = clamped
            currentTime = clamped
            if !player.isPlaying && userPaused {
                midiPausedPosition = clamped
            }
        case .none:
            break
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.ticked() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func ticked() {
        switch activeEngine {
        case .avaudio:
            guard let node = playerNode, let engine = audioEngine, engine.isRunning
            else { return }
            if let renderTime = node.lastRenderTime,
               let playerTime = node.playerTime(forNodeTime: renderTime),
               playerTime.sampleRate > 0 {
                let position = (Double(playerTime.sampleTime) + Double(scheduledStartFrame))
                    / playerTime.sampleRate
                if position.isFinite, position >= 0 {
                    currentTime = min(position, duration)
                }
            }
            if isPlaying && !userPaused && !node.isPlaying
                && duration > 0 && currentTime >= duration - 0.25 {
                trackEnded()
            }
        case .avplayer:
            break // position arrives via periodic observer
        case .embedded:
            engineCLock.lock()
            let ended = engineCEnded
            engineCLock.unlock()
            if ended && isPlaying && !userPaused {
                trackEnded()
            }
        case .midi:
            if let player = midiPlayer {
                currentTime = player.currentPosition
            }
        case .none:
            break
        }
    }

    // MARK: - Teardown

    private func applyVolume() {
        audioEngine?.mainMixerNode.outputVolume = Float(volume)
        fallbackPlayer?.volume = Float(volume)
        engineC?.mainMixerNode.outputVolume = Float(volume)
    }

    private func teardownPlayback() {
        ticker?.invalidate()
        ticker = nil
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        if let observer = fallbackTimeObserver {
            fallbackPlayer?.removeTimeObserver(observer)
            fallbackTimeObserver = nil
        }
        fallbackPlayer?.pause()
        fallbackPlayer = nil

        // Engine C: detach source node while holding lock so render block stops.
        engineCLock.lock()
        pullDecoder = nil
        engineCSeekTarget = nil
        engineCEnded = false
        engineCLock.unlock()
        if let engine = engineC {
            engine.stop()
        }
        srcNode = nil
        engineC = nil
        if let scratch = engineCScratch {
            scratch.deallocate()
            engineCScratch = nil
        }
        pullDecoder = nil

        midiPlayer?.stop()
        midiPlayer = nil
        midiPausedPosition = nil

        teardownEngineA()
        activeEngine = .none
        userPaused = false
    }

    private func teardownEngineA() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        engineFile = nil
        scheduledStartFrame = 0
    }
}
