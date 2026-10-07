import Foundation
import Combine
@preconcurrency import AVFoundation

enum RepeatMode: Int, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        RepeatMode(rawValue: (rawValue + 1) % 3) ?? .off
    }

    var systemImage: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

@MainActor
final class PlayerState: NSObject, ObservableObject {
    @Published private(set) var currentTrack: FileItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var sourcePane: String?
    @Published var volume: Double = 0.8 {
        didSet { applyVolume(); UserDefaults.standard.set(volume, forKey: "ac_volume") }
    }
    @Published var playbackNote: String?

    @Published var shuffleMode: Bool = false {
        didSet {
            guard shuffleMode != oldValue else { return }
            UserDefaults.standard.set(shuffleMode, forKey: "ac_shuffle")
            reshuffleKeepingCurrent()
        }
    }

    @Published var repeatMode: RepeatMode = .off {
        didSet {
            guard repeatMode != oldValue else { return }
            UserDefaults.standard.set(repeatMode.rawValue, forKey: "ac_repeat")
            publishNowPlaying()
        }
    }

    @Published var sleepMinutes: Int = 0 {
        didSet {
            UserDefaults.standard.set(sleepMinutes, forKey: "ac_sleep_min")
            rescheduleSleepTimer()
        }
    }

    /// #17 equalizer state shared with the Effects tab. Same singleton pattern
    /// as SpectrumAnalyzer: PlayerState inserts the EQ node into each engine,
    /// the tab reads/edits the same object.
    let equalizer = Equalizer.shared

    /// #19 ReplayGain store. The gain it offers for the current track is folded
    /// into the master volume whenever a track starts or the mode changes.
    let replayGain = ReplayGainStore.shared

    /// Track transition behaviour (#14). Default off, so the proven
    /// stop-then-start path is untouched unless the user opts in.
    @Published var crossfade: CrossfadeOption = .off {
        didSet {
            guard crossfade != oldValue else { return }
            UserDefaults.standard.set(crossfade.rawValue, forKey: "ac_crossfade")
            if !crossfade.isEnabled { cancelCrossfade() }
        }
    }

    private enum Engine { case none, avaudio, avplayer, embedded, midi }
    private var activeEngine: Engine = .none

    // Engine A: native AVAudioFile
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var engineFile: AVAudioFile?
    private var scheduledStartFrame: AVAudioFramePosition = 0

    // Live EQ insert (#17) per engine. Only the in-app engines can host it;
    // the AVPlayer fallback and AVMIDIPlayer paths stay flat.
    private var eqNodeA: AVAudioUnitEQ?
    private var eqNodeC: AVAudioUnitEQ?
    private var eqNodeE: AVAudioUnitEQ?

    // Engine A transition (#14): a second engine started just before the
    // outgoing track ends, so gapless/crossfade needs no teardown gap.
    private var xfEngine: AVAudioEngine?
    private var xfNode: AVAudioPlayerNode?
    private var xfFile: AVAudioFile?
    private var xfIndex: Int?
    private var xfStartedAt: TimeInterval = 0
    private var xfOverlap: Double = 0
    private var xfTimer: Timer?
    private var isTransitioning = false
    private var xfEQ: AVAudioUnitEQ?

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
    // Engine E: MIDI via AVAudioSequencer -> AVAudioUnitSampler (stutter fix)
    private var midiSampler = false
    private var eEngine: AVAudioEngine?
    private var eSampler: AVAudioUnitSampler?
    private var eSequencer: AVAudioSequencer?
    private var midiEnded = false
    private let gsBankURL = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    private var baseQueue: [FileItem] = []
    private var queue: [FileItem] = []
    private var queueIndex = 0
    private var userPaused = false
    private var failuresInARow = 0
    private var ticker: Timer?
    private var sleepActivity: NSObjectProtocol?
    private var sleepTimer: Timer?
    private var replayGainObserver: Any?

    var hasNext: Bool { queueIndex + 1 < queue.count || repeatMode == .all }
    var hasPrevious: Bool { queue.count > 1 || currentTime > 0.5 }
    var isActivelyPlaying: Bool { isPlaying && !userPaused }

    private func setPreventSleep(_ active: Bool) {
        if active, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "AudioCommander is playing audio")
        } else if !active, let token = sleepActivity {
            ProcessInfo.processInfo.endActivity(token)
            sleepActivity = nil
        }
    }

    // MARK: - Queue control

    override init() {
        super.init()
        let stored = UserDefaults.standard.double(forKey: "ac_volume")
        if stored > 0 { volume = stored }
        sleepMinutes = UserDefaults.standard.integer(forKey: "ac_sleep_min")
        shuffleMode = UserDefaults.standard.bool(forKey: "ac_shuffle")
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "ac_repeat")) ?? .off
        crossfade = CrossfadeOption(rawValue: UserDefaults.standard.integer(forKey: "ac_crossfade")) ?? .off
        replayGainObserver = replayGain.$mode.sink { [weak self] _ in
            self?.applyVolume()
        }
    }

    /// Builds the play order. Shuffled starts at the requested track and
    /// permutes everything after it, so the click that started playback is
    /// always heard first.
    private func makePlayOrder(from items: [FileItem], startAt index: Int) -> [FileItem] {
        guard shuffleMode, items.count > 1 else { return items }
        let first = min(max(0, index), items.count - 1)
        var rest = Array(items.indices.filter { $0 != first })
        rest.shuffle()
        return [items[first]] + rest.map { items[$0] }
    }

    /// Re-applies shuffle without interrupting the current track: it is
    /// pinned to the front and the remainder is re-permuted.
    private func reshuffleKeepingCurrent() {
        guard !baseQueue.isEmpty else { return }
        guard shuffleMode else {
            if let current = currentTrack,
               let restored = baseQueue.firstIndex(where: { $0.id == current.id }) {
                queue = baseQueue
                queueIndex = restored
            } else {
                queue = baseQueue
                queueIndex = min(queueIndex, max(0, baseQueue.count - 1))
            }
            publishNowPlaying()
            return
        }
        var currentId = currentTrack?.id
        if currentId == nil, baseQueue.indices.contains(queueIndex) {
            currentId = baseQueue[queueIndex].id
        }
        let remaining = baseQueue.filter { $0.id != currentId }
        var shuffledRest = remaining
        shuffledRest.shuffle()
        if let currentId, let item = baseQueue.first(where: { $0.id == currentId }) {
            queue = [item] + shuffledRest
            queueIndex = 0
        } else {
            queue = baseQueue.shuffled()
            queueIndex = 0
        }
        publishNowPlaying()
    }

    private func rescheduleSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard sleepMinutes > 0 else { return }
        let t = Timer(timeInterval: TimeInterval(sleepMinutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sleepTimer = nil
                self.sleepMinutes = 0
                self.stopPlayback()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        sleepTimer = t
    }

    func playQueue(items: [FileItem], index: Int, paneLabel: String) {
        guard !items.isEmpty else { return }
        baseQueue = items
        queue = makePlayOrder(from: items, startAt: index)
        if shuffleMode {
            queueIndex = 0 // the clicked track was pinned to the front
        } else {
            queueIndex = min(max(0, index), items.count - 1)
        }
        sourcePane = paneLabel
        playCurrent()
    }

    func togglePause() {
        switch activeEngine {
        case .avaudio:
            guard let node = playerNode else { return }
            if isTransitioning { cancelCrossfade() }
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
            if midiSampler {
                guard let engine = eEngine, let seq = eSequencer else { return }
                if isPlaying {
                    midiPausedPosition = currentTime
                    engine.pause()
                    seq.stop()
                    isPlaying = false
                    userPaused = true
                } else {
                    seq.stop()
                    seq.currentPositionInSeconds = midiPausedPosition ?? 0
                    try? engine.start()
                    try? seq.start()
                    isPlaying = true
                    userPaused = false
                    midiPausedPosition = nil
                    midiEnded = false
                }
            } else {
                guard let player = midiPlayer else { return }
                if player.isPlaying {
                    midiPausedPosition = player.currentPosition
                    player.stop()
                    isPlaying = false
                    userPaused = true
                } else {
                    let pos = midiPausedPosition
                    if let pos { player.currentPosition = pos }
                    player.play { [weak self] in
                        Task { @MainActor [weak self] in self?.midiFinished(player) }
                    }
                    if let pos { player.currentPosition = pos }
                    isPlaying = true
                    userPaused = false
                    midiPausedPosition = nil
                }
            }
        case .none:
            break
        }
        publishNowPlaying()
    }

    func stopPlayback() {
        teardownPlayback()
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        baseQueue.removeAll()
        queue.removeAll()
        queueIndex = 0
        failuresInARow = 0
        setPreventSleep(false)
        sleepTimer?.invalidate()
        sleepTimer = nil
        if sleepMinutes != 0 {
            sleepMinutes = 0
        }
        NowPlaying.clear()
    }

    func next() {
        guard !queue.isEmpty else { return }
        guard queueIndex + 1 < queue.count else {
            guard repeatMode != .off else { return }
            queueIndex = 0
            if shuffleMode { reshuffleKeepingCurrent() }
            playCurrent()
            return
        }
        queueIndex += 1
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
        setPreventSleep(true)
        startTicker()
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        NowPlaying.publish(track: currentTrack, elapsed: currentTime, duration: duration,
                           rate: isPlaying && !userPaused ? 1.0 : 0.0,
                           sourcePane: sourcePane,
                           hasNext: hasNext, hasPrevious: hasPrevious)
    }

    private func startEngineA(url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            engine.mainMixerNode.outputVolume = Float(masterMixerVolume())
            SpectrumAnalyzer.shared.attach(to: engine)   // #16 visualizer tap
            eqNodeA = Equalizer.shared.install(on: engine)   // #17 insert between mixer and output
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
        player.volume = Float(masterMixerVolume())

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
            engine.mainMixerNode.outputVolume = Float(masterMixerVolume())
            SpectrumAnalyzer.shared.attach(to: engine)   // #16 visualizer tap
            eqNodeC = Equalizer.shared.install(on: engine)   // #17 insert between mixer and output
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
        var player: AVMIDIPlayer?
        if let p = try? AVMIDIPlayer(contentsOf: url, soundBankURL: nil) {
            player = p
        } else if url.pathExtension.lowercased() == "rmi",
                  let data = try? Data(contentsOf: url),
                  let smf = AudioFormats.unwrapRMID(data),
                  let p = try? AVMIDIPlayer(data: smf, soundBankURL: nil) {
            player = p
        }
        if let player {
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
        return startEngineE(url: url)
    }

    private func startEngineE(url: URL) -> Bool {
        var data: Data
        if url.pathExtension.lowercased() == "rmi",
           let raw = try? Data(contentsOf: url),
           let smf = AudioFormats.unwrapRMID(raw) {
            data = smf
        } else if let d = try? Data(contentsOf: url) {
            data = d
        } else {
            return false
        }
        guard FileManager.default.fileExists(atPath: gsBankURL.path) else { return false }

        let sampler = AVAudioUnitSampler()
        do {
            try sampler.loadSoundBankInstrument(at: gsBankURL, program: 0,
                                                bankMSB: 0x79, bankLSB: 0)
        } catch {
            return false
        }
        let engine = AVAudioEngine()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = Float(masterMixerVolume())
        SpectrumAnalyzer.shared.attach(to: engine)   // #16 visualizer tap
        eqNodeE = Equalizer.shared.install(on: engine)   // #17 insert between mixer and output

        let sequencer = AVAudioSequencer(audioEngine: engine)
        do {
            try sequencer.load(from: data, options: [.smf_ChannelsToTracks])
        } catch {
            do {
                try sequencer.load(from: data, options: [])
            } catch {
                return false
            }
        }
        var endSeconds: TimeInterval = 0
        for track in sequencer.tracks {
            track.destinationAudioUnit = sampler
            let len = track.lengthInSeconds
            if len.isFinite, len > endSeconds { endSeconds = len }
        }
        if endSeconds > 0 { duration = endSeconds }
        sequencer.prepareToPlay()
        do {
            try engine.start()
            try sequencer.start()
        } catch {
            return false
        }

        eEngine = engine
        eSampler = sampler
        eSequencer = sequencer
        midiPlayer = nil
        midiSampler = true
        midiPausedPosition = nil
        midiEnded = false
        return true
    }

    private func midiFinished(_ player: AVMIDIPlayer) {
        guard midiPlayer === player, activeEngine == .midi,
              currentTrack != nil else { return }
        if userPaused || midiPausedPosition != nil { return }
        if duration <= 0 || player.currentPosition >= max(0, duration - 0.5) {
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
        NowPlaying.clear()
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
        switch repeatMode {
        case .one:
            playCurrent()
        case .all:
            if queueIndex + 1 < queue.count {
                queueIndex += 1
            } else {
                queueIndex = 0
                if shuffleMode { reshuffleKeepingCurrent() }
            }
            playCurrent()
        case .off:
            if queueIndex + 1 < queue.count {
                queueIndex += 1
                playCurrent()
            } else {
                stopPlayback()
            }
        }
    }

    // MARK: - Crossfade / gapless (#14)

    /// The queue slot the upcoming track would occupy, or nil when a transition
    /// would not line up (repeat-one, or the last track with repeat off). The
    /// shuffled repeat-all wrap is left to `trackEnded` because it re-permutes
    /// the queue, which would invalidate a preloaded target.
    private func crossfadeTargetIndex() -> Int? {
        guard crossfade.isEnabled, !queue.isEmpty, repeatMode != .one else { return nil }
        if queueIndex + 1 < queue.count { return queueIndex + 1 }
        if repeatMode == .all && !shuffleMode { return 0 }
        return nil
    }

    private func beginCrossfade() {
        guard activeEngine == .avaudio, !isTransitioning else { return }
        guard let nextIndex = crossfadeTargetIndex() else { return }
        let item = queue[nextIndex]
        let ext = (item.name as NSString).pathExtension
        guard AudioFormats.route(forExtension: ext) == .native else { return }
        do {
            let file = try AVAudioFile(forReading: item.url)
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            engine.mainMixerNode.outputVolume = Float(masterMixerVolume())
            SpectrumAnalyzer.shared.attach(to: engine)
            xfEQ = Equalizer.shared.install(on: engine)
            try engine.start()
            node.scheduleFile(file, at: nil)
            node.volume = crossfade.isGapless ? 1 : 0
            node.play()
            playerNode?.volume = 1
            xfEngine = engine
            xfNode = node
            xfFile = file
            xfIndex = nextIndex
            xfOverlap = crossfade.overlap
            xfStartedAt = ProcessInfo.processInfo.systemUptime
            isTransitioning = true
            if !crossfade.isGapless { startCrossfadeRamp() }
        } catch {
            cancelCrossfade()
        }
    }

    private func startCrossfadeRamp() {
        xfTimer?.invalidate()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rampCrossfade() }
        }
        RunLoop.main.add(timer, forMode: .common)
        xfTimer = timer
    }

    private func rampCrossfade() {
        guard isTransitioning else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - xfStartedAt
        playerNode?.volume = Float(Crossfade.fadeOut(elapsed: elapsed, overlap: xfOverlap))
        xfNode?.volume = Float(Crossfade.fadeIn(elapsed: elapsed, overlap: xfOverlap))
    }

    /// Promotes the pre-started engine to be the live one when the outgoing
    /// track ends. Only Engine A is torn down; the incoming engine keeps
    /// running so there is no silence between the two tracks.
    private func finishCrossfade() {
        guard isTransitioning, let nextIndex = xfIndex,
              queue.indices.contains(nextIndex), let nextFile = xfFile,
              let engine = xfEngine, let node = xfNode else {
            cancelCrossfade()
            if currentTrack != nil { trackEnded() }
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - xfStartedAt
        xfTimer?.invalidate()
        xfTimer = nil
        teardownEngineA()
        eqNodeA = xfEQ
        xfEQ = nil
        audioEngine = engine
        playerNode = node
        engineFile = nextFile
        scheduledStartFrame = 0
        node.volume = 1
        let seconds = Double(nextFile.length) / nextFile.processingFormat.sampleRate
        if seconds.isFinite, seconds > 0 { duration = seconds }
        queueIndex = nextIndex
        currentTrack = queue[nextIndex]
        currentTime = min(max(0, elapsed), duration)
        applyVolume()   // the promoted engine carries the outgoing track's gain
        isPlaying = true
        userPaused = false
        xfEngine = nil
        xfNode = nil
        xfFile = nil
        xfIndex = nil
        isTransitioning = false
        publishNowPlaying()
    }

    private func cancelCrossfade() {
        xfTimer?.invalidate()
        xfTimer = nil
        if let engine = xfEngine { engine.stop() }
        if let eq = xfEQ { Equalizer.shared.uninstall(eq); xfEQ = nil }
        xfEngine = nil
        xfNode = nil
        xfFile = nil
        xfIndex = nil
        isTransitioning = false
        playerNode?.volume = 1
    }

    // MARK: - Seek & position

    func seek(to target: TimeInterval) {
        if isTransitioning { cancelCrossfade() }
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
            if midiSampler {
                guard let seq = eSequencer else { return }
                seq.currentPositionInSeconds = clamped
                currentTime = clamped
                if !seq.isPlaying || userPaused {
                    midiPausedPosition = clamped
                }
                midiEnded = false
            } else {
                guard let player = midiPlayer else { return }
                player.currentPosition = clamped
                currentTime = clamped
                if !player.isPlaying && userPaused {
                    midiPausedPosition = clamped
                }
            }
        case .none:
            break
        }
        publishNowPlaying()
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
            if crossfade.isEnabled && !isTransitioning
                && Crossfade.shouldTransition(position: currentTime, duration: duration,
                                              overlap: crossfade.overlap) {
                beginCrossfade()
            }
            if isPlaying && !userPaused && !node.isPlaying
                && duration > 0 && currentTime >= duration - 0.25 {
                if isTransitioning {
                    finishCrossfade()
                } else {
                    trackEnded()
                }
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
            if midiSampler {
                guard let seq = eSequencer, let engine = eEngine,
                      engine.isRunning else { return }
                let s = seq.currentPositionInSeconds
                if s.isFinite, s >= 0, s <= duration + 10.0 {
                    currentTime = min(s, duration)
                }
                let saneEnd = duration > 0 && s >= max(0, duration - 0.5)
                    && s <= duration + 10.0
                if !midiEnded && saneEnd && isPlaying && !userPaused {
                    midiEnded = true
                    trackEnded()
                }
            } else if let player = midiPlayer, player.isPlaying {
                currentTime = player.currentPosition
            }
        case .none:
            break
        }
        NowPlaying.tickPosition(elapsed: currentTime, duration: duration)
    }

    // MARK: - Teardown

    /// User volume with any ReplayGain gain for the current track folded in.
    /// Recompute happens wherever a track starts and whenever volume/mode
    /// changes, so switching a sound source never changes the loudness the
    /// listener actually hears.
    private func masterMixerVolume() -> Double {
        volume * replayGain.volumeMultiplier(for: currentTrack?.url, mode: replayGain.mode)
    }

    func refreshVolume() {
        applyVolume()
    }

    private func applyVolume() {
        let v = Float(masterMixerVolume())
        audioEngine?.mainMixerNode.outputVolume = v
        fallbackPlayer?.volume = v
        engineC?.mainMixerNode.outputVolume = v
        eEngine?.mainMixerNode.outputVolume = v
        xfEngine?.mainMixerNode.outputVolume = v
    }

    private func teardownPlayback() {
        cancelCrossfade()
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
        if let eq = eqNodeC { Equalizer.shared.uninstall(eq); eqNodeC = nil }
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

        if let seq = eSequencer { seq.stop() }
        if let eq = eqNodeE { Equalizer.shared.uninstall(eq); eqNodeE = nil }
        if let engine = eEngine { engine.stop() }
        eSequencer = nil
        eSampler = nil
        eEngine = nil
        midiSampler = false
        midiEnded = false

        midiPlayer?.stop()
        midiPlayer = nil
        midiPausedPosition = nil

        teardownEngineA()
        activeEngine = .none
        userPaused = false
    }

    private func teardownEngineA() {
        if let eq = eqNodeA { Equalizer.shared.uninstall(eq); eqNodeA = nil }
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        engineFile = nil
        scheduledStartFrame = 0
    }
}
