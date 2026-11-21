import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct AgentChoiceTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-21T21:40:00Z")!

    @Test func aProductCanStartItsOwnAgentAndModel() {
        var portfolio = Portfolio()
        portfolio.settings.aiAgentProgram = "claude"
        portfolio.settings.agentModels = ["claude": "sonnet", "codex": "gpt-6"]
        var product = Product(name: "API")
        #expect(portfolio.agentProgram(for: product) == "claude" && portfolio.agentModel(for: product) == "sonnet")
        #expect(portfolio.agentProgram(for: nil) == "claude")

        product.agentProgram = "codex"
        #expect(portfolio.agentProgram(for: product) == "codex" && portfolio.agentModel(for: product) == "gpt-6")
        product.agentModels = ["codex": "gpt-6-mini", "claude": "opus"]
        #expect(portfolio.agentModel(for: product) == "gpt-6-mini")
        // A model chosen for another agent never goes to this one.
        #expect(portfolio.agentModel(for: product, program: "claude") == "opus")
        #expect(portfolio.agentModel(for: product, program: "agy") == nil)
        product.agentProgram = "  "
        #expect(portfolio.agentProgram(for: product) == "claude")
    }

    @Test func productsSavedBeforeTheChoiceLoadAndFollowSettings() throws {
        let data = try JSONCoding.encoder().encode(Product(name: "Old"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["agentProgram"] = nil
        json["agentModels"] = nil
        let product = try JSONCoding.decoder().decode(Product.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(product.agentProgram == nil && product.agentModels == nil)
        #expect(Portfolio().agentProgram(for: product) == Portfolio().settings.aiAgentProgram)
    }

    @Test func agyLimitsAreReadFromItsUsageCommand() throws {
        let output = """
        Gemini Models\tWeekly Limit Remaining\t100%\t2026-11-28T21:37:50Z
        Gemini Models\tFive Hour Limit Remaining\t64%\t2026-11-22T02:37:50Z
        Claude and GPT models\tWeekly Limit Remaining\t30%\t2026-11-22T09:00:00Z
        Claude and GPT models\tFive Hour Limit Remaining\t100%\t2026-11-22T02:37:50Z
        Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t100%\t2026-11-28T21:37:50Z
        Signed in.
        """
        let windows = try #require(AgyLimitCheck.parse(output, observed: now))
        #expect(windows.map(\.name) == ["Gemini Models · Weekly", "Gemini Models · 5-hour", "Claude and GPT models · Weekly",
                                        "Claude and GPT models · 5-hour", "Gemini 4 Argon · Weekly"])
        #expect(windows[1].usedPercent == 36 && windows[1].windowMinutes == 300 && windows[0].windowMinutes == 10_080)
        #expect(windows[2].resetsAt == ISO8601DateFormatter().date(from: "2026-11-22T09:00:00Z"))
        #expect(AgyLimitCheck.parse("Error: not signed in\n", observed: now) == nil)
        #expect(AgyLimitCheck.arguments == ["--print", "/usage"])

        let tool = AgyLimitCheck.tool(windows)
        #expect(tool.tool == AgyLimitCheck.toolName && !tool.countsTokens && tool.source == .reportedByTool)
    }

    @Test func unusedWeeklyUsageThatResetsWithinADayIsFlagged() {
        func window(_ used: Double, minutes: Int = 10_080, in hours: Double) -> UsageWindow {
            UsageWindow(name: "w", usedPercent: used, windowMinutes: minutes, resetsAt: now.addingTimeInterval(hours * 3_600), observedAt: now)
        }
        #expect(window(25, in: 18).isExpiringUnused(now: now))
        #expect(window(25, in: 24).isExpiringUnused(now: now))
        #expect(!window(25, in: 30).isExpiringUnused(now: now))        // more than a day left
        #expect(!window(85, in: 18).isExpiringUnused(now: now))        // little left to use
        #expect(!window(10, minutes: 300, in: 2).isExpiringUnused(now: now)) // the 5-hour window resets all the time
        #expect(!window(10, in: -1).isExpiringUnused(now: now))        // already reset
        let codex = ToolUsage(tool: "Codex", source: .reportedByTool, windows: [window(10, minutes: 300, in: 2), window(25, in: 18)], note: "")
        #expect(codex.expiring(now: now).count == 1)
    }
}
