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
    /// Set when the agent reported it finished (`.forgedeck/issues-done.json`): which agent, and its one-line summary.
    public var doneBy: String?
    public var doneSummary: String?
    /// When the person last moved it back to Open. A report written before this does not close it again.
    public var reopenedAt: Date?

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

    /// An open issue in one of the product's GitHub repositories.
    public struct GitHubItem: Hashable, Sendable, Identifiable {
        public var repository: Repository
        public var issue: GitHubIssueSummary
        public var id: String { issue.url.isEmpty ? "\(repository.owner)/\(repository.name)#\(issue.number)" : issue.url }
        public var repositoryName: String { "\(repository.owner)/\(repository.name)" }
    }

    /// True when a local item already stands for this GitHub issue: same link, or same number in that repository.
    public static func isLinked(_ item: GitHubItem, in issues: [ProductIssue]) -> Bool {
        issues.contains { local in
            if let url = local.githubURL, !url.isEmpty, !item.issue.url.isEmpty { return url.lowercased() == item.issue.url.lowercased() }
            return local.githubNumber == item.issue.number && local.githubURL == nil
        }
    }

    /// Open issues from every GitHub repository of the product that are not in its list yet, most recently updated first.
    public static func githubIssues(_ product: Product, cache: ObservationCache) -> [GitHubItem] {
        let local = product.issues ?? []
        var seen = Set<String>()
        return product.repositories.filter { $0.provider == "github" }
            .flatMap { repo in (cache.remotes[repo.id]?.issues ?? []).map { GitHubItem(repository: repo, issue: $0) } }
            .filter { seen.insert($0.id).inserted && !isLinked($0, in: local) }
            .sorted { $0.issue.updatedAt > $1.issue.updatedAt }
    }

    /// When the product's GitHub issues were last read, or nil when none of its repositories have been.
    public static func githubCheckedAt(_ product: Product, cache: ObservationCache) -> Date? {
        product.repositories.filter { $0.provider == "github" }
            .compactMap { cache.remotes[$0.id].flatMap { $0.issues == nil ? nil : $0.provenance.observedAt } }.max()
    }

    /// The local item for a GitHub issue: its title, the start of its description, and the link back.
    public static func imported(_ item: GitHubItem, now: Date = .now) -> ProductIssue {
        var issue = ProductIssue(title: String(item.issue.title.prefix(maxTitle)), createdAt: now)
        let header = "GitHub \(item.repositoryName)#\(item.issue.number)" + (item.issue.labels.isEmpty ? "" : " · " + item.issue.labels.joined(separator: ", "))
        issue.notes = String([header, item.issue.body.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
            .joined(separator: "\n\n").prefix(maxNotes))
        issue.githubNumber = item.issue.number
        issue.githubURL = item.issue.url.isEmpty ? nil : item.issue.url
        return issue
    }

    /// Open items for the tab's badge: the list's open items plus GitHub issues not in it yet.
    public static func openCount(_ product: Product, cache: ObservationCache) -> Int {
        openCount(product) + githubIssues(product, cache: cache).count
    }

    /// The most items one agent session takes at once.
    public static let maxPerSession = 10

    /// The agent's first message. The item is usually a short note, so the agent looks at the code, says what
    /// it thinks the item means, and asks before it changes anything.
    public static func prompt(for issue: ProductIssue, product: Product) -> String {
        prompt(for: [issue], product: product)
    }

    /// One session for several items: the agent asks about all of them in one message, then works through them in turn.
    public static func prompt(for issues: [ProductIssue], product: Product) -> String {
        let issues = Array(issues.prefix(maxPerSession))
        guard issues.count > 1 else { return single(issues.first ?? ProductIssue(title: ""), product: product) }
        var lines = ["From the Issues list \(Brand.name) keeps for \(product.name), \(issues.count) items:"]
        for (index, issue) in issues.enumerated() { lines += ["", "\(index + 1). " + describe(issue, product: product)] }
        lines += ["",
                  "These are short notes the person wrote for themselves, not full requests. Before you change anything:",
                  "1. Look at the code each item most likely touches.",
                  "2. For each item, say in a sentence what you think it asks for.",
                  "3. Ask what you need to know to do them well, grouped under each item's number: what done looks like, the scope, "
                      + "anything ambiguous. At most three short questions per item, all in one message. Skip what the code already answers.",
                  "4. Wait for the answers. Then do the items one at a time, in the order that makes sense. Run the tests after each, "
                      + "and say which item is finished before you start the next.",
                  IssueReports.instruction(several: true),
                  "Do not push, deploy, or open, close, or comment on GitHub issues."]
        return lines.joined(separator: "\n")
    }

    /// Title, ID, notes, and the GitHub issue when there is one.
    private static func describe(_ issue: ProductIssue, product: Product) -> String {
        let redactor = Redactor()
        let notes = redactor.redact(issue.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        var text = "\"\(redactor.redact(issue.title))\"\nID: \(issue.id.uuidString)\n" + (notes.isEmpty ? "Notes: none." : "Notes:\n\(notes)")
        if let number = issue.githubNumber, let repo = repository(product) {
            text += "\nIt is GitHub issue #\(number) in \(repo.owner)/\(repo.name). Read the discussion with `gh issue view \(number) --repo \(repo.owner)/\(repo.name) --comments` if it helps."
        }
        return text
    }

    private static func single(_ issue: ProductIssue, product: Product) -> String {
        var lines = ["From the Issues list \(Brand.name) keeps for \(product.name): " + describe(issue, product: product)]
        lines += ["",
                  "This is a short note the person wrote for themselves, not a full request. Before you change anything:",
                  "1. Look at the code it most likely touches, and recent commits if they help.",
                  "2. Say in one or two sentences what you think it asks for.",
                  "3. Ask what you need to know to do it well: what done looks like, the scope, anything ambiguous. "
                      + "At most four short numbered questions, in one message. Skip what the code already answers.",
                  "4. Wait for the answers. Then give a short plan, do the work, and run the tests.",
                  IssueReports.instruction(several: false),
                  "Do not push, deploy, or open, close, or comment on GitHub issues."]
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

// When the agent finishes an item it writes `.forgedeck/issues-done.json` with the item's ID and a one-line summary.
// The app reads it while the session runs and on every refresh, and moves the item to Done. Only items an agent was
// started on can be closed this way, only by a report written after that start, and never one the person reopened later.

public enum IssueReports {
    public static let relativePath = ".forgedeck/issues-done.json"
    static let maxBytes = 64 * 1024
    static let maxEntries = 50
    public static let maxSummary = 280

    public struct Entry: Codable, Hashable, Sendable {
        public var id: String
        public var summary: String?
        public init(id: String, summary: String? = nil) { self.id = id; self.summary = summary }
    }

    /// A plan step the agent finished.
    public struct StepEntry: Codable, Hashable, Sendable {
        public var plan: String
        public var step: String
        public var summary: String?
        public init(plan: String, step: String, summary: String? = nil) { self.plan = plan; self.step = step; self.summary = summary }
    }

    /// One checkout's file and when it was last written.
    public struct Report: Hashable, Sendable {
        public var entries: [Entry]
        public var steps: [StepEntry]
        public var written: Date
        public init(entries: [Entry], steps: [StepEntry] = [], written: Date) { self.entries = entries; self.steps = steps; self.written = written }
    }

    /// What the agent is told to do when an item is finished.
    public static func instruction(several: Bool) -> String {
        let example = "{\"done\": [{\"id\": \"<the item's ID>\", \"summary\": \"One sentence: what changed.\"}]}"
        return several
            ? "When an item is finished and its tests pass, add it to `\(relativePath)` in this folder, keeping the items already there: "
                + "\(example). \(Brand.name) then moves it to Done. List only items that are really finished; leave out any you stopped on."
            : "When it is finished and the tests pass, say so and write `\(relativePath)` in this folder: \(example). "
                + "\(Brand.name) then moves it to Done. Do not write the file if you stopped before it was finished."
    }

    public static func read(_ product: Product) -> [Report] {
        product.checkouts.compactMap { read(folder: $0.path) }
    }

    public static func read(folder: String) -> Report? {
        let url = URL(fileURLWithPath: folder).appending(path: relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxBytes,
              let data = try? Data(contentsOf: url), let parsed = parseReport(data) else { return nil }
        return Report(entries: parsed.entries, steps: parsed.steps, written: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    public static func parse(_ data: Data) -> [Entry]? { parseReport(data)?.entries }

    /// Finished items under "done" and finished plan steps under "steps". Either may be left out, not both.
    public static func parseReport(_ data: Data) -> (entries: [Entry], steps: [StepEntry])? {
        struct File: Decodable { var done: [Entry]?; var steps: [StepEntry]? }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.done != nil || file.steps != nil else { return nil }
        return (Array((file.done ?? []).prefix(maxEntries)), Array((file.steps ?? []).prefix(maxEntries * 2)))
    }

    /// The items with every report applied, and the ones it moved to Done.
    public static func apply(_ reports: [Report], to issues: [ProductIssue], now: Date = .now) -> (issues: [ProductIssue], closed: [ProductIssue]) {
        var issues = issues
        var closed: [ProductIssue] = []
        let redactor = Redactor()
        for report in reports {
            for entry in report.entries {
                guard let id = UUID(uuidString: entry.id.trimmingCharacters(in: .whitespaces)),
                      let index = issues.firstIndex(where: { $0.id == id }) else { continue }
                let issue = issues[index]
                guard !issue.isDone, let started = issue.startedAt, report.written >= started,
                      issue.reopenedAt.map({ report.written > $0 }) ?? true else { continue }
                let summary = redactor.redact(entry.summary ?? "")
                    .split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                issues[index].isDone = true
                issues[index].doneAt = now
                issues[index].doneBy = issue.startedWith
                issues[index].doneSummary = summary.isEmpty ? nil : String(summary.prefix(maxSummary))
                closed.append(issues[index])
            }
        }
        return (issues, closed)
    }
}
