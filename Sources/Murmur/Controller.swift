import AppKit
import AVFoundation

/// Ties it together: talk key → record → speech to text → tidy-up → save → type.
@MainActor
final class Controller {
    enum Phase { case idle, recording, working }

    private(set) var phase: Phase = .idle { didSet { onChange?() } }
    private(set) var engineStatus = "Starting…" { didSet { onChange?() } }
    private(set) var lastFailedSamples: [Float]? { didSet { onChange?() } }
    var onChange: (() -> Void)?

    let history = HistoryStore()
    let hud = HUD()
    private let recorder = AudioRecorder()
    private let cleaner = Cleaner()
    private let paster = Paster()
    private let hotkeys = HotkeyMonitor()
    private var engine: AppleSpeechEngine?
    private var engineLocale = ""
    /// What the talk key is doing during a recording.
    private enum KeyMode { case pressed, awaitingSecondTap, handsFree }
    private var keyMode: KeyMode = .pressed
    private var pressStart: Date?
    /// Shorter than this is a tap. The pill appears at the same moment, so taps never show it.
    private let holdThreshold: TimeInterval = 0.3
    private var showTimer: Timer?
    private var tapTimer: Timer?
    private var maxLengthTimer: Timer?
    private var live: LiveTranscription?
    private var accessibilityTimer: Timer?

    var hotkeysActive: Bool { hotkeys.isRunning }

    var statusLine: String {
        if !hotkeys.isRunning { return "Needs Accessibility permission. Open Settings." }
        if engineStatus != "Ready" { return engineStatus }
        return "Hold \(Pref.triggerName) to talk"
    }

    func start() {
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.model.push(level: level) }
        }
        hotkeys.onTriggerDown = { [weak self] in self?.triggerDown() }
        hotkeys.onTriggerUp = { [weak self] in self?.triggerUp() }
        hotkeys.onOtherKeyWhileHeld = { [weak self] in self?.otherKeyWhileHeld() }
        hotkeys.isRecording = { [weak self] in self?.phase == .recording }
        hotkeys.onEscape = { [weak self] in self?.cancelRecording(message: "Cancelled") }
        hotkeys.onPasteLast = { [weak self] in self?.pasteLast() }
        applyTrigger()
        startHotkeys(prompt: true)
        reloadEngineIfNeeded()

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTrigger()
                self?.reloadEngineIfNeeded()
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    func shutdown() {
        _ = recorder.stop()
    }

    // MARK: - Talk key
    //
    // The mic starts on the first press so no word is lost, but nothing shows until it is clearly a hold.
    // A quick tap waits briefly for a second tap: if one comes, the same recording turns hands-free.
    // If not, it is dropped without ever showing anything.

    private func triggerDown() {
        switch (phase, keyMode) {
        case (.idle, _):
            pressStart = Date()
            startRecording()
        case (.recording, .awaitingSecondTap):
            tapTimer?.invalidate()
            keyMode = .handsFree
            playStartSound()
            hud.show(.handsFree)
        case (.recording, .handsFree):
            finishRecording()
        default:
            break
        }
    }

    private func triggerUp() {
        guard phase == .recording, keyMode == .pressed, let pressStart else { return }
        if Date().timeIntervalSince(pressStart) < holdThreshold {
            showTimer?.invalidate()
            keyMode = .awaitingSecondTap
            tapTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.keyMode == .awaitingSecondTap else { return }
                    self.cancelRecording(message: nil)
                }
            }
        } else {
            finishRecording()
        }
    }

    private func otherKeyWhileHeld() {
        // fn + another key is a keyboard shortcut, not dictation.
        guard phase == .recording, keyMode == .pressed else { return }
        cancelRecording(message: nil)
    }

    // MARK: - Recording

    private func startRecording() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            hud.flash("Microphone is off for Murmur. Turn it on in Settings.")
            return
        }

        hud.model.liveText = ""
        let live = engine?.startLive(vocabulary: Pref.vocabularyList) { [weak self] text in
            DispatchQueue.main.async { self?.hud.model.liveText = text }
        }
        recorder.onChunk = { chunk in live?.append(chunk) }
        do {
            try recorder.start()
        } catch {
            live?.cancel()
            hud.flash(error.localizedDescription)
            return
        }
        self.live = live
        keyMode = .pressed
        phase = .recording
        if Pref.d.bool(forKey: Pref.cleanup) { cleaner.prewarm(vocabulary: Pref.vocabularyList) }
        if let engine { Task { try? await engine.prepare() } }
        showTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording, self.keyMode == .pressed else { return }
                self.playStartSound()
                self.hud.show(.listening)
            }
        }
        maxLengthTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishRecording() }
        }
    }

    private func playStartSound() {
        if Pref.d.bool(forKey: Pref.sounds) { NSSound(named: "Tink")?.play() }
    }

    private func stopTimers() {
        showTimer?.invalidate()
        tapTimer?.invalidate()
        maxLengthTimer?.invalidate()
    }

    private func cancelRecording(message: String?) {
        guard phase == .recording else { return }
        stopTimers()
        _ = recorder.stop()
        live?.cancel()
        live = nil
        phase = .idle
        if let message { hud.flash(message, seconds: 1.2) } else { hud.hide() }
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        stopTimers()
        let samples = recorder.stop()
        let live = self.live
        self.live = nil
        guard AudioCheck.hasSpeech(samples) else {
            live?.cancel()
            phase = .idle
            hud.flash("Didn't hear anything", seconds: 1.4)
            return
        }
        process(samples, live: live)
    }

    func retryLast() {
        guard phase == .idle, let samples = lastFailedSamples else { return }
        hud.model.liveText = ""
        process(samples, live: nil)
    }

    private func process(_ samples: [Float], live: LiveTranscription?) {
        guard let engine else { return }
        phase = .working
        hud.show(.working)
        let vocabulary = Pref.vocabularyList
        let shortcuts = Shortcuts.all
        let cleanup = Pref.d.bool(forKey: Pref.cleanup)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName

        Task {
            do {
                // The live text is ready almost at once. If it failed, transcribe the recording instead.
                var heard = (try? await live?.finish()) ?? ""
                if heard.isEmpty { heard = try await engine.transcribe(samples, vocabulary: vocabulary) }
                let raw = TextFilter.tidy(heard)
                lastFailedSamples = nil
                guard !raw.isEmpty else { return finish(flash: "Didn't catch that") }
                let text = await cleaner.polish(raw, cleanup: cleanup, vocabulary: vocabulary, shortcuts: shortcuts)
                history.add(Entry(date: Date(), raw: raw, text: text, app: app))
                let result = await paster.insert(text)
                finish(flash: result == .pasted ? nil : "Copied. Press ⌘V if it didn't appear.")
            } catch {
                lastFailedSamples = samples
                engineStatus = "Last try failed: \(error.localizedDescription)"
                finish(flash: "Couldn't transcribe. Retry from the menu bar.")
            }
        }
    }

    private func finish(flash: String?) {
        phase = .idle
        if let flash { hud.flash(flash) } else { hud.hide() }
    }

    // MARK: - History

    func pasteLast() {
        guard phase == .idle, let entry = history.entries.first else { return }
        Task {
            if await paster.insert(entry.text) == .copied { hud.flash("Copied. Press ⌘V if it didn't appear.") }
        }
    }

    func copy(_ entry: Entry) {
        paster.copy(entry.text)
        hud.flash("Copied", seconds: 1)
    }

    // MARK: - Setup

    private func applyTrigger() {
        hotkeys.trigger = Pref.d.string(forKey: Pref.trigger) == "rightOption" ? .rightOption : .fn
    }

    private func startHotkeys(prompt: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), hotkeys.start() {
            onChange?()
            return
        }
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if AXIsProcessTrusted(), self.hotkeys.start() {
                    timer.invalidate()
                    self.onChange?()
                }
            }
        }
    }

    private func reloadEngineIfNeeded() {
        let locale = Pref.localeID
        guard locale != engineLocale else { return }
        engineLocale = locale
        let new = AppleSpeechEngine(localeID: locale)
        engine = new
        engineStatus = "Loading \(new.name)…"
        Task {
            do {
                try await new.prepare()
                if engine === new { engineStatus = "Ready" }
            } catch {
                if engine === new { engineStatus = error.localizedDescription }
            }
        }
    }
}
