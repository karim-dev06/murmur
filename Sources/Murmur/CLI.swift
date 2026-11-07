import Foundation

/// Test mode, no permissions needed:
///   Murmur --transcribe file.wav [--no-cleanup]
///   Murmur --clean "um so like the text"
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
                let live = engine.startLive(vocabulary: vocabulary) { _ in updates.add() }
                let step = Int(AudioRecorder.sampleRate / 10)
                for start in stride(from: 0, to: samples.count, by: step) {
                    live.append(Array(samples[start ..< min(start + step, samples.count)]))
                    try await Task.sleep(for: .milliseconds(100))
                }
                let released = Date()
                let text = try await live.finish()
                print("\(updates.value) live updates while talking. Ready \(elapsed(released)) after release: \(text)")
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
