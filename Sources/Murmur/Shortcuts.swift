import Foundation

/// "When I say X, type Y." Saved in settings as JSON.
struct Shortcut: Codable, Identifiable, Equatable {
    var id = UUID()
    var phrase: String
    var text: String
}

enum Shortcuts {
    static var all: [Shortcut] { decode(Pref.d.string(forKey: Pref.shortcuts)) }

    static func decode(_ json: String?) -> [Shortcut] {
        guard let data = json?.data(using: .utf8), let list = try? JSONDecoder().decode([Shortcut].self, from: data) else { return [] }
        return list.filter { !words($0.phrase).isEmpty && !$0.text.isEmpty }
    }

    static func encode(_ list: [Shortcut]) -> String {
        let kept = list.filter { !words($0.phrase).isEmpty && !$0.text.isEmpty }
        guard let data = try? JSONEncoder().encode(kept) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The whole dictation is just the phrase, so the text is typed exactly, with no tidy-up.
    static func exactMatch(_ dictation: String, in list: [Shortcut]) -> Shortcut? {
        let said = words(dictation)
        return list.first { words($0.phrase) == said }
    }

    /// The phrase said inside a sentence is swapped for its text. Longest phrases win.
    static func expand(_ dictation: String, with list: [Shortcut]) -> String {
        var out = dictation
        for shortcut in list.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            out = out.replacingOccurrences(of: pattern(shortcut), with: NSRegularExpression.escapedTemplate(for: shortcut.text),
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// The shortcuts whose phrase was said somewhere in the dictation.
    static func said(in dictation: String, from list: [Shortcut]) -> [Shortcut] {
        list.filter { dictation.range(of: pattern($0), options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static func pattern(_ shortcut: Shortcut) -> String {
        let parts = words(shortcut.phrase).map(NSRegularExpression.escapedPattern(for:))
        // Speech engines may put commas or dashes between the words.
        return "\\b" + parts.joined(separator: "[\\s,.-]+") + "\\b"
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}
