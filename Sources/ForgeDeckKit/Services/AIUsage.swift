import Foundation
import SQLite3

// AI tool usage from the files those tools keep on this Mac. Only numbers are read: token
// counts, rate-limit percentages, and costs. Message text is never read or kept, and nothing
// is sent anywhere. Not real time: it reflects the tools' own logs, refreshed every few minutes.

public struct TokenCounts: Sendable, Equatable, Codable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0
    public init() {}
    public init(input: Int, output: Int, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheWrite + cacheRead }
    /// Input and output, without cache reads: closer to the work done.
    public var fresh: Int { input + output + cacheWrite }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
}

/// A plan limit as the tool reported it.
public struct UsageWindow: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date
    /// When the tool last reported this number.
    public var observedAt: Date

    /// Once the reset time has passed, the reported number is history, not the current state.
    public func hasReset(now: Date = .now) -> Bool { resetsAt <= now }
    public func remainingPercent(now: Date = .now) -> Double? { hasReset(now: now) ? nil : max(0, 100 - usedPercent) }
}

public struct ModelTokens: Sendable, Equatable, Identifiable {
    public var id: String { model }
    public var model: String
    public var tokens: TokenCounts
    public var cost: Double?
}

public struct ToolUsage: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable { case reportedByTool, countedFromLogs }
    public var id: String { tool }
    public var tool: String
    public var source: Source
    public var plan: String?
    public var windows: [UsageWindow] = []
    public var today = TokenCounts()
    public var costToday: Double?
    public var cost7d: Double?
    /// The current 5-hour activity block, counted from the logs. Plans reset on rolling windows like this one.
    public var block: TokenCounts?
    public var blockStart: Date?
    public var blockEnd: Date?
    /// The largest earlier block, to put the current one in proportion.
    public var largestBlock: Int?
    /// Seven days, oldest first. nil for a day with no use.
    public var daily: [Int?] = []
    public var byModel: [ModelTokens] = []
    public var lastActivity: Date?
    public var note: String
}

public enum AIUsageReader {
    public static let blockHours = 5.0

    static func day(_ date: Date, calendar: Calendar) -> Date { calendar.startOfDay(for: date) }

    static func dailySeries(_ perDay: [Date: Int], now: Date, calendar: Calendar) -> [Int?] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            // The logs cover the whole week, so a day without use is a real zero.
            return perDay[date] ?? 0
        }
    }

    /// Splits activity into 5-hour blocks the way rolling plan windows work: a block starts at the
    /// hour of its first message and lasts five hours; a message after that starts a new block.
    static func blocks(_ events: [(Date, TokenCounts)]) -> [(start: Date, end: Date, tokens: TokenCounts)] {
        var blocks: [(start: Date, end: Date, tokens: TokenCounts)] = []
        let calendar = Calendar(identifier: .gregorian)
        for (date, tokens) in events.sorted(by: { $0.0 < $1.0 }) {
            if let last = blocks.last, date < last.end {
                blocks[blocks.count - 1].tokens = last.tokens + tokens
            } else {
                let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
                blocks.append((hour, hour.addingTimeInterval(blockHours * 3_600), tokens))
            }
        }
        return blocks
    }

    // MARK: Fast field extraction

    /// Parsed events per file, reused while a file's size and date are unchanged.
    final class FileCache: @unchecked Sendable {
        struct Entry { var size: Int; var modified: Date; var events: [(key: String, date: Date, model: String, tokens: TokenCounts)] }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        func get(_ path: String, size: Int, modified: Date) -> Entry? {
            lock.withLock { entries[path].flatMap { $0.size == size && $0.modified == modified ? $0 : nil } }
        }
        func set(_ path: String, _ entry: Entry) { lock.withLock { entries[path] = entry } }
    }

    static let claudeCache = FileCache()

    /// Scans a Claude Code log as bytes. Lines are found with memchr and fields with memmem, so the
    /// large message text is never decoded. Returns one event per assistant response with usage.
    static func scanClaudeLog(_ data: Data) -> [(key: String, date: Date, model: String, tokens: TokenCounts)] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var out: [(key: String, date: Date, model: String, tokens: TokenCounts)] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            func find(_ needle: String, from: Int, to: Int) -> Int? {
                needle.utf8CString.withUnsafeBufferPointer { pattern -> Int? in
                    let length = pattern.count - 1
                    guard to - from >= length, let hit = memmem(base + from, to - from, pattern.baseAddress, length) else { return nil }
                    return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                }
            }
            func string(after key: String, from: Int, to: Int) -> String? {
                guard let at = find("\"\(key)\":\"", from: from, to: to) else { return nil }
                let begin = at + key.utf8.count + 4
                guard let quote = memchr(base + begin, 0x22, to - begin) else { return nil }
                let end = base.distance(to: quote.assumingMemoryBound(to: UInt8.self))
                return String(decoding: UnsafeBufferPointer(start: base + begin, count: end - begin), as: UTF8.self)
            }
            var start = 0
            while start < count {
                let end = memchr(base + start, 0x0A, count - start).map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? count
                defer { start = end + 1 }
                guard find("\"type\":\"assistant\"", from: start, to: end) != nil,
                      let usageAt = find("\"usage\":{", from: start, to: end) else { continue }
                // Match braces to cut out the usage object alone.
                var index = usageAt + 8, depth = 0, inString = false, escaped = false, close = -1
                while index < end {
                    let byte = base[index]
                    if inString {
                        if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                    } else if byte == 0x22 { inString = true }
                    else if byte == 0x7B { depth += 1 }
                    else if byte == 0x7D { depth -= 1; if depth == 0 { close = index; break } }
                    index += 1
                }
                guard close > 0,
                      let usage = try? JSONSerialization.jsonObject(with: Data(bytes: base + usageAt + 8, count: close - usageAt - 7)) as? [String: Any],
                      let stamp = string(after: "timestamp", from: start, to: end), let date = iso.date(from: stamp) ?? plain.date(from: stamp) else { continue }
                let tokens = TokenCounts(input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
                                         cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0, cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0)
                guard tokens.total > 0 else { continue }
                let messageAt = find("\"message\":", from: start, to: end) ?? start
                let key = "\(string(after: "id", from: messageAt, to: end) ?? "")|\(string(after: "requestId", from: start, to: end) ?? "")"
                out.append((key, date, string(after: "model", from: messageAt, to: end) ?? "unknown", tokens))
            }
        }
        return out
    }

    // MARK: Claude Code

    /// Counts tokens from Claude Code's session logs (~/.claude/projects/*/*.jsonl) modified in the last
    /// eight days. Each response is counted once, by message id and request id.
    public static func claudeCode(projects: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/projects"),
                                  now: Date = .now, calendar: Calendar = .current) -> ToolUsage? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        let cutoff = now.addingTimeInterval(-8 * 86_400)
        var files: [URL] = []
        for folder in folders {
            let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            files += entries.filter { url in
                url.pathExtension == "jsonl"
                    && ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { $0 > cutoff } ?? false)
            }
        }
        var seen = Set<String>()
        var events: [(Date, TokenCounts)] = []
        var models: [String: TokenCounts] = [:]
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate ?? .distantPast
            var parsed: [(key: String, date: Date, model: String, tokens: TokenCounts)]
            if let cached = claudeCache.get(file.path, size: size, modified: modified) {
                parsed = cached.events
            } else {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                parsed = scanClaudeLog(data)
                claudeCache.set(file.path, FileCache.Entry(size: size, modified: modified, events: parsed))
            }
            for event in parsed where event.date > cutoff {
                guard event.key == "|" || seen.insert(event.key).inserted else { continue }
                events.append((event.date, event.tokens))
                if calendar.isDate(event.date, inSameDayAs: now) {
                    models[event.model, default: TokenCounts()] = models[event.model, default: TokenCounts()] + event.tokens
                }
            }
        }
        guard !events.isEmpty else {
            return ToolUsage(tool: "Claude Code", source: .countedFromLogs, note: "No Claude Code activity in the last week.")
        }
        var perDay: [Date: Int] = [:]
        var today = TokenCounts()
        for (date, tokens) in events {
            perDay[day(date, calendar: calendar), default: 0] += tokens.fresh
            if calendar.isDate(date, inSameDayAs: now) { today = today + tokens }
        }
        let allBlocks = blocks(events)
        let current = allBlocks.last.flatMap { $0.end > now ? $0 : nil }
        let largest = allBlocks.dropLast(current == nil ? 0 : 1).map(\.tokens.fresh).max()
        return ToolUsage(tool: "Claude Code", source: .countedFromLogs, today: today, block: current?.tokens,
                         blockStart: current?.start, blockEnd: current?.end, largestBlock: largest,
                         daily: dailySeries(perDay, now: now, calendar: calendar),
                         byModel: models.map { ModelTokens(model: $0.key, tokens: $0.value, cost: nil) }.sorted { $0.tokens.total > $1.tokens.total },
                         lastActivity: events.map(\.0).max(),
                         note: "Claude Code does not record its plan limits on this Mac, so what is left cannot be shown. Tokens are counted from its logs; cache reads are cheap and shown apart.")
    }

    // MARK: Codex

    /// Reads Codex's own rate-limit report (the newest `token_count` event in ~/.codex/sessions) and
    /// counts tokens from its sessions in the last eight days.
    public static func codex(sessions: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".codex/sessions"),
                             now: Date = .now, calendar: Calendar = .current) -> ToolUsage? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let cutoff = now.addingTimeInterval(-8 * 86_400)
        var files: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { files.append((url, date)) }
        }
        guard !files.isEmpty else { return nil }
        files.sort { $0.1 > $1.1 }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var latestLimits: (Date, [String: Any])?
        var events: [(Date, TokenCounts)] = []
        var models: [String: TokenCounts] = [:]
        for (index, (file, modified)) in files.enumerated() where index == 0 || modified > cutoff {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var model = "codex"
            for line in text.split(separator: "\n") {
                if line.contains("\"turn_context\""), let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let payload = record["payload"] as? [String: Any], let name = payload["model"] as? String {
                    model = name
                }
                guard line.contains("\"token_count\""),
                      let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = record["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                      let stamp = record["timestamp"] as? String, let date = iso.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { continue }
                if let limits = payload["rate_limits"] as? [String: Any], latestLimits.map({ date > $0.0 }) ?? true { latestLimits = (date, limits) }
                if date > cutoff, let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] {
                    let cached = last["cached_input_tokens"] as? Int ?? 0
                    let tokens = TokenCounts(input: max(0, (last["input_tokens"] as? Int ?? 0) - cached),
                                             output: (last["output_tokens"] as? Int ?? 0) + (last["reasoning_output_tokens"] as? Int ?? 0),
                                             cacheWrite: last["cache_write_input_tokens"] as? Int ?? 0, cacheRead: cached)
                    events.append((date, tokens))
                    if calendar.isDate(date, inSameDayAs: now) { models[model, default: TokenCounts()] = models[model, default: TokenCounts()] + tokens }
                }
            }
        }
        var windows: [UsageWindow] = []
        var plan: String?
        if let (observed, limits) = latestLimits {
            plan = (limits["plan_type"] as? String).map { $0.capitalized }
            for (key, fallback) in [("primary", "5-hour window"), ("secondary", "Weekly window")] {
                guard let window = limits[key] as? [String: Any], let used = window["used_percent"] as? Double,
                      let minutes = window["window_minutes"] as? Int else { continue }
                let reset = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    ?? (window["resets_in_seconds"] as? Double).map { observed.addingTimeInterval($0) } ?? observed
                let name = minutes == 300 ? "5-hour window" : minutes == 10_080 ? "Weekly window" : fallback
                windows.append(UsageWindow(name: name, usedPercent: used, windowMinutes: minutes, resetsAt: reset, observedAt: observed))
            }
        }
        var perDay: [Date: Int] = [:]
        var today = TokenCounts()
        for (date, tokens) in events {
            perDay[day(date, calendar: calendar), default: 0] += tokens.fresh
            if calendar.isDate(date, inSameDayAs: now) { today = today + tokens }
        }
        return ToolUsage(tool: "Codex", source: windows.isEmpty ? .countedFromLogs : .reportedByTool, plan: plan, windows: windows, today: today,
                         daily: dailySeries(perDay, now: now, calendar: calendar),
                         byModel: models.map { ModelTokens(model: $0.key, tokens: $0.value, cost: nil) }.sorted { $0.tokens.total > $1.tokens.total },
                         lastActivity: latestLimits?.0 ?? events.map(\.0).max(),
                         note: "Limits are what Codex reported after its last request. A window whose reset time has passed starts again at zero.")
    }

    // MARK: OpenCode

    /// Reads token counts and OpenCode's own cost figures from its database, read-only.
    public static func openCode(database: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/share/opencode/opencode.db"),
                                now: Date = .now, calendar: Calendar = .current) -> ToolUsage? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let since = Int64(now.addingTimeInterval(-8 * 86_400).timeIntervalSince1970 * 1000)
        // Only numeric fields leave SQLite. Message parts (the text) are not touched.
        let sql = """
        SELECT time_created, json_extract(data,'$.modelID'), json_extract(data,'$.cost'),
               json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'), json_extract(data,'$.tokens.reasoning'),
               json_extract(data,'$.tokens.cache.write'), json_extract(data,'$.tokens.cache.read')
        FROM message WHERE time_created >= ? AND json_extract(data,'$.role') = 'assistant'
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, since)
        var perDay: [Date: Int] = [:]
        var today = TokenCounts()
        var costToday = 0.0, cost7d = 0.0
        var models: [String: (TokenCounts, Double)] = [:]
        var last: Date?
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        while sqlite3_step(statement) == SQLITE_ROW {
            let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1000)
            let model = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "unknown"
            let cost = sqlite3_column_double(statement, 2)
            let tokens = TokenCounts(input: Int(sqlite3_column_int64(statement, 3)),
                                     output: Int(sqlite3_column_int64(statement, 4)) + Int(sqlite3_column_int64(statement, 5)),
                                     cacheWrite: Int(sqlite3_column_int64(statement, 6)), cacheRead: Int(sqlite3_column_int64(statement, 7)))
            last = max(last ?? date, date)
            perDay[day(date, calendar: calendar), default: 0] += tokens.fresh
            if date > weekAgo { cost7d += cost }
            if calendar.isDate(date, inSameDayAs: now) {
                today = today + tokens
                costToday += cost
                let entry = models[model] ?? (TokenCounts(), 0)
                models[model] = (entry.0 + tokens, entry.1 + cost)
            }
        }
        return ToolUsage(tool: "OpenCode", source: .countedFromLogs, today: today, costToday: costToday, cost7d: cost7d,
                         daily: dailySeries(perDay, now: now, calendar: calendar),
                         byModel: models.map { ModelTokens(model: $0.key, tokens: $0.value.0, cost: $0.value.1) }.sorted { $0.tokens.total > $1.tokens.total },
                         lastActivity: last,
                         note: "Costs are OpenCode's own estimates at API prices. With a subscription login the provider may not bill them.")
    }

    /// Fixed sample numbers for screenshots and the design gallery. Never shown as real data.
    public static func sample(now: Date = .now) -> [ToolUsage] {
        let hour = Calendar(identifier: .gregorian).dateInterval(of: .hour, for: now.addingTimeInterval(-7_200))?.start ?? now
        return [
            ToolUsage(tool: "Claude Code", source: .countedFromLogs, today: TokenCounts(input: 210_000, output: 380_000, cacheWrite: 1_800_000, cacheRead: 96_000_000),
                      block: TokenCounts(input: 90_000, output: 160_000, cacheWrite: 820_000, cacheRead: 41_000_000), blockStart: hour,
                      blockEnd: hour.addingTimeInterval(5 * 3_600), largestBlock: 1_900_000, daily: [1_700_000, 3_400_000, nil, 2_500_000, 1_900_000, 1_500_000, 2_400_000],
                      byModel: [ModelTokens(model: "claude-opus-5-5", tokens: TokenCounts(input: 120_000, output: 220_000, cacheWrite: 1_000_000), cost: nil),
                                ModelTokens(model: "claude-sonnet-5-5", tokens: TokenCounts(input: 90_000, output: 160_000, cacheWrite: 800_000), cost: nil)],
                      lastActivity: now.addingTimeInterval(-120),
                      note: "Claude Code does not record its plan limits on this Mac, so what is left cannot be shown."),
            ToolUsage(tool: "Codex", source: .reportedByTool, plan: "Plus",
                      windows: [UsageWindow(name: "5-hour window", usedPercent: 62, windowMinutes: 300, resetsAt: now.addingTimeInterval(5_400), observedAt: now.addingTimeInterval(-900)),
                                UsageWindow(name: "Weekly window", usedPercent: 25, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400), observedAt: now.addingTimeInterval(-900))],
                      today: TokenCounts(input: 40_000, output: 12_000, cacheRead: 300_000), daily: [nil, 133_000, nil, nil, 80_000, nil, 52_000],
                      lastActivity: now.addingTimeInterval(-900), note: "Limits are what Codex reported after its last request."),
        ]
    }

    /// Every tool found on this Mac.
    public static func all(now: Date = .now) -> [ToolUsage] {
        [claudeCode(now: now), codex(now: now), openCode(now: now)].compactMap { $0 }
    }
}

public enum TokenFormat {
    public static func short(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...: String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: String(format: "%.0fk", Double(value) / 1_000)
        case 1_000...: String(format: "%.1fk", Double(value) / 1_000)
        default: "\(value)"
        }
    }
}
