import Foundation

// Alert rules. Each rule has one open incident per subject at most, so a condition
// that stays true does not raise a second alert, and a recovery is reported once.

public enum AlertEngine {
    public static let consecutiveFailures = 3

    /// Opens an incident, or does nothing when one is already open for the rule and subject.
    @discardableResult
    static func open(_ rule: AlertRuleKind, subject: String, product: Product, title: String, detail: String,
                     at: Date, cache: inout ObservationCache) -> Bool {
        guard !cache.incidents.contains(where: { $0.rule == rule && $0.subject == subject && $0.isOpen }) else { return false }
        var incident = Incident()
        incident.rule = rule
        incident.subject = subject
        incident.productID = product.id
        incident.title = title
        incident.detail = detail
        incident.openedAt = at
        incident.isDemo = product.isDemo
        cache.incidents.append(incident)
        cache.record(ActivityEvent(id: "alert:\(incident.id.uuidString)", kind: .alert, productID: product.id, title: title,
                                   detail: detail, at: at, sourceLabel: rule.title, isDemo: product.isDemo))
        return true
    }

    @discardableResult
    static func resolve(_ rule: AlertRuleKind, subject: String, product: Product, title: String, detail: String = "",
                        at: Date, cache: inout ObservationCache) -> Bool {
        guard let index = cache.incidents.firstIndex(where: { $0.rule == rule && $0.subject == subject && $0.isOpen }) else { return false }
        cache.incidents[index].resolvedAt = at
        cache.record(ActivityEvent(id: "recovery:\(cache.incidents[index].id.uuidString)", kind: .recovery, productID: product.id,
                                   title: title, detail: detail, at: at, sourceLabel: rule.title, isDemo: product.isDemo))
        return true
    }

    /// Call after a health sample was recorded for a probe.
    public static func evaluateHealth(probe: ProbeConfig, environment: ProductEnvironment, product: Product, cache: inout ObservationCache) {
        let samples = cache.health[probe.id] ?? []
        guard let last = samples.last else { return }
        let subject = probe.id.uuidString
        let name = probe.name.isEmpty ? environment.name : probe.name
        if last.ok {
            resolve(.healthFailing, subject: subject, product: product, title: "\(name) recovered",
                    detail: "\(environment.name) answers again.", at: last.at, cache: &cache)
        } else {
            let recent = samples.suffix(consecutiveFailures)
            // An offline Mac says nothing about the server.
            guard recent.count == consecutiveFailures, recent.allSatisfy({ !$0.ok && $0.problem != .offline }) else { return }
            let reason = last.problem?.title ?? "HTTP \(last.statusCode.map(String.init) ?? "error")"
            open(.healthFailing, subject: subject, product: product, title: "\(name) is failing",
                 detail: "\(consecutiveFailures) checks in a row failed on \(environment.name): \(reason).", at: last.at, cache: &cache)
        }
    }

    /// The rules that look at the whole cache. Safe to call after every refresh.
    public static func evaluate(portfolio: Portfolio, cache: inout ObservationCache, now: Date = .now) {
        for product in portfolio.products where !product.isArchived && !product.isDemo {
            for repo in product.repositories {
                guard let remote = cache.remotes[repo.id] else { continue }
                let subject = repo.id.uuidString
                if let run = remote.defaultBranchRun {
                    if run.failed {
                        open(.pipelineBroken, subject: subject, product: product, title: "\(run.name.isEmpty ? "CI" : run.name) is failing on \(remote.defaultBranch)",
                             detail: "\(repo.fullName) at \(shortSHA(run.headSHA)).", at: run.createdAt, cache: &cache)
                    } else if run.succeeded {
                        resolve(.pipelineBroken, subject: subject, product: product, title: "CI passes again on \(remote.defaultBranch)",
                                detail: repo.fullName, at: run.createdAt, cache: &cache)
                    }
                }
                if remote.problem == .unauthorized {
                    open(.authFailure, subject: subject, product: product, title: "GitHub rejected the token",
                         detail: "Reconnect GitHub in Connections.", at: remote.provenance.observedAt, cache: &cache)
                } else if remote.problem == nil {
                    resolve(.authFailure, subject: subject, product: product, title: "GitHub is connected again", at: now, cache: &cache)
                }
            }
            for environment in product.environments {
                let records = cache.deployments.filter { $0.environmentID == environment.id && $0.provenance.source == .deploymentRecord }
                if let newest = records.max(by: { $0.provenance.observedAt < $1.provenance.observedAt }) {
                    let subject = environment.id.uuidString
                    if ["failure", "error"].contains(newest.deployState ?? "") {
                        open(.deployFailed, subject: subject, product: product, title: "Deploy to \(environment.name) failed",
                             detail: "The deployment record for \(shortSHA(newest.sha)) reports \(newest.deployState ?? "failure"). The running version did not change.",
                             at: newest.provenance.observedAt, cache: &cache)
                    } else if newest.deployState == "success" {
                        resolve(.deployFailed, subject: subject, product: product, title: "Deploy to \(environment.name) succeeded", at: newest.provenance.observedAt, cache: &cache)
                    }
                }
                for source in environment.metricSources {
                    let key = "metrics:\(source.id.uuidString)"
                    guard let state = cache.sync[key], let attempt = state.lastAttempt else { continue }
                    let stalled = state.lastProblem != nil && state.lastProblem != .offline
                        && (state.lastSuccess.map { attempt.timeIntervalSince($0) > 3_600 } ?? false)
                    if stalled {
                        open(.leadIngestStalled, subject: source.id.uuidString, product: product, title: "\(source.name) stopped reporting",
                             detail: "Last good answer \(state.lastSuccess.map { RelativeTime.short($0, now: now) } ?? "never"). Numbers shown are stale.", at: attempt, cache: &cache)
                    } else if state.lastProblem == nil {
                        resolve(.leadIngestStalled, subject: source.id.uuidString, product: product, title: "\(source.name) reports again", at: attempt, cache: &cache)
                    }
                }
            }
            // Verified staging ahead of verified production.
            if product.environment(tier: .production) != nil, product.environment(tier: .staging) != nil {
                let relation = DriftAnalyzer.relations(product: product, cache: cache, now: now).first { $0.from == .staging }
                let subject = product.id.uuidString
                if case .ahead(let n)? = relation?.comparison {
                    open(.productionDrift, subject: subject, product: product, title: "Production is \(n) commit\(n == 1 ? "" : "s") behind staging",
                         detail: relation?.sentence ?? "", at: now, cache: &cache)
                } else if case .same? = relation?.comparison {
                    resolve(.productionDrift, subject: subject, product: product, title: "Production matches staging", at: now, cache: &cache)
                }
            }
        }
        for variable in portfolio.variables {
            guard let credential = variable.credential, let productID = variable.scope.productID,
                  let product = portfolio.product(id: productID), !product.isDemo else { continue }
            let subject = variable.id.uuidString
            let due = credential.rotationDue(now: now)
            let expiring = credential.expiresAt.map { $0.timeIntervalSince(now) < 7 * 86_400 } ?? false
            if expiring || (due.map { $0 <= now } ?? false) {
                open(.secretExpiring, subject: subject, product: product, title: "\(variable.key) needs rotation",
                     detail: expiring ? "The credential expires \(credential.expiresAt.map { RelativeTime.short($0, now: now) } ?? "soon")." : "The rotation reminder is due.",
                     at: now, cache: &cache)
            } else {
                resolve(.secretExpiring, subject: subject, product: product, title: "\(variable.key) was rotated", at: now, cache: &cache)
            }
        }
    }

    public static func acknowledge(_ id: UUID, cache: inout ObservationCache, now: Date = .now) {
        if let index = cache.incidents.firstIndex(where: { $0.id == id }) { cache.incidents[index].acknowledgedAt = now }
    }

    public static func snooze(_ id: UUID, for interval: TimeInterval, cache: inout ObservationCache, now: Date = .now) {
        if let index = cache.incidents.firstIndex(where: { $0.id == id }) { cache.incidents[index].snoozedUntil = now.addingTimeInterval(interval) }
    }
}

public enum RelativeTime {
    public static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 {
            let ahead = -seconds
            if ahead < 3_600 { return "in \(max(1, Int(ahead / 60)))m" }
            if ahead < 86_400 { return "in \(Int(ahead / 3_600))h" }
            return "in \(Int(ahead / 86_400))d"
        }
        if seconds < 45 { return "now" }
        if seconds < 3_600 { return "\(max(1, Int((seconds / 60).rounded())))m ago" }
        if seconds < 86_400 { return "\(Int((seconds / 3_600).rounded()))h ago" }
        if seconds < 86_400 * 14 { return "\(Int((seconds / 86_400).rounded()))d ago" }
        return "\(Int((seconds / (86_400 * 7)).rounded()))w ago"
    }

    /// "5m", "2h": for tight columns.
    public static func compact(_ date: Date, now: Date = .now) -> String {
        let text = short(date, now: now)
        return text.hasSuffix(" ago") ? String(text.dropLast(4)) : text
    }
}
