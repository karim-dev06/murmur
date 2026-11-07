import AppKit

/// Test mode, no permissions needed:
///   Murmur --transcribe file.wav [--no-cleanup]
///   Murmur --clean "um so like the text"
///   Murmur --learn "typed text" "edited text"   (what would be learned)
///   Murmur --fix-words < lines.txt   (tech word fixes only)
///   Murmur --live file.wav   (streams the file as if spoken, prints when the text is ready)
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        Pref.registerDefaults()
        let vocabulary = Pref.vocabularyList
        do {
            if let path = value(after: "--live", in: args) {
                let samples = try AudioConvert.load(URL(fileURLWithPath: path))
                let engine = AppleSpeechEngine(localeID: Pref.localeID)
                try await engine.prepare()
                let updates = Counter()
                let tidier = await LiveTidier(cleaner: Cleaner(), vocabulary: vocabulary)
                let live = engine.startLive(vocabulary: vocabulary, onText: { _ in updates.add() },
                                            onSettled: { piece in
                    DispatchQueue.main.async { MainActor.assumeIsolated { tidier.add(piece) } }
                })
                let step = Int(AudioRecorder.sampleRate / 10)
                for start in stride(from: 0, to: samples.count, by: step) {
                    live.append(Array(samples[start ..< min(start + step, samples.count)]))
                    try await Task.sleep(for: .milliseconds(100))
                }
                let released = Date()
                let text = try await live.finish()
                print("\(updates.value) live updates while talking. Heard \(elapsed(released)) after release: \(text)")
                let tidied = await Cleaner().polish(text, cleanup: true, vocabulary: vocabulary, shortcuts: Shortcuts.all,
                                                    pretidied: await tidier.finish())
                print("Tidied \(elapsed(released)) after release: \(tidied)")
                return 0
            }
            if let typed = value(after: "--learn", in: args), let edited = args.last, edited != typed {
                // What would be learned if Murmur typed the first text and the person changed it to the second.
                for fix in Learned.corrections(typed: typed, edited: edited) { print("learn: \(fix.heard) → \(fix.correct)") }
                return 0
            }
            if let name = value(after: "--watch-test", in: args) {
                return await MainActor.run { () -> Int32 in
                    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { print("no app \(name)"); return 1 }
                    let appElement = AXUIElementCreateApplication(app.processIdentifier)
                    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    let focus = { () -> AXUIElement? in
                        var v: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v else { return nil }
                        return (v as! AXUIElement)
                    }
                    guard let box = focus() else { print("no focused text box in \(name)"); return 1 }
                    var v: CFTypeRef?
                    AXUIElementCopyAttributeValue(box, kAXValueAttribute as CFString, &v)
                    guard let text = v as? String, !text.isEmpty else { print("can't read the text box (\(CorrectionWatcher.role(of: box)))"); return 1 }
                    let typed = String(text.split(whereSeparator: \.isNewline).last ?? Substring(text))
                    let watcher = CorrectionWatcher()
                    watcher.focused = focus
                    watcher.onLearned = { fixes in for f in fixes { print("LEARNED: \(f.heard) → \(f.correct)") }; exit(0) }
                    watcher.watch(box, typed: typed)
                    print("watching \(CorrectionWatcher.role(of: box)): \"\(typed)\" — edit it within 40 s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 40) { watcher.finish(); print("nothing learned"); exit(2) }
                    return -1
                }
            }
            if args.contains("--self-test") {
                // Checks how an edit to a text box is pinned to the words Murmur typed.
                let before = "Hi Priya, I made this Whisper Pro alternative. Bye"
                let start = 10, length = 36
                let cases: [(String, String?)] = [
                    ("Hi Priya, I made this Wispr Flow alternative. Bye", "I made this Wispr Flow alternative."),
                    ("Hi Priya, I made this Whisper Pro alternative. Bye", "I made this Whisper Pro alternative."),
                    ("Hello Priya, I made this Wispr Flow alternative. Bye", nil),
                    ("Hi Priya, I made this Whisper Pro alternative. Thanks, bye", nil),
                    // Writing more after the typed words is not an edit of them.
                    ("Hi Priya, I made this Whisper Pro alternative. More text. Bye", nil),
                    ("Hi Priya, I made this Whisper Pro tool. Bye", "I made this Whisper Pro tool."),
                ]
                var ok = true
                for (after, expected) in cases {
                    let got = CorrectionWatcher.editedSpan(before: before, after: after, spanStart: start, spanLength: length)
                    if got != expected { ok = false; print("FAIL: \(after) → \(got ?? "nil"), expected \(expected ?? "nil")") }
                }
                print(ok ? "self-test passed" : "self-test failed")
                return ok ? 0 : 1
            }
            if args.contains("--fix-words") {
                // One sentence per line on stdin, fixed tech words on stdout.
                while let line = readLine() { print(TextFilter.fixTechWords(line)) }
                return 0
            }
            if let text = value(after: "--clean", in: args) {
                let start = Date()
                let cleaned = await Cleaner().polish(text, cleanup: true, vocabulary: vocabulary, shortcuts: Shortcuts.all)
                print("cleaned (\(elapsed(start))): \(cleaned)")
                return 0
            }
            guard let path = value(after: "--transcribe", in: args) else {
                print("usage: Murmur --transcribe file.wav [--no-cleanup] | --clean \"text\" | --live file.wav")
                return 2
            }
            let samples = try AudioConvert.load(URL(fileURLWithPath: path))
            let engine = AppleSpeechEngine(localeID: Pref.localeID)

            var start = Date()
            try await engine.prepare()
            print("\(engine.name) loaded in \(elapsed(start))")
            start = Date()
            let raw = TextFilter.tidy(try await engine.transcribe(samples, vocabulary: vocabulary))
            print("heard (\(elapsed(start))): \(raw)")
            if !args.contains("--no-cleanup") {
                start = Date()
                let cleaned = await Cleaner().polish(raw, cleanup: true, vocabulary: vocabulary, shortcuts: Shortcuts.all)
                print("cleaned (\(elapsed(start))): \(cleaned)")
            }
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func elapsed(_ start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }
}


private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
