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
}

/// Loud two-tone siren generated in code (no audio assets), plus haptics and a
/// local notification for when the app is in the background.
@MainActor
final class AlarmPlayer: AlarmPlaying {
    /// Read by the audio thread, written on the main thread; a stale value for a few milliseconds is harmless.
    private final class Gain { var level: Float = 0 }

    private let engine = AVAudioEngine()
    private let gain = Gain()
    private var node: AVAudioSourceNode?
    private var armed = false
    private var haptics: Timer?
    private var testTask: Task<Void, Never>?
    private var observing = false

    var volume: Float { AVAudioSession.sharedInstance().outputVolume }

    var externalRoute: String? {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let builtIn: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver]
        return outputs.first { !builtIn.contains($0.portType) }?.portName
    }

    func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        configureSession()
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            MainActor.assumeIsolated { if ended { self?.configureSession(); self?.ensureRunning() } }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureRunning() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildEngine() }
        }
    }

    /// `.playback` sounds even with the silent switch on; `.mixWithOthers` means keeping the session open never
    /// pauses music or a chart app's audio.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    func arm() {
        armed = true
        configureSession()
        startEngine()
    }

    func disarm() {
        armed = false
        if gain.level == 0 { engine.stop() }
    }

    func ensureRunning() {
        guard (armed || gain.level > 0), !engine.isRunning else { return }
        configureSession()
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
        configureSession()
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

    private func startEngine() {
        if node == nil { buildEngine() }
        if !engine.isRunning { try? engine.start() }
    }

    /// The source node always runs; it produces silence until `gain` is raised.
    private func buildEngine() {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return }
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
    private func rebuildEngine() {
        if let node { engine.detach(node) }
        node = nil
        configureSession()
        ensureRunning()
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
}
