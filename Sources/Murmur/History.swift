import Foundation

struct Entry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    /// What the speech engine heard.
    var raw: String
    /// What was typed (after tidy-up).
    var text: String
    var app: String?
}

/// Every dictation is saved here before Murmur tries to type it, so nothing is ever lost.
@MainActor
final class HistoryStore {
    private(set) var entries: [Entry] = []
    private let url: URL
    private let limit = 500

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
