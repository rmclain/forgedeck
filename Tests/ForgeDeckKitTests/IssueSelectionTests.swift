import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct IssueSelectionTests {
    func issues(_ count: Int, notes: Int = 50) -> [ProductIssue] {
        (1...count).map { ProductIssue(title: "Item \($0)", notes: String(repeating: "n", count: notes)) }
    }

    @Test func oneSessionTakesEverySelectedItem() {
        let product = Product(name: "App")
        let selected = issues(25)
        let prompt = ProductIssues.prompt(for: selected, product: product)
        #expect(prompt.contains("25 items"))
        #expect(selected.allSatisfy { prompt.contains("ID: \($0.id.uuidString)") })
        #expect(prompt.contains("25. \"Item 25\""))
    }

    @Test func longNotesAreShortenedSoTheWholeSelectionFits() {
        var product = Product(name: "App")
        product.slug = "app"
        let selected = issues(40, notes: 8_000)
        let prompt = ProductIssues.prompt(for: selected, product: product)
        #expect(prompt.count < ProductIssues.promptNotesBudget + 40 * 400 + 3_000)
        #expect(prompt.contains("forgedeck issue list app --json"))
        // A few items keep their notes whole.
        let few = ProductIssues.prompt(for: issues(3, notes: 2_000), product: product)
        #expect(!few.contains("shortened"))
    }

    @Test func onePlanCanCoverSeveralItems() throws {
        let product = Product(name: "App")
        let selected = issues(12)
        var plan = FeaturePlan(request: FeaturePlans.request(for: selected))
        plan.issueIDs = selected.map(\.id)
        #expect(plan.linkedIssueIDs == selected.map(\.id))
        let prompt = FeaturePlans.planPrompt(plan, issues: selected, product: product)
        #expect(prompt.contains("covers these 12 items") && selected.allSatisfy { prompt.contains($0.id.uuidString) })
        #expect(prompt.contains("Plan ID: \(plan.id.uuidString)"))

        // A plan made from one item, saved before plans could cover several, still links to it.
        let single = FeaturePlan(request: "x", issueID: selected[0].id)
        #expect(single.linkedIssueIDs == [selected[0].id])
        var json = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(single)) as? [String: Any])
        json["issueIDs"] = nil
        let decoded = try JSONCoding.decoder().decode(FeaturePlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.linkedIssueIDs == [selected[0].id])
    }

    @Test func aGitHubItemPointsAtItsOwnRepository() {
        var product = Product(name: "App")
        var repo = Repository()
        repo.provider = "github"; repo.owner = "acme"; repo.name = "app"
        product.repositories = [repo]
        var issue = ProductIssue(title: "From the other repo")
        issue.githubNumber = 4
        issue.githubURL = "https://github.com/acme/api/issues/4"
        #expect(ProductIssues.prompt(for: [issue], product: product).contains("--repo acme/api"))
    }

    @Test func aReadyPlanTicksOffStepsWhenTheAgentGoesAheadFromItsTerminal() {
        let asked = Date(timeIntervalSince1970: 1_000)
        var plan = FeaturePlan(request: "two items", createdAt: asked)
        plan.requestedAt = asked
        plan.phase = .ready
        plan.steps = [.init(id: "1", title: "One"), .init(id: "2", title: "Two")]
        let id = plan.id.uuidString
        let stale = IssueReports.Report(entries: [], steps: [.init(plan: id, step: "1")], written: asked.addingTimeInterval(-10))
        #expect(FeaturePlans.applyProgress([stale], to: [plan]).stepsDone == 0)
        let later = asked.addingTimeInterval(600)
        let first = FeaturePlans.applyProgress([.init(entries: [], steps: [.init(plan: id, step: "1")], written: later)], to: [plan], now: later)
        #expect(first.stepsDone == 1 && first.plans[0].phase == .executing && first.plans[0].executedAt == later)
        let rest = FeaturePlans.applyProgress([.init(entries: [], steps: [.init(plan: id, step: "2")], written: later.addingTimeInterval(60))], to: first.plans)
        #expect(rest.finished.count == 1 && rest.plans[0].phase == .done)
        let prompt = FeaturePlans.planPrompt(plan, issues: [], product: Product(name: "App"))
        #expect(prompt.contains("go ahead") && prompt.contains("\"steps\" list"))
    }

    @Test func doneItemsStillOpenOnGitHubCanBeClosed() throws {
        var product = Product(name: "App")
        var repo = Repository()
        repo.provider = "github"
        repo.owner = "acme"
        repo.name = "app"
        product.repositories = [repo]
        var open = GitHubIssueSummary()
        open.number = 7
        open.url = "https://github.com/acme/app/issues/7"
        var snapshot = RemoteSnapshot()
        snapshot.issues = [open]
        var cache = ObservationCache()
        cache.remotes[repo.id] = snapshot
        var done = ProductIssue(title: "Fix export", isDone: true)
        done.githubNumber = 7
        done.githubURL = open.url
        done.doneSummary = "Export keeps the last row."
        var closedThere = ProductIssue(title: "Old", isDone: true)
        closedThere.githubNumber = 3
        closedThere.githubURL = "https://github.com/acme/app/issues/3"
        var stillOpenHere = ProductIssue(title: "Open")
        stillOpenHere.githubNumber = 7
        product.issues = [done, closedThere, stillOpenHere]
        #expect(ProductIssues.openOnGitHub(product, cache: cache).map(\.id) == [done.id])
        let args = try #require(ProductIssues.githubCloseArguments(done, product: product))
        #expect(Array(args.prefix(7)) == ["issue", "close", "7", "--repo", "acme/app", "--reason", "completed"])
        #expect(args[7] == "--comment" && args[8].hasPrefix("Export keeps the last row."))
        #expect(ProductIssues.githubCloseArguments(ProductIssue(title: "local only"), product: product) == nil)
    }
}
