import Foundation

// A product's Memory: rules and key facts kept on this Mac, so a new agent session does not start from nothing.
// Every session ForgeDeck starts gets them in its prompt, and CONTEXT.md lists them for sessions that read it.
// When an agent learns something the next session needs, it adds it to `.forgedeck/memory.json` in the folder.
// The app moves those entries into the list and empties the file. The person edits or deletes anything there.

public struct MemoryNote: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Something to always or never do: "Run the tests with make test, not swift test".
        case rule
        /// A fact worth knowing: "Billing webhooks arrive at /api/stripe; the secret is STRIPE_WEBHOOK".
        case note

        public var title: String { self == .rule ? "Rule" : "Note" }
    }

    public var id = UUID()
    public var text: String
    public var kind: Kind
    public var createdAt = Date.now
    /// The agent program that added it. nil when the person did.
    public var addedBy: String?

    public init(id: UUID = UUID(), text: String, kind: Kind = .note, createdAt: Date = .now, addedBy: String? = nil) {
        self.id = id
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
        self.addedBy = addedBy
    }

    enum CodingKeys: String, CodingKey { case id, text, kind, createdAt, addedBy }

    /// An unknown kind from a newer build loads as a note.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .note
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        addedBy = try c.decodeIfPresent(String.self, forKey: .addedBy)
    }
}

public enum ProductMemory {
    public static let relativePath = ".forgedeck/memory.json"
    public static let maxText = 500
    /// The most items a product keeps. An agent's entries past it are left out, and the person is told.
    public static let maxItems = 100
    /// The most of the prompt memory may take. Rules go in first, then the newest notes; CONTEXT.md has them all.
    public static let maxPromptCharacters = 6_000
    static let maxFileBytes = 64 * 1024
    static let maxFileEntries = 25

    /// A new item from what was typed, or nil when there is nothing to keep. Lines are joined and secrets redacted.
    public static func make(_ text: String, kind: MemoryNote.Kind, addedBy: String? = nil, now: Date = .now) -> MemoryNote? {
        let clean = self.clean(text)
        guard !clean.isEmpty else { return nil }
        return MemoryNote(text: clean, kind: kind, createdAt: now, addedBy: addedBy)
    }

    /// One line, redacted, at most `maxText` characters.
    public static func clean(_ text: String) -> String {
        let joined = Redactor().redact(text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return String(joined.prefix(maxText))
    }

    /// Rules first, then notes; oldest first in each, so the list reads in the order it was learned.
    public static func sorted(_ notes: [MemoryNote]) -> [MemoryNote] {
        notes.filter { $0.kind == .rule }.sorted { $0.createdAt < $1.createdAt }
            + notes.filter { $0.kind == .note }.sorted { $0.createdAt < $1.createdAt }
    }

    public static func count(_ product: Product) -> Int { product.memory?.count ?? 0 }

    /// Case, spacing, and a final full stop do not make two items different.
    static func key(_ text: String) -> String {
        var words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = words.last, ".!".contains(last) { words.removeLast() }
        return words
    }

    public static func contains(_ text: String, in notes: [MemoryNote]) -> Bool {
        let wanted = key(text)
        return notes.contains { key($0.text) == wanted }
    }

    /// What the agent is told when it starts: the memory, then how to add to it.
    public static func prompt(_ product: Product) -> String {
        var lines = ["\(Brand.name) memory for \(product.name): rules and key facts earlier sessions and the person saved. Read them before you start."]
        let notes = sorted(product.memory ?? [])
        if notes.isEmpty {
            lines.append("It is empty so far.")
        } else {
            var used = 0
            var shown: [MemoryNote] = []
            // Rules always fit first; notes fill what is left, newest first.
            for note in notes.filter({ $0.kind == .rule }) + notes.filter({ $0.kind == .note }).reversed() {
                guard used + note.text.count <= maxPromptCharacters else { continue }
                used += note.text.count
                shown.append(note)
            }
            let ids = Set(shown.map(\.id))
            lines += notes.filter { ids.contains($0.id) }.map { "- \($0.kind == .rule ? "Rule" : "Note"): \($0.text)" }
            if shown.count < notes.count {
                lines.append("\(notes.count - shown.count) more in the Memory section of the context file.")
            }
            lines.append("Follow the rules unless the person says otherwise in this session. If one is wrong or out of date, say so; do not edit the list yourself.")
        }
        lines.append(instruction)
        return lines.joined(separator: "\n")
    }

    /// How an agent adds to the memory.
    public static var instruction: String {
        "When you learn something a future session on this product would need and could not quickly find (a rule the person states, "
            + "a decision and its reason, a trap you hit, where something non-obvious lives), add it to `\(relativePath)` in this folder: "
            + "{\"add\": [{\"kind\": \"rule\", \"text\": \"One sentence.\"}]}. Kind is rule (always or never do something) or note (a fact). "
            + "Keep entries already in the file. Only lasting facts: not task progress, nothing the code or README already says plainly, never a secret value. "
            + "\(Brand.name) adds them to the memory and empties the file."
    }

    /// The Memory section of CONTEXT.md: every item, then how to add one.
    public static func contextSection(_ product: Product) -> String {
        let notes = sorted(product.memory ?? [])
        var text = "## Memory\n\nRules and key facts saved for \(product.name) by the person and earlier sessions. Read them before you start."
        if notes.isEmpty {
            text += " None saved yet."
        } else {
            text += "\n\n" + notes.map { "- \($0.kind == .rule ? "Rule" : "Note"): \($0.text)" }.joined(separator: "\n")
        }
        return text + "\n\n" + instruction
    }

    // MARK: The agent's file

    public struct Entry: Codable, Hashable, Sendable {
        public var text: String
        public var kind: String?
        public init(text: String, kind: String? = nil) { self.text = text; self.kind = kind }
    }

    /// One checkout's file: what it holds and the exact bytes read, so the app empties it only if nothing was added since.
    public struct Inbox: Hashable, Sendable {
        public var folder: String
        public var entries: [Entry]
        public var data: Data
    }

    public static func parse(_ data: Data) -> [Entry]? {
        struct File: Decodable { var add: [Entry] }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return Array(file.add.prefix(maxFileEntries))
    }

    public static func read(_ product: Product) -> [Inbox] {
        product.checkouts.compactMap { read(folder: $0.path) }
    }

    public static func read(folder: String) -> Inbox? {
        let url = URL(fileURLWithPath: folder).appending(path: relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxFileBytes,
              let data = try? Data(contentsOf: url), let entries = parse(data) else { return nil }
        return Inbox(folder: folder, entries: entries, data: data)
    }

    /// The memory with the agent's entries added, the ones added, and how many were left out because the list is full.
    /// Repeats and empty entries are skipped.
    public static func merge(_ entries: [Entry], into notes: [MemoryNote], by agent: String?, now: Date = .now)
        -> (notes: [MemoryNote], added: [MemoryNote], leftOut: Int) {
        var notes = notes
        var added: [MemoryNote] = []
        var leftOut = 0
        for entry in entries {
            let kind = MemoryNote.Kind(rawValue: (entry.kind ?? "").lowercased().trimmingCharacters(in: .whitespaces)) ?? .note
            guard let note = make(entry.text, kind: kind, addedBy: agent, now: now), !contains(note.text, in: notes) else { continue }
            guard notes.count < maxItems else { leftOut += 1; continue }
            notes.append(note)
            added.append(note)
        }
        return (notes, added, leftOut)
    }

    /// Empties the file once its entries are in the memory. Left alone if the agent wrote to it after it was read.
    public static func empty(_ inbox: Inbox) {
        let url = URL(fileURLWithPath: inbox.folder).appending(path: relativePath)
        guard (try? Data(contentsOf: url)) == inbox.data else { return }
        try? Data("{\"add\": []}\n".utf8).write(to: url, options: .atomic)
    }
}
