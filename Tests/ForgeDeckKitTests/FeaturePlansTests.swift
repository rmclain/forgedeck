import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct FeaturePlansTests {
    private let asked = Date(timeIntervalSince1970: 1_000)

    private func plan() -> FeaturePlan { FeaturePlan(request: "dark mode for the widget", createdAt: asked) }

    private func file(_ plan: FeaturePlan, steps: String? = nil, extra: String = "") -> Data {
        let steps = steps ?? """
        [{"id": "1", "title": "CSS variables", "detail": "Move colors", "files": ["src/widget.css"]},
         {"id": "2", "title": "Dark palette"}, {"id": "3", "title": "Switcher", "optional": true}]
        """
        return Data("""
        {"plan": "\(plan.id.uuidString)", "title": "Dark mode", "summary": "Use variables.", "steps": \(steps),
         "questions": ["Follow the host page?"], "risks": []\(extra)}
        """.utf8)
    }

    @Test func aGoodPlanFileBecomesTheChecklist() throws {
        let plan = plan()
        let parsed = FeaturePlans.parse(file(plan), written: asked.addingTimeInterval(30))
        #expect(parsed.isUsable && parsed.steps.map(\.id) == ["1", "2", "3"] && parsed.steps[2].optional == true)
        #expect(parsed.steps[0].files == ["src/widget.css"] && parsed.questions == ["Follow the host page?"] && parsed.risks.isEmpty)
        let result = FeaturePlans.applyFiles([parsed], to: [plan])
        #expect(result.ready.count == 1)
        let ready = try #require(result.plans.first)
        #expect(ready.phase == .ready && ready.name == "Dark mode" && ready.summary == "Use variables." && ready.steps.count == 3)
    }

    @Test func aFileIsCheckedAsUntrustedInput() {
        let plan = plan()
        let bad = FeaturePlans.parse(file(plan, steps: """
        [{"id": "1", "title": "a", "files": ["../../etc/passwd"]}, {"id": "1", "title": ""},
         {"id": "has space", "title": "x", "detail": "key sk_live_\("51Habcdefghijklmnopqrstuvwx")"}]
        """), written: asked)
        #expect(!bad.isUsable)
        #expect(bad.problems.contains { $0.contains("outside the project folder") })
        #expect(bad.problems.contains { $0.contains("repeats the id") } && bad.problems.contains { $0.contains("has no title") })
        #expect(bad.problems.contains { $0.contains("short id") } && bad.problems.contains { $0.contains("looks like a secret") })
        #expect(!FeaturePlans.parse(Data("nope".utf8), written: asked).isUsable)
        #expect(FeaturePlans.parse(Data("{\"steps\": [{\"id\": \"1\", \"title\": \"a\"}]}".utf8), written: asked).problems.contains { $0.contains("plan ID") })
        let many = "[" + (1...31).map { "{\"id\": \"\($0)\", \"title\": \"s\"}" }.joined(separator: ",") + "]"
        #expect(FeaturePlans.parse(file(plan, steps: many), written: asked).problems.contains { $0.contains("the most is 30") })
        #expect(FeaturePlans.isRelativePath("src/a.ts") && !FeaturePlans.isRelativePath("/etc/hosts") && !FeaturePlans.isRelativePath("~/x"))
    }

    @Test func onlyTheWaitingPlanWithTheSameIDTakesANewFile() {
        let plan = plan()
        let other = FeaturePlan(request: "other", createdAt: asked)
        // Written before the request: a leftover.
        #expect(FeaturePlans.applyFiles([FeaturePlans.parse(file(plan), written: asked.addingTimeInterval(-1))], to: [plan]).ready.isEmpty)
        // Another plan's file.
        #expect(FeaturePlans.applyFiles([FeaturePlans.parse(file(other), written: asked.addingTimeInterval(5))], to: [plan]).ready.isEmpty)
        // A plan already reviewed doesn't change under the person.
        var ready = plan
        ready.phase = .ready
        #expect(FeaturePlans.applyFiles([FeaturePlans.parse(file(plan), written: asked.addingTimeInterval(5))], to: [ready]).ready.isEmpty)
        // A broken file for the waiting plan explains itself.
        let broken = FeaturePlans.parse(file(plan, steps: "[]"), written: asked.addingTimeInterval(5))
        #expect(FeaturePlans.problems([broken], for: plan) == ["It has no steps."])
    }

    private func executing() -> FeaturePlan {
        let waiting = plan()
        var plan = FeaturePlans.applyFiles([FeaturePlans.parse(file(waiting), written: asked.addingTimeInterval(5))], to: [waiting]).plans[0]
        plan.steps[2].skipped = true
        plan.steps[0].note = "keep the old names\nas aliases"
        plan.phase = .executing
        plan.executedAt = asked.addingTimeInterval(60)
        return plan
    }

    @Test func reportedStepsTickOffAndTheLastOneFinishesThePlan() throws {
        let plan = executing()
        let id = plan.id.uuidString
        let early = IssueReports.Report(entries: [], steps: [.init(plan: id, step: "1")], written: asked.addingTimeInterval(30))
        #expect(FeaturePlans.applyProgress([early], to: [plan]).stepsDone == 0)
        let first = IssueReports.Report(entries: [], steps: [.init(plan: id, step: "1", summary: "Variables in place."), .init(plan: id, step: "3")],
                                        written: asked.addingTimeInterval(120))
        let partway = FeaturePlans.applyProgress([first], to: [plan])
        #expect(partway.stepsDone == 1 && partway.finished.isEmpty && partway.plans[0].progress == (1, 2))
        #expect(partway.plans[0].steps[0].summary == "Variables in place." && !partway.plans[0].steps[2].isDone)
        let both = IssueReports.Report(entries: [], steps: [.init(plan: id, step: "1"), .init(plan: id, step: "2")], written: asked.addingTimeInterval(200))
        let finished = FeaturePlans.applyProgress([both], to: partway.plans)
        #expect(finished.stepsDone == 1 && finished.finished.count == 1 && finished.plans[0].phase == .done)
    }

    @Test func theDoneReportCarriesStepsAlongsideIssues() throws {
        let parsed = try #require(IssueReports.parseReport(Data("{\"steps\": [{\"plan\": \"p\", \"step\": \"1\"}]}".utf8)))
        #expect(parsed.entries.isEmpty && parsed.steps == [.init(plan: "p", step: "1")])
        #expect(IssueReports.parseReport(Data("{}".utf8)) == nil)
    }

    @Test func leftOutStepsBecomeIssues() {
        let issues = FeaturePlans.issuesForSkippedSteps(executing())
        #expect(issues.map(\.title) == ["Switcher"] && issues[0].notes.contains("Left out of the plan"))
    }

    @Test func theMessagesSayWhatToDoAndStayOnOneLineWhenTyped() {
        var product = Product(name: "Acme")
        product.slug = "acme"
        let waiting = plan()
        let prompt = FeaturePlans.planPrompt(waiting, issue: nil, product: product)
        #expect(prompt.contains("Plan ID: \(waiting.id.uuidString)") && prompt.contains(FeaturePlans.relativePath))
        #expect(prompt.contains("change no code") && prompt.contains("Do not push, deploy"))
        let plan = executing()
        let line = FeaturePlans.executeMessage(plan, note: "small commits\nplease")
        #expect(!line.contains("\n") && !line.contains("\r"))
        #expect(line.contains("1 (CSS variables), 2 (Dark palette)") && line.contains("Skip step 3"))
        #expect(line.contains("step 1: keep the old names as aliases") && line.contains("Overall: small commits please."))
        #expect(line.contains(IssueReports.relativePath) && line.contains("\"plan\": \"\(plan.id.uuidString)\""))
        let full = FeaturePlans.executePrompt(plan, note: nil, product: product)
        #expect(full.contains("1. CSS variables — Move colors") && full.contains("Left out, don't do: 3. Switcher"))
        let revise = FeaturePlans.reviseMessage(plan, note: "fewer steps")
        #expect(!revise.contains("\n") && revise.contains("fewer steps.") && revise.contains("same plan ID"))
    }

    @Test func demoPlansAreLabelledDemo() {
        let lumen = DemoFixtures.products().first { $0.slug == "lumen" }
        #expect(lumen?.isDemo == true && lumen?.plans?.contains { $0.phase == .ready } == true)
    }
}
