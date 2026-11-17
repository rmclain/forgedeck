import Foundation

// A product's Issues list: a to-do list kept on this Mac. Each item can start the agent, which reads the
// code and asks about the item before it changes anything, because most items are quick notes, not prompts.
// Copying an item to GitHub is off by default and goes through the person's own `gh` login.

public struct ProductIssue: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var notes = ""
    public var isDone = false
    public var createdAt = Date.now
    public var doneAt: Date?
    /// When an agent was last started on it, and which one.
    public var startedAt: Date?
    public var startedWith: String?
    /// Set once it is copied to GitHub.
    public var githubNumber: Int?
    public var githubURL: String?

    public init(id: UUID = UUID(), title: String, notes: String = "", isDone: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isDone = isDone
        self.createdAt = createdAt
    }
}

public enum ProductIssues {
    public static let maxTitle = 200
    public static let maxNotes = 8_000

    /// A new item from what was typed, or nil when there is nothing to add. The first line is the title;
    /// anything after it, or past the title limit, becomes the notes.
    public static func make(from text: String, now: Date = .now) -> ProductIssue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var title = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        var notes = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > maxTitle {
            notes = [String(title.dropFirst(maxTitle)), notes].filter { !$0.isEmpty }.joined(separator: "\n")
            title = String(title.prefix(maxTitle))
        }
        return ProductIssue(title: title, notes: String(notes.prefix(maxNotes)), createdAt: now)
    }

    /// Open items first, newest first; done items after, most recently done first.
    public static func sorted(_ issues: [ProductIssue]) -> [ProductIssue] {
        issues.filter { !$0.isDone }.sorted { $0.createdAt > $1.createdAt }
            + issues.filter(\.isDone).sorted { ($0.doneAt ?? $0.createdAt) > ($1.doneAt ?? $1.createdAt) }
    }

    public static func openCount(_ product: Product) -> Int { (product.issues ?? []).filter { !$0.isDone }.count }

    /// The GitHub repository items are copied to: the product's first GitHub repository.
    public static func repository(_ product: Product) -> Repository? {
        product.repositories.first { $0.provider == "github" && !$0.owner.isEmpty && !$0.name.isEmpty }
    }

    /// The agent's first message. The item is usually a short note, so the agent looks at the code, says what
    /// it thinks the item means, and asks before it changes anything.
    public static func prompt(for issue: ProductIssue, product: Product) -> String {
        let redactor = Redactor()
        var lines = ["From the Issues list \(Brand.name) keeps for \(product.name): \"\(redactor.redact(issue.title))\""]
        let notes = redactor.redact(issue.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(notes.isEmpty ? "Notes: none." : "Notes:\n\(notes)")
        if let number = issue.githubNumber, let repo = repository(product) {
            lines.append("It is GitHub issue #\(number) in \(repo.owner)/\(repo.name). Read the discussion with `gh issue view \(number) --repo \(repo.owner)/\(repo.name) --comments` if it helps.")
        }
        lines += ["",
                  "This is a short note the person wrote for themselves, not a full request. Before you change anything:",
                  "1. Look at the code it most likely touches, and recent commits if they help.",
                  "2. Say in one or two sentences what you think it asks for.",
                  "3. Ask what you need to know to do it well: what done looks like, the scope, anything ambiguous. "
                      + "At most four short numbered questions, in one message. Skip what the code already answers.",
                  "4. Wait for the answers. Then give a short plan, do the work, and run the tests.",
                  "Do not push, deploy, or open, close, or comment on GitHub issues. When it is done, say so; the person marks it done in \(Brand.name)."]
        return lines.joined(separator: "\n")
    }

    /// `gh issue create` arguments. The body is the notes, redacted, with a line saying where it came from.
    public static func githubCreateArguments(_ issue: ProductIssue, repository: Repository) -> [String] {
        let redactor = Redactor()
        let notes = redactor.redact(issue.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = [notes, "Added from \(Brand.name)."].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return ["issue", "create", "--repo", "\(repository.owner)/\(repository.name)", "--title", redactor.redact(issue.title), "--body", body]
    }

    /// The issue URL and number from `gh issue create` output: its last github.com issue link.
    public static func createdIssue(fromOutput output: String, repository: Repository) -> (url: String, number: Int)? {
        let prefix = "https://github.com/\(repository.owner)/\(repository.name)/issues/"
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.lowercased().hasPrefix(prefix.lowercased()), let number = Int(text.dropFirst(prefix.count)), number > 0 else { continue }
            return (text, number)
        }
        return nil
    }
}
