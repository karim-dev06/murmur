import AppKit
import ApplicationServices

/// A word or phrase Murmur got wrong, and what the person changed it to.
struct LearnedFix: Codable, Identifiable, Equatable {
    var id = UUID()
    var heard: String
    var correct: String
    var date: Date
}

/// Fixes learned from the person's own corrections, applied to everything Murmur types afterwards.
enum Learned {
    static var all: [LearnedFix] {
        guard let data = Pref.d.string(forKey: Pref.learned)?.data(using: .utf8),
              let list = try? JSONDecoder().decode([LearnedFix].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [LearnedFix]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        Pref.d.set(String(decoding: data, as: UTF8.self), forKey: Pref.learned)
    }

    /// Remembers a fix. Hearing the same thing again replaces the old fix rather than adding a second.
    static func add(heard: String, correct: String) {
        var list = all.filter { key($0.heard) != key(heard) }
        list.insert(LearnedFix(heard: heard, correct: correct, date: Date()), at: 0)
        save(Array(list.prefix(300)))
    }

    static func apply(_ text: String, fixes: [LearnedFix] = all) -> String {
        var out = text
        for fix in fixes.sorted(by: { $0.heard.count > $1.heard.count }) {
            let words = key(fix.heard).split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = "(?<![\\w])" + words.joined(separator: "[\\s,.-]+") + "(?![\\w])"
            out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: fix.correct),
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    // MARK: - Spotting corrections

    /// Compares what Murmur typed with what the person left after editing, and returns the small
    /// sound-alike swaps worth learning. Rewrites, additions and deletions are not corrections.
    static func corrections(typed: String, edited: String) -> [(heard: String, correct: String)] {
        let a = tokens(typed)
        let b = tokens(edited)
        guard !a.isEmpty, !b.isEmpty, a.count < 400, b.count < 400 else { return [] }
        var found: [(String, String)] = []
        for (oldWords, newWords) in replacements(a, b) {
            guard (1 ... 4).contains(oldWords.count), (1 ... 4).contains(newWords.count) else { continue }
            let heard = oldWords.joined(separator: " ")
            let correct = newWords.joined(separator: " ")
            if key(heard) == key(correct) {
                // Same letters: keep only a brand-style capital ("Github" → "GitHub"), not a sentence start.
                guard hasInnerCapital(correct) else { continue }
            } else {
                let (h, c) = (key(heard), key(correct))
                // "file" → "files" or "test" → "testing" is editing the sentence, not fixing a mishearing.
                guard !c.hasPrefix(h), !h.hasPrefix(c),
                      !(oldWords.count == 1 && commonWords.contains(h)),
                      soundsAlike(heard, correct) else { continue }
            }
            found.append((heard, correct))
        }
        return found
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:\"“”()")) }
            .filter { !$0.isEmpty }
    }

    /// The runs of words that were swapped, from a word-by-word comparison.
    private static func replacements(_ a: [String], _ b: [String]) -> [([String], [String])] {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [([String], [String])] = []
        var i = 0, j = 0
        var oldRun: [String] = [], newRun: [String] = []
        func flush() {
            if !oldRun.isEmpty || !newRun.isEmpty { out.append((oldRun, newRun)) }
            oldRun = []; newRun = []
        }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flush(); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                newRun.append(b[j]); j += 1
            } else {
                oldRun.append(a[i]); i += 1
            }
        }
        flush()
        // A pure insertion or deletion is the person writing more, not fixing a mishearing.
        return out.filter { !$0.0.isEmpty && !$0.1.isEmpty }
    }

    static func key(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    private static func hasInnerCapital(_ s: String) -> Bool {
        s.split(separator: " ").contains { word in word.dropFirst().contains(where: \.isUppercase) }
    }

    /// True when two phrases share their consonant sounds ("whisper pro" / "Wispr Flow",
    /// "Cuban eats" / "Kubernetes") but not when the meaning changed ("Tuesday" / "Monday").
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let letters = { (s: String) in key(s).replacingOccurrences(of: " ", with: "") }
        let plain = similarity(letters(a), letters(b))
        let sound = similarity(skeleton(a), skeleton(b))
        return sound >= 0.55 || plain >= 0.75
    }

    /// The consonants that carry the sound of a word: vowels dropped, look-alike sounds merged.
    private static func skeleton(_ s: String) -> String {
        var t = key(s).replacingOccurrences(of: " ", with: "")
        for (from, to) in [("ph", "f"), ("ck", "k"), ("qu", "k"), ("c", "k"), ("q", "k"), ("z", "s"), ("x", "ks"), ("v", "f")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        guard let first = t.first else { return "" }
        let rest = t.dropFirst().filter { !"aeiouhwy".contains($0) }
        var out = String(first)
        for ch in rest where ch != out.last { out.append(ch) }
        return out
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var row = Array(0 ... b.count)
        for i in 1 ... max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1 ... max(b.count, 1) where !b.isEmpty {
                let old = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = old
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// Single words too common to learn a fix for: changing "of" or "then" is editing, not fixing.
    private static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "so", "to", "of", "in", "on", "at", "by", "for", "with",
        "from", "up", "out", "as", "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these",
        "those", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my", "your", "our",
        "their", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should", "not", "no",
        "yes", "all", "any", "some", "more", "most", "just", "very", "too", "also", "now", "here", "there", "when",
        "what", "which", "who", "how", "why", "where", "about", "into", "over", "after", "before", "again", "off",
    ]
}

/// A short log of what learning saw, in ~/Library/Logs/Murmur.log. Kept under 200 KB.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Murmur.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// After Murmur types into a text box, watches that box for a short while. When the person
/// leaves it (or time runs out) it compares what was typed with what is there now and learns
/// from the swaps. It reads only that one text box, and nothing leaves the Mac.
@MainActor
final class CorrectionWatcher {
    var onLearned: (([(heard: String, correct: String)]) -> Void)?
    /// Which element has focus now. The system-wide focus, unless a test points it at one app.
    var focused: () -> AXUIElement? = { CorrectionWatcher.focusedElement() }

    private var element: AXUIElement?
    private var typed = ""
    private var before = ""
    private var spanStart = 0
    private var lastValue: String?
    private var timer: Timer?
    private var deadline = Date()

    func watch(_ element: AXUIElement, typed: String) {
        finish()
        // Read the box once the paste has landed, and find the typed words in it.
        guard let value = Self.value(of: element) else {
            return Log.write("learn: can't read this text box (\(Self.role(of: element)))")
        }
        guard let range = value.range(of: typed.trimmingCharacters(in: .whitespacesAndNewlines), options: .backwards) else {
            return Log.write("learn: typed words not found in the text box (\(Self.role(of: element)), \(value.count) chars)")
        }
        Log.write("learn: watching \(Self.role(of: element)) for edits")
        self.element = element
        self.typed = String(value[range])
        before = value
        spanStart = value.distance(from: value.startIndex, to: range.lowerBound)
        lastValue = value
        deadline = Date().addingTimeInterval(45)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Stops watching and learns from what the person changed so far.
    func finish() {
        timer?.invalidate()
        timer = nil
        // One last read, so a fix made just before the person moved on still counts.
        if let element, let value = Self.value(of: element) { lastValue = value }
        guard element != nil, let after = lastValue else { return reset() }
        let edited = Self.editedSpan(before: before, after: after, spanStart: spanStart, spanLength: typed.count)
        let typed = self.typed
        reset()
        guard let edited else { return Log.write("learn: text outside the typed words changed too, skipped") }
        guard edited != typed else { return Log.write("learn: no edits") }
        let found = Learned.corrections(typed: typed, edited: edited)
        guard !found.isEmpty else { return Log.write("learn: edits were not sound-alike fixes") }
        Log.write("learn: " + found.map { "\($0.heard) → \($0.correct)" }.joined(separator: ", "))
        for fix in found { Learned.add(heard: fix.heard, correct: fix.correct) }
        onLearned?(found)
    }

    private func tick() {
        guard let element else { return finish() }
        let stillThere = focused().map { CFEqual($0, element) } ?? false
        if let value = Self.value(of: element) { lastValue = value }
        if !stillThere || Date() > deadline { finish() }
    }

    private func reset() {
        element = nil
        lastValue = nil
        typed = ""
        before = ""
    }

    /// What the typed words became. Nil when the person changed text outside them too,
    /// because then the edit can't be pinned to what Murmur typed.
    nonisolated static func editedSpan(before: String, after: String, spanStart: Int, spanLength: Int) -> String? {
        let a = Array(before), b = Array(after)
        guard a != b else { return String(a[spanStart ..< min(spanStart + spanLength, a.count)]) }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let spanEnd = spanStart + spanLength
        // Everything changed must sit inside the typed words.
        guard prefix >= spanStart, a.count - suffix <= spanEnd else { return nil }
        let newEnd = b.count - (a.count - spanEnd)
        guard spanStart <= newEnd, newEnd <= b.count else { return nil }
        return String(b[spanStart ..< newEnd])
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func role(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String ?? "unknown role"
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
