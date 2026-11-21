import ForgeDeckKit
import SwiftUI

extension AppModel {
    /// Reads usage off the main thread. Claude Code's limits are checked at most every 5 minutes, or now when
    /// `checkLimits` is set (the refresh button). Snapshot runs use fixed sample numbers instead of this Mac's logs.
    func refreshUsage(checkLimits: Bool = false) {
        guard !usageLoading else { return }
        if Runtime.isSnapshot {
            usage = AIUsageReader.sample(now: now)
            usageUpdatedAt = .now
            return
        }
        usageLoading = true
        let checkClaude = checkLimits || claudeLimitsCheckedAt.map { Date.now.timeIntervalSince($0) >= ClaudeLimitCheck.interval } ?? true
        let checkAgy = checkLimits || agyLimitsCheckedAt.map { Date.now.timeIntervalSince($0) >= AgyLimitCheck.interval } ?? true
        Task {
            if checkClaude { claudeLimitsCheckedAt = .now }
            if checkAgy { agyLimitsCheckedAt = .now }
            async let claude = checkClaude ? ClaudeLimitCheck.check() : nil
            async let agy = checkAgy ? AgyLimitCheck.check() : nil
            if let fresh = await claude { claudeLimits = fresh }
            if let fresh = await agy { agyLimits = fresh }
            let checked = claudeLimits, agyChecked = agyLimits
            let found = await Task.detached(priority: .utility) { AIUsageReader.all(claudeChecked: checked, agyChecked: agyChecked) }.value
            usage = found
            usageUpdatedAt = .now
            usageLoading = false
        }
    }

    func toggleUsagePanel() {
        usagePanelVisible.toggle()
        if !Runtime.isAutomated { UserDefaults.standard.set(usagePanelVisible, forKey: "usage.panel") }
        if usagePanelVisible { refreshUsage() }
    }
}

/// The right-hand sidebar: what each AI tool on this Mac has used, and what is left where the tool says.
struct UsagePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.sm) {
                Text("AI Usage").kitType(.section)
                Spacer()
                if model.usageLoading { ProgressView().controlSize(.small) }
                IconButton(.sync, label: "Check limits and read the logs again", kind: .toolbar) { model.refreshUsage(checkLimits: true) }
                IconButton(.xmark, label: "Hide (⌘⇧U)", kind: .toolbar) { model.toggleUsagePanel() }
            }
            .padding(.horizontal, Space.md).frame(height: 44)
            .hairlineBelow()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    if model.usage.isEmpty && !model.usageLoading {
                        EmptyState(icon: .chart, title: "No AI tools found", message: "Claude Code, Codex, and OpenCode keep usage logs on this Mac, and agy reports its limits. None were found.", compact: true)
                    }
                    ForEach(model.usage.flatMap { tool in tool.expiring(now: model.now).map { (tool.tool, $0) } }, id: \.1.id) { tool, window in
                        ExpiringUsageNote(tool: tool, window: window)
                    }
                    ForEach(model.usage) { tool in UsageCard(tool: tool) }
                    let quiet = AgentCatalog.installed().filter { spec in
                        spec.program == "gemini" || (spec.program == "agy" && !model.usageLoading && !model.usage.contains { $0.tool == AgyLimitCheck.toolName })
                    }.map(\.name)
                    if !quiet.isEmpty, !Runtime.isSnapshot {
                        Text("\(quiet.joined(separator: " and ")) \(quiet.count == 1 ? "is" : "are") installed but reported no usage on this Mac, so \(quiet.count == 1 ? "it is" : "they are") not shown.")
                            .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Read from the files these tools keep on this Mac: token counts and limits only, never message text. Claude's and agy's limits come from each tool checking your account, as /usage does. Updated every 5 minutes while open\(model.usageUpdatedAt.map { ", last \(RelativeTime.short($0, now: max(model.now, $0)))" } ?? "").")
                        .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.md)
            }
        }
        .frame(width: 300)
        .background(Ink.window)
        .overlay(alignment: .leading) { Ink.line.frame(width: Metric.hairline) }
        .task(id: model.usagePanelVisible) {
            guard model.usagePanelVisible else { return }
            model.refreshUsage()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                model.refreshUsage()
            }
        }
    }
}

struct UsageCard: View {
    @Environment(AppModel.self) private var model
    let tool: ToolUsage

    private var icon: KitIcon { tool.tool == "Codex" ? .code : tool.tool == "OpenCode" ? .terminal : tool.tool == AgyLimitCheck.toolName ? .bolt : .sparkle }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                ToneIcon(icon: icon, tone: .accent, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Space.xs) {
                        Text(tool.tool).kitType(.bodyStrong)
                        if let plan = tool.plan { Chip(plan) }
                    }
                    Text(tool.source == .reportedByTool ? "Limits reported by \(tool.tool)" : "Counted from local logs")
                        .kitType(.meta, tool.source == .reportedByTool ? Ink.ok : Ink.text3)
                }
                Spacer(minLength: 0)
                if let last = tool.lastActivity { Text(RelativeTime.compact(last, now: model.now)).kitType(.meta, Ink.text3).help("Last activity") }
            }
            ForEach(tool.windows) { window in WindowGauge(window: window) }
            if tool.windows.isEmpty, tool.tool == "Claude Code" {
                if let block = tool.block, let end = tool.blockEnd {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack {
                            Text("This 5-hour block").kitType(.labelMedium)
                            Spacer()
                            Text("ends \(RelativeTime.short(end, now: model.now))").kitType(.meta, Ink.text3)
                        }
                        if let largest = tool.largestBlock, largest > 0 {
                            let fraction = min(1, Double(block.fresh) / Double(largest))
                            Bar(fraction: fraction, tone: fraction > 0.85 ? .warn : .accent)
                            Text("\(TokenFormat.short(block.fresh)) tokens: \(Int(fraction * 100))% of your busiest block this week. A comparison, not your plan's limit.")
                                .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("\(TokenFormat.short(block.fresh)) tokens so far").kitType(.meta, Ink.text3)
                        }
                    }
                } else {
                    Text("No activity in the last five hours: a fresh window.").kitType(.label, Ink.text2)
                }
            }
            if tool.countsTokens { tokenRows }
            Text(tool.note).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.md)
        .card()
    }

    /// Today's tokens, the week's bars, and the top models. Left out for a tool that keeps no counts.
    @ViewBuilder private var tokenRows: some View {
            Divider().overlay(Ink.line2)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Today").kitType(.meta, Ink.text3)
                    Text(TokenFormat.short(tool.today.fresh)).kitType(.metricSmall).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    if let cost = tool.costToday {
                        Text(String(format: "$%.2f", cost)).kitType(.labelStrong).monospacedDigit()
                        Text(tool.cost7d.map { String(format: "$%.2f this week, est.", $0) } ?? "est.").kitType(.meta, Ink.text3)
                    } else {
                        Text("+ \(TokenFormat.short(tool.today.cacheRead))").kitType(.labelMedium, Ink.text2).monospacedDigit()
                        Text("cache reads").kitType(.meta, Ink.text3)
                    }
                }
            }
            DailyBars(values: tool.daily.map { $0 ?? 0 })
            HStack {
                Text("7 days ago").kitType(.meta, Ink.text3)
                Spacer()
                Text("today").kitType(.meta, Ink.text3)
            }
            ForEach(tool.byModel.prefix(3)) { model in
                HStack {
                    Text(model.model).kitType(.monoSmall, Ink.text2).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(TokenFormat.short(model.tokens.fresh)).kitType(.meta, Ink.text3).monospacedDigit()
                }
            }
    }
}

/// A weekly limit with a good share left that resets within a day: worth using before it is gone.
struct ExpiringUsageNote: View {
    @Environment(AppModel.self) private var model
    let tool: String
    let window: UsageWindow

    var body: some View {
        let left = Int(window.remainingPercent(now: model.now) ?? 0)
        HStack(alignment: .top, spacing: Space.sm) {
            ToneIcon(icon: .clock, tone: .ok, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(left)% of \(tool) left, resets \(RelativeTime.short(window.resetsAt, now: model.now))").kitType(.labelMedium)
                Text("\(window.name) is paid for and unused. Use it before it resets.")
                    .kitType(.meta, Ink.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(Ink.ok.soft(0.10), in: RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous).strokeBorder(Ink.ok.soft(0.35), lineWidth: Metric.hairline))
        .accessibilityElement(children: .combine)
    }
}

struct WindowGauge: View {
    @Environment(AppModel.self) private var model
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.name).kitType(.labelMedium)
                Spacer()
                if window.hasReset(now: model.now) {
                    Text("reset \(RelativeTime.short(window.resetsAt, now: model.now))").kitType(.meta, Ink.ok)
                } else {
                    if window.isExpiringUnused(now: model.now) { TagBadge("Use it", tone: .ok).help("Resets within a day with \(Int(100 - window.usedPercent))% unused") }
                    Text("\(Int(100 - window.usedPercent))% left").kitType(.labelStrong, window.usedPercent >= 90 ? Ink.err : window.usedPercent >= 70 ? Ink.warn : Ink.ok).monospacedDigit()
                }
            }
            if window.hasReset(now: model.now) {
                Bar(fraction: 0, tone: .ok)
                Text("Was \(Int(window.usedPercent))% used when last seen \(RelativeTime.short(window.observedAt, now: model.now)). Nothing used since.")
                    .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
            } else {
                Bar(fraction: window.usedPercent / 100, tone: window.usedPercent >= 90 ? .err : window.usedPercent >= 70 ? .warn : .accent)
                Text("\(Int(window.usedPercent))% used · resets \(RelativeTime.short(window.resetsAt, now: model.now)) · as of \(RelativeTime.short(window.observedAt, now: model.now))")
                    .kitType(.meta, Ink.text3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Seven small bars, oldest first. Hover shows the number.
struct DailyBars: View {
    let values: [Int]

    var body: some View {
        let top = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: Space.xs) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index == values.count - 1 ? Ink.accent : Ink.accent.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .frame(height: value == 0 ? 2 : max(3, 28 * CGFloat(value) / CGFloat(top)))
                    .help(value == 0 ? "No use" : "\(TokenFormat.short(value)) tokens")
            }
        }
        .frame(height: 28, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tokens per day for the last seven days: " + values.map(TokenFormat.short).joined(separator: ", "))
    }
}

struct Bar: View {
    let fraction: Double
    var tone: Tone = .accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.chip)
                Capsule().fill(Ink.tone(tone)).frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
