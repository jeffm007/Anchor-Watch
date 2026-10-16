import AVFoundation
import UIKit
import UserNotifications

@MainActor
protocol AlarmPlaying: AnyObject {
    func prepare()
    /// Keeps the audio engine running silently while the anchor is set, so the siren can sound at once
    /// even if the app is in the background or the phone is locked (iOS won't let an app start audio from nothing there).
    func arm()
    func disarm()
    /// Restarts the engine if iOS stopped it (a call, Siri, an unplugged speaker...). Called every second while watching.
    func ensureRunning()
    func start(message: String)
    func stop()
    /// A quiet banner notification (no siren), e.g. for a new weather alert.
    func notice(title: String, message: String)
    /// Sounds the siren briefly so the volume can be checked.
    func test(duration: TimeInterval)
    /// Phone volume, 0...1.
    var volume: Float { get }
    /// Name of the output device when the sound would not come from the phone's own speaker.
    var externalRoute: String? { get }
    /// Last audio setup/startup failure; cleared only after a successful startup.
    var audioFailure: String? { get }
}

/// The C atomic flag is shared with the audio thread; reads never acquire a lock.
final class AudioGain: @unchecked Sendable {
    private let signal: AWAudioSignalRef
    init() {
        guard let signal = AWAudioSignalCreate() else { fatalError("Could not allocate audio signal") }
        self.signal = signal
    }
    deinit { AWAudioSignalDestroy(signal) }
    var level: Float {
        get { AWAudioSignalLoad(signal) ? 0.85 : 0 }
        set { AWAudioSignalStore(signal, newValue > 0) }
    }
}

/// Loud two-tone siren generated in code (no audio assets), plus haptics and a
/// local notification for when the app is in the background.
@MainActor
final class AlarmPlayer: AlarmPlaying {
    private var engine: AVAudioEngine
    private let makeEngine: () -> AVAudioEngine
    private let gain = AudioGain()
    private(set) var engineGeneration = 0
    var isSounding: Bool { gain.level > 0 }
    private var node: AVAudioSourceNode?
    private var armed = false
    private var haptics: Timer?
    private var testTask: Task<Void, Never>?
    private var observing = false
    private var interrupted = false
    private(set) var audioFailure: String?
    private let sessionSetup: () throws -> Void
    private let engineStartup: (() throws -> Void)?

    /// Injectable hardware boundaries let tests exercise failures and recovery without playing audio.
    init(sessionSetup: (() throws -> Void)? = nil,
         engineStartup: (() throws -> Void)? = nil,
         engineFactory: (() -> AVAudioEngine)? = nil) {
        let factory = engineFactory ?? { AVAudioEngine() }
        self.makeEngine = factory
        self.engine = factory()
        self.sessionSetup = sessionSetup ?? Self.configureAudioSession
        self.engineStartup = engineStartup
    }

    var volume: Float { AVAudioSession.sharedInstance().outputVolume }

    var externalRoute: String? {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let builtIn: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver]
        return outputs.first { !builtIn.contains($0.portType) }?.portName
    }

    func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        do { try sessionSetup() } catch { audioFailure = error.localizedDescription }
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            MainActor.assumeIsolated { self?.handleInterruption(ended: ended) }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let changed = note.object as? AVAudioEngine, changed === self.engine else { return }
                self.ensureRunning()
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        }
    }

    /// `.playback` sounds even with the silent switch on; `.mixWithOthers` means keeping the session open never
    /// pauses music or a chart app's audio.
    private static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    func arm() {
        armed = true
        startEngine()
    }

    func disarm() {
        armed = false
        if gain.level == 0 { engine.stop() }
    }

    func ensureRunning() {
        guard (armed || gain.level > 0), audioFailure != nil || !engine.isRunning else { return }
        startEngine()
    }

    func start(message: String) {
        notify(title: "Anchor alarm", message)
        testTask?.cancel()
        sound()
    }

    func stop() {
        testTask?.cancel()
        silence()
    }

    func test(duration: TimeInterval) {
        guard gain.level == 0 else { return }       // a real alarm is already sounding
        sound()
        testTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.silence()
        }
    }

    func notice(title: String, message: String) {
        notify(title: title, message)
    }

    // MARK: Siren

    private func sound() {
        gain.level = 0.85
        startEngine()
        if haptics == nil {
            haptics = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func silence() {
        gain.level = 0
        haptics?.invalidate()
        haptics = nil
        if !armed { engine.stop() }
    }

    func handleInterruption(ended: Bool) {
        interrupted = !ended
        if ended { ensureRunning() }
        else { audioFailure = "Audio interrupted. The siren will retry automatically." }
    }

    private func startEngine() {
        guard !interrupted else { return }
        do {
            try sessionSetup()
            if let engineStartup {
                try engineStartup()
            } else {
                if node == nil { try buildEngine() }
                if !engine.isRunning { try engine.start() }
            }
            audioFailure = nil
        } catch {
            audioFailure = error.localizedDescription
        }
    }

    /// The source node always runs; it produces silence until `gain` is raised.
    private func buildEngine() throws {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else {
            throw NSError(domain: "AnchorWatch.Audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio output is available."])
        }
        let gain = self.gain
        var phase = 0.0
        var t = 0.0
        let source = AVAudioSourceNode { _, _, frames, audio in
            let buffers = UnsafeMutableAudioBufferListPointer(audio)
            let level = Double(gain.level)
            for frame in 0..<Int(frames) {
                let freq = Int(t * 2) % 2 == 0 ? 880.0 : 660.0
                phase += 2 * .pi * freq / sampleRate
                if phase > 2 * .pi { phase -= 2 * .pi }
                t += 1 / sampleRate
                let sample = Float(sin(phase) * level)
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        node = source
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
    }

    /// After iOS resets the media services, every audio object has to be rebuilt.
    func handleMediaServicesReset() {
        // All graph objects from the previous media server are orphaned. Discard
        // them together, preserving only our atomic siren flag and armed state.
        node = nil
        engine = makeEngine()
        engineGeneration += 1
        interrupted = false
        if armed || isSounding {
            audioFailure = "Audio services reset. Restarting siren output."
            startEngine()
        }
    }

    private func notify(title: String, _ message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

@MainActor
final class SilentAlarm: AlarmPlaying {
    private(set) var armed = false
    private(set) var sirenSounding = false
    private(set) var tested = 0

    func prepare() {}
    func arm() { armed = true }
    func disarm() { armed = false }
    func ensureRunning() {}
    func start(message: String) { sirenSounding = true }
    func stop() { sirenSounding = false }
    func notice(title: String, message: String) {}
    func test(duration: TimeInterval) { tested += 1 }
    var volume: Float = 1
    var externalRoute: String?
    var audioFailure: String?
}
