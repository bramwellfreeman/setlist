import AVFoundation
import AudioToolbox
import Combine
import CoreAudio

/// One output device, as listed in the playlist's Output menu.
struct OutputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// AVAudioEngine playback with two decks (for crossfades and gapless hand-offs),
/// per-track gain (dB), master volume, trim-aware scheduling, seeking, fades,
/// and a selectable output device.
///
/// Graph:  deck.player → deck.sub (mixer) → deck.eq → mainMixer → output
/// Only `player → sub` changes per file; a mixer input converts any sample rate /
/// channel count, so the engine keeps running when formats differ. (Reconnecting
/// a fixed-format chain live is what caused CoreAudio -10868 crashes before.)
final class AudioController: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTrackID: UUID?
    @Published var currentTime: Double = 0      // absolute position in the file (seconds)
    @Published var segmentStart: Double = 0     // trim start of loaded track
    @Published var segmentEnd: Double = 0       // effective end of loaded track
    @Published var masterVolume: Double = 1.0 {
        didSet { engine.mainMixerNode.outputVolume = Float(masterVolume) }
    }
    /// True when a segment is loaded and has playback remaining (playing or paused).
    @Published private(set) var hasSegment = false
    @Published private(set) var isFading = false
    @Published private(set) var outputDeviceUID: String?   // nil = system default

    /// Called on the main thread when the active segment plays to its end.
    var onFinished: (() -> Void)?
    /// Called ~10×/s while playing with the seconds remaining in the active segment.
    var onTick: ((Double) -> Void)?

    private final class Deck {
        let player = AVAudioPlayerNode()
        let sub = AVAudioMixerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 0)
        var file: AVAudioFile?
        var track: Track?
        var gainDB: Double = 0
        var fs: Double = 44_100
        var startFrame: AVAudioFramePosition = 0
        var endFrame: AVAudioFramePosition = 0
        var generation = 0
        var loaded: Bool { file != nil }
    }

    private let engine = AVAudioEngine()
    private let decks = [Deck(), Deck()]
    private var activeIndex = 0
    private var cur: Deck { decks[activeIndex] }
    private var other: Deck { decks[1 - activeIndex] }
    private let busFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private var timer: Timer?
    private var fadeTimer: Timer?
    private var fades: [Fade] = []
    private var configObserver: NSObjectProtocol?
    private var ignoreConfigChangeUntil = Date.distantPast

    private struct Fade {
        let node: AVAudioMixerNode
        let from: Float, to: Float
        let start: Date, duration: Double
        let done: (() -> Void)?
    }

    init() {
        for d in decks {
            engine.attach(d.player)
            engine.attach(d.sub)
            engine.attach(d.eq)
            engine.connect(d.sub, to: d.eq, format: busFormat)
            engine.connect(d.eq, to: engine.mainMixerNode, format: busFormat)
        }
        engine.mainMixerNode.outputVolume = Float(masterVolume)
        // The engine stops itself when the output device changes (interface
        // plugged/unplugged, AirPods, sample-rate switch). Restart and resume.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, Date() > self.ignoreConfigChangeUntil else { return }
            self.recoverFromConfigChange()
        }
    }

    // MARK: - Deck loading

    /// Open `track` on `deck` and schedule its segment (not started). Returns false
    /// if the file couldn't be opened.
    private func load(_ deck: Deck, track: Track, gainDB: Double, fromAbsolute: Double?) -> Bool {
        deck.generation += 1
        let gen = deck.generation
        deck.player.stop()

        let f: AVAudioFile
        do { f = try AVAudioFile(forReading: track.url) } catch {
            NSLog("Setlist: can't open \(track.path) — \(error)")
            deck.file = nil; deck.track = nil
            return false
        }
        let fs = f.processingFormat.sampleRate
        engine.disconnectNodeOutput(deck.player)
        engine.connect(deck.player, to: deck.sub, format: f.processingFormat)
        deck.eq.globalGain = clampGain(gainDB)
        deck.sub.outputVolume = 1

        let total = f.length
        let endSec = track.effectiveEnd > 0 ? track.effectiveEnd : Double(total) / fs
        let endFrame = min(AVAudioFramePosition(endSec * fs), total)
        var startFrame = AVAudioFramePosition(max(0, track.trimStart) * fs)
        if let abs = fromAbsolute { startFrame = AVAudioFramePosition(max(track.trimStart, abs) * fs) }
        startFrame = max(0, min(startFrame, endFrame))

        deck.file = f; deck.track = track; deck.gainDB = gainDB; deck.fs = fs
        deck.startFrame = startFrame; deck.endFrame = endFrame

        if endFrame > startFrame {
            deck.player.scheduleSegment(f, startingFrame: startFrame,
                                        frameCount: AVAudioFrameCount(endFrame - startFrame),
                                        at: nil, completionCallbackType: .dataPlayedBack) { [weak self, weak deck] _ in
                DispatchQueue.main.async {
                    guard let self, let deck, deck.generation == gen else { return }
                    self.deckFinished(deck)
                }
            }
        }
        return true
    }

    private func unload(_ deck: Deck) {
        deck.generation += 1
        deck.player.stop()
        deck.file = nil
        deck.track = nil
    }

    private func publishActive() {
        let d = cur
        currentTrackID = d.track?.id
        segmentStart = d.track?.trimStart ?? 0
        segmentEnd = d.track.map { $0.effectiveEnd > 0 ? $0.effectiveEnd : Double(d.endFrame) / d.fs } ?? 0
        currentTime = Double(d.startFrame) / d.fs
        hasSegment = d.loaded && d.endFrame > d.startFrame
    }

    private func deckFinished(_ deck: Deck) {
        guard deck === cur else { unload(deck); return }   // a deck we already handed off from
        isPlaying = false
        hasSegment = false
        stopTimer()
        onFinished?()
    }

    // MARK: - Transport

    /// Load and play (or, with `startPaused`, load and hold) a track — a hard
    /// cut that stops anything else. Returns false if the file couldn't be opened.
    @discardableResult
    func play(track: Track, gainDB: Double, fromAbsolute: Double? = nil, startPaused: Bool = false) -> Bool {
        cancelFades()
        unload(other)
        guard load(cur, track: track, gainDB: gainDB, fromAbsolute: fromAbsolute) else {
            unload(cur)
            isPlaying = false; hasSegment = false; currentTrackID = nil
            stopTimer()
            return false
        }
        publishActive()
        if !hasSegment {
            // Empty segment (e.g. seek to the very end): treat as finished.
            let gen = cur.generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.cur.generation == gen else { return }
                self.onFinished?()
            }
            return true
        }
        startEngineIfNeeded()
        if startPaused {
            isPlaying = false
            stopTimer()
        } else {
            cur.player.play()
            isPlaying = true
            startTimer()
        }
        return true
    }

    /// Start `track` on the idle deck and overlap it with the current one,
    /// fading old → out and new → in over `seconds`.
    @discardableResult
    func crossfade(to track: Track, gainDB: Double, seconds: Double) -> Bool {
        guard isPlaying, cur.loaded else { return play(track: track, gainDB: gainDB) }
        cancelFades(finishing: true)
        let old = cur, new = other
        guard load(new, track: track, gainDB: gainDB, fromAbsolute: nil) else { return false }
        new.sub.outputVolume = 0
        startEngineIfNeeded()
        new.player.play()
        activeIndex = 1 - activeIndex
        publishActive()
        isPlaying = true
        startTimer()
        addFade(new.sub, to: 1, seconds: seconds)
        addFade(old.sub, to: 0, seconds: seconds) { [weak self] in self?.unload(old) }
        return true
    }

    /// Queue `track` on the idle deck to start exactly when the current segment
    /// ends (sample-accurate hand-off, no gap).
    @discardableResult
    func queueGapless(_ track: Track, gainDB: Double) -> Bool {
        guard isPlaying, let nodeTime = cur.player.lastRenderTime,
              let pt = cur.player.playerTime(forNodeTime: nodeTime) else { return false }
        let old = cur, new = other
        let remainingFrames = Double(old.endFrame - old.startFrame) - Double(pt.sampleTime)
        let remaining = max(0, remainingFrames / old.fs)
        guard load(new, track: track, gainDB: gainDB, fromAbsolute: nil) else { return false }
        let startHost = nodeTime.hostTime + AVAudioTime.hostTime(forSeconds: remaining)
        new.player.play(at: AVAudioTime(hostTime: startHost))
        activeIndex = 1 - activeIndex
        publishActive()
        isPlaying = true
        startTimer()
        return true
    }

    func togglePlayPause() {
        guard cur.loaded else { return }
        isPlaying ? pause() : resume()
    }

    func pause() {
        guard isPlaying else { return }
        cancelFades(finishing: true)      // settle any crossfade onto the new track
        cur.player.pause()
        isPlaying = false
        stopTimer()
    }

    func resume() {
        guard cur.loaded, hasSegment, !isPlaying else { return }
        startEngineIfNeeded()
        cur.sub.outputVolume = 1
        cur.player.play()
        isPlaying = true
        startTimer()
    }

    func stop() {
        cancelFades()
        unload(decks[0]); unload(decks[1])
        isPlaying = false
        isFading = false
        hasSegment = false
        stopTimer()
        currentTrackID = nil
        currentTime = 0
        segmentStart = 0
        segmentEnd = 0
    }

    /// Fade the current track to silence, then stop and call `completion`.
    /// A fade already in progress is finished immediately instead.
    func fadeOutAndStop(seconds: Double, completion: @escaping () -> Void) {
        if isFading { cancelFades(finishing: true); return }
        guard isPlaying, seconds > 0 else { completion(); return }
        cancelFades(finishing: true)
        isFading = true
        addFade(cur.sub, to: 0, seconds: seconds) { [weak self] in
            self?.isFading = false
            completion()
        }
    }

    func seek(toAbsolute seconds: Double, track: Track, gainDB: Double) {
        // Reschedule from the new position; stay paused if we were paused.
        play(track: track, gainDB: gainDB, fromAbsolute: seconds, startPaused: !isPlaying)
    }

    /// Live per-track gain change for the currently loaded track.
    func setGain(db: Double) {
        cur.gainDB = db
        cur.eq.globalGain = clampGain(db)
    }

    // MARK: - Output device

    /// Route output to the device with `uid` (nil = system default). Restarts the
    /// engine; anything loaded resumes from where it was.
    func setOutputDevice(uid: String?) {
        guard uid != outputDeviceUID else { return }
        guard let unit = engine.outputNode.audioUnit else { return }
        var devID = uid.flatMap(Self.deviceID(forUID:)) ?? Self.defaultOutputDeviceID()
        guard devID != 0 else { return }

        let wasPlaying = isPlaying
        let resume = cur.track.map { ($0, cur.gainDB, currentTime) }
        ignoreConfigChangeUntil = Date().addingTimeInterval(1.0)
        cancelFades()
        unload(decks[0]); unload(decks[1])
        engine.stop()
        let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &devID,
                                       UInt32(MemoryLayout<AudioDeviceID>.size))
        if err != noErr { NSLog("Setlist: couldn't switch output device (\(err))") }
        outputDeviceUID = uid
        if let (t, g, pos) = resume {
            play(track: t, gainDB: g, fromAbsolute: pos, startPaused: !wasPlaying)
        }
    }

    static func outputDevices() -> [OutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }   // private system aggregate
            return OutputDevice(uid: uid, name: name)
        }
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        outputDevicesWithIDs().first { $0.uid == uid }?.id
    }

    private static func outputDevicesWithIDs() -> [(uid: String, id: AudioDeviceID)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in stringProperty(id, kAudioDevicePropertyDeviceUID).map { ($0, id) } }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    // MARK: - Fades

    private func addFade(_ node: AVAudioMixerNode, to target: Float, seconds: Double, done: (() -> Void)? = nil) {
        fades.append(Fade(node: node, from: node.outputVolume, to: target,
                          start: Date(), duration: max(0.01, seconds), done: done))
        if fadeTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepFades() }
            RunLoop.main.add(t, forMode: .common)
            fadeTimer = t
        }
    }

    private func stepFades() {
        let now = Date()
        var finished: [Fade] = []
        fades.removeAll { f in
            let p = min(1, now.timeIntervalSince(f.start) / f.duration)
            // Equal-power-ish curve: smoother than linear for musical fades.
            let shaped = Float(f.to > f.from ? sin(p * .pi / 2) : cos((1 - p) * .pi / 2))
            f.node.outputVolume = f.from + (f.to - f.from) * shaped
            if p >= 1 { finished.append(f); return true }
            return false
        }
        if fades.isEmpty { fadeTimer?.invalidate(); fadeTimer = nil }
        finished.forEach { $0.done?() }
    }

    /// Stop running fades. With `finishing`, jump each to its end and run its
    /// completion (e.g. unload the outgoing crossfade deck).
    private func cancelFades(finishing: Bool = false) {
        let pending = fades
        fades.removeAll()
        fadeTimer?.invalidate(); fadeTimer = nil
        isFading = false
        guard finishing else { return }
        for f in pending { f.node.outputVolume = f.to; f.done?() }
    }

    // MARK: - Helpers

    private func clampGain(_ db: Double) -> Float { Float(max(-24, min(24, db))) }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { NSLog("Setlist: engine start failed — \(error)") }
    }

    private func recoverFromConfigChange() {
        guard let t = cur.track, hasSegment else { return }
        let wasPlaying = isPlaying
        let pos = currentTime
        NSLog("Setlist: audio configuration changed — restarting at \(pos)s")
        play(track: t, gainDB: cur.gainDB, fromAbsolute: pos, startPaused: !wasPlaying)
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        let d = cur
        guard d.loaded, let nodeTime = d.player.lastRenderTime,
              let pt = d.player.playerTime(forNodeTime: nodeTime) else { return }
        let elapsed = max(0, Double(pt.sampleTime) / pt.sampleRate)
        currentTime = min(Double(d.startFrame) / d.fs + elapsed, segmentEnd)
        if isPlaying { onTick?(segmentEnd - currentTime) }
    }
}
