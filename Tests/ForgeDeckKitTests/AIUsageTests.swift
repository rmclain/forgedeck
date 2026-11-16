import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct AIUsageTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-15T15:30:00Z")!
    var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    func claudeLine(_ time: String, id: String, request: String, input: Int, output: Int, cacheRead: Int = 0, text: String = "hello") -> String {
        #"{"parentUuid":"x","message":{"id":"\#(id)","model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"server_tool_use":{"web_search_requests":0}}},"requestId":"\#(request)","type":"assistant","timestamp":"\#(time)"}"#
    }

    @Test func claudeCodeTokensAreCountedOnceAndNoTextIsKept() throws {
        let root = try makeTempDir("claude projects")
        defer { removeTemp(root) }
        let project = root.appending(path: "-Users-me-code")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let lines = [
            claudeLine("2026-11-15T13:10:00.000Z", id: "msg_1", request: "req_1", input: 100, output: 50, cacheRead: 1_000, text: "SECRET-CONVERSATION-MARKER"),
            claudeLine("2026-11-15T13:10:00.000Z", id: "msg_1", request: "req_1", input: 100, output: 50, cacheRead: 1_000),
            claudeLine("2026-11-15T14:00:00.000Z", id: "msg_2", request: "req_2", input: 200, output: 100),
            claudeLine("2026-11-14T09:00:00.000Z", id: "msg_3", request: "req_3", input: 5_000, output: 1_000),
            #"{"type":"user","message":{"role":"user","content":"\"usage\":{\"input_tokens\":999999}"},"timestamp":"2026-11-15T13:00:00.000Z"}"#,
        ]
        try write(lines.joined(separator: "\n") + "\n", to: project.appending(path: "session.jsonl"))
        let usage = try #require(AIUsageReader.claudeCode(projects: root, now: now, calendar: utc))
        #expect(usage.today == TokenCounts(input: 300, output: 150, cacheWrite: 0, cacheRead: 1_000))
        #expect(usage.windows.isEmpty)
        #expect(usage.block?.fresh == 450)
        #expect(usage.blockStart == ISO8601DateFormatter().date(from: "2026-11-15T13:00:00Z"))
        #expect(usage.blockEnd == ISO8601DateFormatter().date(from: "2026-11-15T18:00:00Z"))
        #expect(usage.largestBlock == 6_000)
        #expect(usage.daily.suffix(2) == [6_000, 450])
        #expect(usage.daily.count == 7 && usage.daily.first == 0)
        #expect(usage.byModel.map(\.model) == ["claude-opus-5-5"])
        #expect(!String(describing: usage).contains("SECRET-CONVERSATION-MARKER"))
    }

    @Test func noRecentClaudeActivityMeansAFreshWindow() throws {
        let root = try makeTempDir("claude projects")
        defer { removeTemp(root) }
        let project = root.appending(path: "p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try write(claudeLine("2026-11-15T05:00:00.000Z", id: "m", request: "r", input: 10, output: 10), to: project.appending(path: "s.jsonl"))
        let usage = try #require(AIUsageReader.claudeCode(projects: root, now: now, calendar: utc))
        #expect(usage.block == nil)
        #expect(usage.today.fresh == 20)
    }

    func codexLine(_ time: String, used5h: Double, resets5h: Date, usedWeek: Double, resetsWeek: Date, input: Int) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(input / 2),"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":\#(input + 15)}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(used5h),"window_minutes":300,"resets_at":\#(Int(resets5h.timeIntervalSince1970))},"secondary":{"used_percent":\#(usedWeek),"window_minutes":10080,"resets_at":\#(Int(resetsWeek.timeIntervalSince1970))},"plan_type":"plus"}}}"#
    }

    @Test func codexLimitsAreTheNewestReportAndAPassedResetShowsAsReset() throws {
        let root = try makeTempDir("codex sessions")
        defer { removeTemp(root) }
        let folder = root.appending(path: "2026/11/15")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-11-15T14:00:00.000Z","type":"turn_context","payload":{"model":"gpt-6"}}"#,
            codexLine("2026-11-15T14:00:00.000Z", used5h: 40, resets5h: now.addingTimeInterval(3_600), usedWeek: 20, resetsWeek: now.addingTimeInterval(86_400), input: 1_000),
            codexLine("2026-11-15T15:00:00.000Z", used5h: 61, resets5h: now.addingTimeInterval(1_800), usedWeek: 22, resetsWeek: now.addingTimeInterval(-60), input: 2_000),
        ]
        try write(lines.joined(separator: "\n") + "\n", to: folder.appending(path: "rollout.jsonl"))
        let usage = try #require(AIUsageReader.codex(sessions: root, now: now, calendar: utc))
        #expect(usage.source == .reportedByTool)
        #expect(usage.plan == "Plus")
        let fiveHour = try #require(usage.windows.first { $0.windowMinutes == 300 })
        #expect(fiveHour.usedPercent == 61)
        #expect(fiveHour.remainingPercent(now: now) == 39)
        let weekly = try #require(usage.windows.first { $0.windowMinutes == 10_080 })
        #expect(weekly.hasReset(now: now))
        #expect(weekly.remainingPercent(now: now) == nil)
        #expect(usage.today.cacheRead == 1_500)
        #expect(usage.today.output == 30)
        #expect(usage.byModel.first?.model == "gpt-6")
    }

    @Test func openCodeIsReadFromItsDatabaseWithoutTouchingText() throws {
        let root = try makeTempDir("opencode")
        defer { removeTemp(root) }
        let db = root.appending(path: "opencode.db").path
        let stamp = Int64(now.addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        let old = Int64(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970 * 1000)
        let sql = """
        CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
        CREATE TABLE part (id TEXT, data TEXT);
        INSERT INTO part VALUES ('p', '{"text":"SECRET-OPENCODE-MARKER"}');
        INSERT INTO message VALUES ('a','s',\(stamp),\(stamp),'{"role":"assistant","modelID":"claude-opus-5-5","cost":0.17,"tokens":{"input":2,"output":97,"reasoning":3,"cache":{"write":388,"read":832072}}}');
        INSERT INTO message VALUES ('b','s',\(stamp),\(stamp),'{"role":"user"}');
        INSERT INTO message VALUES ('c','s',\(old),\(old),'{"role":"assistant","modelID":"x","cost":9.0,"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"write":0,"read":0}}}');
        """
        _ = try runTool("/usr/bin/sqlite3", [db, sql])
        let usage = try #require(AIUsageReader.openCode(database: URL(fileURLWithPath: db), now: now, calendar: utc))
        #expect(usage.today == TokenCounts(input: 2, output: 100, cacheWrite: 388, cacheRead: 832_072))
        #expect(abs((usage.costToday ?? 0) - 0.17) < 0.0001)
        #expect(abs((usage.cost7d ?? 0) - 0.17) < 0.0001)
        #expect(!String(describing: usage).contains("SECRET-OPENCODE-MARKER"))
        #expect(AIUsageReader.openCode(database: root.appending(path: "missing.db"), now: now) == nil)
    }

    @Test func blocksStartOnTheHourAndLastFiveHours() {
        let base = ISO8601DateFormatter().date(from: "2026-11-15T08:20:00Z")!
        let blocks = AIUsageReader.blocks([(base, TokenCounts(input: 1, output: 0)),
                                           (base.addingTimeInterval(4 * 3_600), TokenCounts(input: 2, output: 0)),
                                           (base.addingTimeInterval(5 * 3_600), TokenCounts(input: 4, output: 0))])
        #expect(blocks.count == 2)
        #expect(blocks[0].start == ISO8601DateFormatter().date(from: "2026-11-15T08:00:00Z"))
        #expect(blocks[0].tokens.input == 3)
        #expect(blocks[1].tokens.input == 4)
    }

    @Test func tokenCountsReadShort() {
        #expect(TokenFormat.short(950) == "950")
        #expect(TokenFormat.short(1_500) == "1.5k")
        #expect(TokenFormat.short(52_000) == "52k")
        #expect(TokenFormat.short(2_400_000) == "2.4M")
    }
}
