import AppKit

enum Pref {
    static let locale = "locale"                // BCP 47, e.g. "en-US"
    static let cleanup = "cleanup"
    static let trigger = "trigger"              // "fn" | "rightOption"
    static let vocabulary = "vocabulary"
    static let sounds = "sounds"
    static let shortcuts = "shortcuts"          // JSON list of Shortcut

    static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            locale: "en-US",
            cleanup: true,
            trigger: "fn",
            vocabulary: "",
            sounds: false,
            shortcuts: "[]",
        ])
    }

    static var vocabularyList: [String] {
        (d.string(forKey: vocabulary) ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static var localeID: String { d.string(forKey: locale) ?? "en-US" }

    static var triggerName: String { d.string(forKey: trigger) == "rightOption" ? "right ⌥" : "fn" }
}

enum Permissions {
    static let accessibilityURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let microphoneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let keyboardURL = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"

    /// "Press 🌐 key to: Do Nothing". Any other choice pops up emoji or dictation when fn is released.
    static var globeKeyDoesNothing: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) == 0
    }

    static var wisprFlow: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName?.localizedCaseInsensitiveContains("wispr") == true }
    }

    static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

struct MurmurError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Returns the result, or throws after `seconds` even if the work ignores cancellation and keeps going.
func withTimeout<T>(seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
    let gate = OnceGate<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.set(continuation)
        let work = Task {
            do { gate.resume(.success(try await operation())) } catch { gate.resume(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work.cancel()
            gate.resume(.failure(MurmurError("Timed out")))
        }
    }
}

/// Lets whichever of two racers finishes first resume the waiter, exactly once.
private final class OnceGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) { lock.withLock { continuation = c } }

    func resume(_ result: Result<T, Error>) {
        let c = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}

extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
