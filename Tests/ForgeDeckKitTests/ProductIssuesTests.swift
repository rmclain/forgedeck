import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ProductIssuesTests {
    private func product() -> Product {
        var product = Product(name: "Acme")
        var repo = Repository()
        repo.owner = "example"
        repo.name = "acme"
        product.repositories = [repo]
        return product
    }

    @Test func aQuickNoteBecomesAnItem() throws {
        #expect(ProductIssues.make(from: "  \n ") == nil)
        let one = try #require(ProductIssues.make(from: "  fix login flicker  "))
        #expect(one.title == "fix login flicker" && one.notes.isEmpty && !one.isDone)
        let two = try #require(ProductIssues.make(from: "export bug\nlast row missing\n\nwith filters"))
        #expect(two.title == "export bug" && two.notes == "last row missing\n\nwith filters")
        let long = try #require(ProductIssues.make(from: String(repeating: "a", count: 250)))
        #expect(long.title.count == ProductIssues.maxTitle && long.notes.count == 50)
    }

    @Test func openItemsComeFirst() {
        let now = Date.now
        var done = ProductIssue(title: "done", isDone: true, createdAt: now)
        done.doneAt = now
        let old = ProductIssue(title: "old", createdAt: now.addingTimeInterval(-100))
        let new = ProductIssue(title: "new", createdAt: now)
        #expect(ProductIssues.sorted([done, old, new]).map(\.title) == ["new", "old", "done"])
        var product = product()
        product.issues = [done, old, new]
        #expect(ProductIssues.openCount(product) == 2)
    }

    /// Items are notes, not prompts: the agent reads the code and asks before it changes anything.
    @Test func thePromptAsksBeforeItStarts() {
        var issue = ProductIssue(title: "export bug", notes: "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 in logs")
        var prompt = ProductIssues.prompt(for: issue, product: product())
        #expect(prompt.contains("\"export bug\"") && prompt.contains("Ask what you need to know") && prompt.contains("Wait for the answers"))
        #expect(prompt.contains("Do not push, deploy"))
        #expect(prompt.contains("ID: \(issue.id.uuidString)") && prompt.contains(IssueReports.relativePath) && prompt.contains("moves it to Done"))
        #expect(!prompt.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!prompt.contains("gh issue view"))
        issue.githubNumber = 12
        prompt = ProductIssues.prompt(for: issue, product: product())
        #expect(prompt.contains("`gh issue view 12 --repo example/acme --comments`"))
        #expect(ProductIssues.prompt(for: ProductIssue(title: "x"), product: product()).contains("Notes: none."))
    }

    /// Several selected items go to one session: questions for all of them first, then one item at a time.
    @Test func severalItemsShareOneSessionAndOneRoundOfQuestions() {
        let issues = (1...12).map { ProductIssue(title: "item \($0)", notes: $0 == 2 ? "only on mobile" : "") }
        let prompt = ProductIssues.prompt(for: issues, product: product())
        #expect(prompt.contains("12 items:"))
        #expect(prompt.contains("1. \"item 1\"\nID: \(issues[0].id.uuidString)\nNotes: none.")
                && prompt.contains("2. \"item 2\"\nID: \(issues[1].id.uuidString)\nNotes:\nonly on mobile"))
        #expect(prompt.contains("10. \"item 10\"") && prompt.contains("12. \"item 12\""))
        #expect(prompt.contains("grouped under each item's number") && prompt.contains("all in one message"))
        #expect(prompt.contains("one at a time") && prompt.contains("Do not push, deploy"))
        #expect(prompt.contains("keeping the items already there") && prompt.contains("ID: \(issues[9].id.uuidString)"))
        #expect(ProductIssues.prompt(for: [issues[0]], product: product()) == ProductIssues.prompt(for: issues[0], product: product()))
    }

    @Test func gitHubCopyUsesGhWithTheRepositoryAndReadsBackTheNumber() throws {
        let repo = try #require(ProductIssues.repository(product()))
        let args = ProductIssues.githubCreateArguments(ProductIssue(title: "export bug", notes: "last row"), repository: repo)
        #expect(args == ["issue", "create", "--repo", "example/acme", "--title", "export bug", "--body", "last row\n\nAdded from \(Brand.name)."])
        let output = "Creating issue in example/acme\n\nhttps://github.com/example/acme/issues/42\n"
        let created = try #require(ProductIssues.createdIssue(fromOutput: output, repository: repo))
        #expect(created.number == 42 && created.url == "https://github.com/example/acme/issues/42")
        #expect(ProductIssues.createdIssue(fromOutput: "https://github.com/other/repo/issues/9", repository: repo) == nil)
        #expect(ProductIssues.repository(Product(name: "No repo")) == nil)
    }

    @Test func productsSavedBeforeIssuesLoadWithGitHubOff() throws {
        let data = try JSONEncoder().encode(Product(name: "Acme"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "issues")
        json.removeValue(forKey: "issuesToGitHub")
        let product = try JSONDecoder().decode(Product.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(product.issues == nil && product.issuesToGitHub != true)
    }

    @Test func demoIssuesAreOnlyOnDemoProducts() {
        let lumen = DemoFixtures.products().first { $0.slug == "lumen" }
        #expect(lumen?.isDemo == true && (lumen?.issues?.count ?? 0) > 0)
        #expect(DemoFixtures.issues().allSatisfy { $0.githubURL?.contains("-demo/") ?? true })
    }

    // MARK: The agent's done report

    private func started(_ title: String, at date: Date) -> ProductIssue {
        var issue = ProductIssue(title: title)
        issue.startedAt = date
        issue.startedWith = "claude"
        return issue
    }

    @Test func aDoneReportMovesTheStartedItemToDone() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let issue = started("export bug", at: start)
        let untouched = ProductIssue(title: "never started")
        let data = Data("""
        {"done": [{"id": "\(issue.id.uuidString)", "summary": "Kept the last row.\\nAdded a test. token ghp_abcdefghijklmnopqrstuvwxyz0123456789"},
                  {"id": "\(untouched.id.uuidString)"}, {"id": "not-a-uuid"}]}
        """.utf8)
        let entries = try #require(IssueReports.parse(data))
        #expect(entries.count == 3)
        let now = Date(timeIntervalSince1970: 3_000)
        let result = IssueReports.apply([.init(entries: entries, written: start.addingTimeInterval(60))], to: [issue, untouched], now: now)
        #expect(result.closed.map(\.id) == [issue.id])
        let done = try #require(result.issues.first { $0.id == issue.id })
        #expect(done.isDone && done.doneAt == now && done.doneBy == "claude")
        #expect(done.doneSummary?.hasPrefix("Kept the last row. Added a test.") == true && done.doneSummary?.contains("ghp_abcdef") == false)
        #expect(result.issues.first { $0.id == untouched.id }?.isDone == false)
    }

    @Test func anOldReportDoesNotCloseAnItemAgain() {
        let start = Date(timeIntervalSince1970: 1_000)
        var issue = started("export bug", at: start)
        let entry = IssueReports.Entry(id: issue.id.uuidString, summary: "done")
        // Written before this session started: a leftover from an earlier one.
        #expect(IssueReports.apply([.init(entries: [entry], written: start.addingTimeInterval(-5))], to: [issue]).closed.isEmpty)
        // Reopened by the person after the report.
        issue.reopenedAt = start.addingTimeInterval(120)
        #expect(IssueReports.apply([.init(entries: [entry], written: start.addingTimeInterval(60))], to: [issue]).closed.isEmpty)
        // A new report after the reopen closes it.
        #expect(IssueReports.apply([.init(entries: [entry], written: start.addingTimeInterval(180))], to: [issue]).closed.count == 1)
        // Already done: nothing changes.
        issue.isDone = true
        #expect(IssueReports.apply([.init(entries: [entry], written: start.addingTimeInterval(180))], to: [issue]).closed.isEmpty)
    }

    @Test func aBrokenOrMissingReportIsIgnored() throws {
        #expect(IssueReports.parse(Data("{\"finished\": []}".utf8)) == nil)
        #expect(IssueReports.parse(Data("not json".utf8)) == nil)
        let folder = FileManager.default.temporaryDirectory.appending(path: "issue-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(IssueReports.read(folder: folder.path) == nil)
        try FileManager.default.createDirectory(at: folder.appending(path: ".forgedeck"), withIntermediateDirectories: true)
        try Data("{\"done\": [{\"id\": \"x\"}]}".utf8).write(to: folder.appending(path: IssueReports.relativePath))
        #expect(IssueReports.read(folder: folder.path)?.entries.count == 1)
        #expect(AgentFiles.relativePaths.contains(IssueReports.relativePath))
    }
}
