// Remembers the open windows across launches: where each one sat, which T3 page it
// showed, and whether it has paired. Each window's filters, panels and drafts are not
// kept here; they live in that window's own WebKit storage (see ProWindowController).

import Foundation

struct WindowRecord: Codable, Equatable {
    /// Also names the window's WebKit data store and its session label on the server.
    var id: UUID
    /// The last T3 page the window showed (a thread, a draft, settings). Nil until it loads one.
    var url: String?
    /// The window frame, as `NSStringFromRect` writes it.
    var frame: String?
    /// True once this window's storage holds a session cookie.
    var paired: Bool = false
    /// Page zoom set from the title bar control; nil is 100%.
    var zoom: Double?
}

@MainActor
final class WindowStore {
    static let shared = WindowStore()

    private let file: URL
    private(set) var records: [WindowRecord] = []

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("T3 Code Pro Max", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        file = support.appendingPathComponent("windows.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([WindowRecord].self, from: data) {
            records = saved
        }
    }

    func upsert(_ record: WindowRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            guard records[index] != record else { return }
            records[index] = record
        } else {
            records.append(record)
        }
        save()
    }

    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
