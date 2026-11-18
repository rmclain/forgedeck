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
        #expect(prompt.contains("10 items:"))
        #expect(prompt.contains("1. \"item 1\"\nNotes: none.") && prompt.contains("2. \"item 2\"\nNotes:\nonly on mobile"))
        #expect(prompt.contains("10. \"item 10\"") && !prompt.contains("item 11"))
        #expect(prompt.contains("grouped under each item's number") && prompt.contains("all in one message"))
        #expect(prompt.contains("one at a time") && prompt.contains("Do not push, deploy"))
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
}
