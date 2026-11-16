import Foundation

// The source-of-truth model: LOCAL -> GITHUB -> STAGING -> PRODUCTION.
// Each stage shows what was observed, by whom, when, and how strong the evidence is.
// Production is never inferred from `main`, a green CI run, or the newest release.

public enum Tone: String, Sendable, Codable { case ok, warn, err, accent, muted, prod }

public struct StatusBadge: Sendable, Hashable {
    public var label: String
    public var tone: Tone
    public init(_ label: String, _ tone: Tone) { self.label = label; self.tone = tone }
}

public struct ChainNode: Sendable, Hashable, Identifiable {
    public enum Stage: String, Sendable, CaseIterable { case local, github, staging, production }
    public var id: String { stage.rawValue }
    public var stage: Stage
    public var title: String
    public var sha: String?
    public var version: String?
    public var level: EvidenceLevel
    public var sourceTitle: String
    public var observedAt: Date?
    public var deployedAt: Date?
    public var detail: String
    public var problem: ObservationProblem?
    public var isMixed = false
    public var isDemo = false
    public var isDirty = false

    /// What the stage runs, for a headline: a version, a short sha, or the honest gap.
    public var headline: String {
        if let version, !version.isEmpty { return version }
        if sha != nil { return shortSHA(sha) }
        return problem?.title ?? level.title
    }
}

/// The best current evidence for one environment.
public struct DeploymentEvidence: Sendable, Hashable {
    public var observation: DeploymentObservation?
    public var level: EvidenceLevel
    /// A newer attempt that failed, like a revoked token.
    public var problem: ObservationProblem?
    public var problemDetail: String
}

public enum DriftAnalyzer {
    /// Picks the strongest evidence. A failed attempt newer than the last good one demotes it to Stale;
    /// with no good observation at all the result is Unknown with the reason.
    public static func evidence(environment: ProductEnvironment, product: Product, cache: ObservationCache, now: Date = .now) -> DeploymentEvidence {
        let all = cache.deployments.filter { $0.environmentID == environment.id && $0.productID == product.id }
        let good = all.filter { $0.problem == nil && ($0.sha != nil || $0.version != nil) && ($0.deployState == nil || $0.deployState == "success") }
        let failures = all.filter { $0.problem != nil }
        func latestFailure(source: FactSource) -> DeploymentObservation? {
            failures.filter { $0.provenance.source == source }.max { $0.provenance.observedAt < $1.provenance.observedAt }
        }
        // Newest observation per source, then the strongest of those.
        var newestBySource: [FactSource: DeploymentObservation] = [:]
        for observation in good {
            if let current = newestBySource[observation.provenance.source], current.provenance.observedAt >= observation.provenance.observedAt { continue }
            newestBySource[observation.provenance.source] = observation
        }
        var candidates: [(DeploymentObservation, EvidenceLevel, ObservationProblem?, String)] = []
        for (source, observation) in newestBySource {
            var level = observation.provenance.effectiveLevel(now: now)
            var problem: ObservationProblem?
            var detail = ""
            if let failure = latestFailure(source: source), failure.provenance.observedAt > observation.provenance.observedAt {
                level = min(level, .stale)
                problem = failure.problem
                detail = failure.detail
            }
            candidates.append((observation, level, problem, detail))
        }
        if let best = candidates.max(by: { ($0.1, $0.0.provenance.observedAt) < ($1.1, $1.0.provenance.observedAt) }) {
            return DeploymentEvidence(observation: best.0, level: best.1, problem: best.2, problemDetail: best.3)
        }
        if let failure = failures.max(by: { $0.provenance.observedAt < $1.provenance.observedAt }) {
            return DeploymentEvidence(observation: nil, level: .unknown, problem: failure.problem, problemDetail: failure.detail)
        }
        let configured = !environment.probes.isEmpty || environment.githubEnvironmentName != nil || environment.sshHosts.contains { $0.releaseFilePath != nil }
        return DeploymentEvidence(observation: nil, level: .unknown, problem: configured ? nil : .notConfigured,
                                  problemDetail: configured ? "Not checked yet." : "No status endpoint, deployment record, or release file is connected.")
    }

    public static func chain(product: Product, cache: ObservationCache, now: Date = .now) -> [ChainNode] {
        var nodes: [ChainNode] = []
        if let checkout = product.primaryCheckout {
            if let git = cache.git[checkout.id] {
                let demo = product.isDemo
                nodes.append(ChainNode(stage: .local, title: "Local", sha: git.headSHA, version: nil,
                                       level: git.available && git.isRepository ? .verified : .unknown,
                                       sourceTitle: demo ? FactSource.fixture.title : FactSource.localCheckout.title, observedAt: git.observedAt,
                                       detail: git.summary, problem: git.available ? nil : .notFound, isDemo: demo, isDirty: git.isDirty))
            } else {
                nodes.append(ChainNode(stage: .local, title: "Local", level: .unknown, sourceTitle: FactSource.localCheckout.title,
                                       detail: "Not inspected yet"))
            }
        } else {
            nodes.append(ChainNode(stage: .local, title: "Local", level: .unknown, sourceTitle: FactSource.localCheckout.title,
                                   detail: "No local checkout", problem: .notConfigured))
        }
        if let repo = product.repositories.first {
            if let remote = cache.remotes[repo.id] {
                let level: EvidenceLevel = remote.headSHA == nil ? .unknown : remote.provenance.effectiveLevel(now: now)
                let run = remote.defaultBranchRun
                let ci = run.map { $0.succeeded ? "CI passed" : $0.failed ? "CI failing" : "CI \($0.conclusion.isEmpty ? $0.status : $0.conclusion)" }
                nodes.append(ChainNode(stage: .github, title: "GitHub", sha: remote.headSHA, level: level,
                                       sourceTitle: remote.provenance.isDemo ? FactSource.fixture.title : remote.provenance.source.title,
                                       observedAt: remote.provenance.observedAt,
                                       detail: [remote.defaultBranch, ci].compactMap { $0 }.joined(separator: " · "),
                                       problem: remote.problem, isDemo: remote.provenance.isDemo))
            } else {
                nodes.append(ChainNode(stage: .github, title: "GitHub", level: .unknown, sourceTitle: FactSource.githubAPI.title,
                                       detail: "Not fetched yet"))
            }
        } else {
            nodes.append(ChainNode(stage: .github, title: "GitHub", level: .unknown, sourceTitle: FactSource.githubAPI.title,
                                   detail: "No repository linked", problem: .notConfigured))
        }
        for (stage, tier) in [(ChainNode.Stage.staging, EnvironmentTier.staging), (.production, .production)] {
            guard let environment = product.environment(tier: tier) else {
                nodes.append(ChainNode(stage: stage, title: tier.title, level: .unknown, sourceTitle: "—",
                                       detail: "No \(tier.title.lowercased()) environment", problem: .notConfigured))
                continue
            }
            let evidence = evidence(environment: environment, product: product, cache: cache, now: now)
            let observation = evidence.observation
            var detail = evidence.problemDetail
            if detail.isEmpty, let observation {
                detail = observation.detail.isEmpty ? observation.health.title : observation.detail
            }
            nodes.append(ChainNode(stage: stage, title: environment.name, sha: observation?.sha, version: observation?.version,
                                   level: evidence.level,
                                   sourceTitle: observation.map { $0.provenance.isDemo ? FactSource.fixture.title : $0.provenance.source.title } ?? "—",
                                   observedAt: observation?.provenance.observedAt, deployedAt: observation?.deployedAt, detail: detail,
                                   problem: evidence.problem, isMixed: observation?.isMixed ?? false, isDemo: observation?.provenance.isDemo ?? false))
        }
        return nodes
    }

    public static func comparisonKey(_ a: String, _ b: String) -> String { "\(a)...\(b)" }

    public struct Relation: Sendable, Hashable, Identifiable {
        public var id: String { "\(from.rawValue)-\(to.rawValue)" }
        public var from: ChainNode.Stage
        public var to: ChainNode.Stage
        public var comparison: RevisionComparison
        public var sentence: String
    }

    /// Compares neighbouring stages from known evidence only.
    public static func relations(product: Product, cache: ObservationCache, now: Date = .now) -> [Relation] {
        let nodes = chain(product: product, cache: cache, now: now)
        func node(_ stage: ChainNode.Stage) -> ChainNode? { nodes.first { $0.stage == stage } }
        var relations: [Relation] = []
        for (from, to) in [(ChainNode.Stage.local, ChainNode.Stage.github), (.github, .production), (.staging, .production)] {
            guard let a = node(from), let b = node(to) else { continue }
            let comparison: RevisionComparison
            if let x = a.sha, let y = b.sha {
                comparison = x == y ? .same : (cache.comparisons[comparisonKey(x, y)] ?? .notEnoughHistory)
            } else {
                comparison = .unknown
            }
            relations.append(Relation(from: from, to: to, comparison: comparison, sentence: sentence(a, b, comparison)))
        }
        return relations
    }

    static func sentence(_ a: ChainNode, _ b: ChainNode, _ comparison: RevisionComparison) -> String {
        let weak = b.level < .reported ? " (\(b.level.title.lowercased()) evidence)" : b.level == .reported ? " (reported, not verified)" : ""
        switch comparison {
        case .same: return "\(a.title) and \(b.title) are on \(shortSHA(a.sha))\(weak)."
        case .ahead(let n): return "\(a.title) is \(n) commit\(n == 1 ? "" : "s") ahead of \(b.title)\(weak)."
        case .behind(let n): return "\(a.title) is \(n) commit\(n == 1 ? "" : "s") behind \(b.title)\(weak)."
        case .diverged(let ahead, let behind): return "\(a.title) and \(b.title) diverged: \(ahead) ahead, \(behind) behind\(weak)."
        case .notEnoughHistory:
            return "\(a.title) (\(shortSHA(a.sha))) and \(b.title) (\(shortSHA(b.sha))) differ. Not enough history to count commits: fetch the repository in a local checkout."
        case .unknown:
            let missing = [a, b].filter { $0.sha == nil }.map(\.title).joined(separator: " and ")
            return "Cannot compare: no commit is known for \(missing)."
        }
    }
}

public enum ProductStatus {
    public static func openIncidents(_ product: Product, cache: ObservationCache, now: Date = .now) -> [Incident] {
        cache.incidents.filter { $0.productID == product.id && $0.isOpen }
    }

    /// One badge for a product card. With nothing connected the answer is "No signal", never "Healthy".
    public static func badge(_ product: Product, cache: ObservationCache, now: Date = .now) -> StatusBadge {
        if product.isArchived { return StatusBadge("Archived", .muted) }
        let incidents = openIncidents(product, cache: cache, now: now)
        if incidents.contains(where: { $0.rule == .healthFailing }) { return StatusBadge("Unhealthy", .err) }
        if incidents.contains(where: { $0.rule == .deployFailed }) { return StatusBadge("Deploy failed", .err) }
        if incidents.contains(where: { $0.rule == .pipelineBroken }) { return StatusBadge("Build failed", .err) }
        if incidents.contains(where: { $0.rule == .authFailure }) { return StatusBadge("Sign-in needed", .warn) }
        var healthy = false
        if let production = product.environment(tier: .production) {
            let evidence = DriftAnalyzer.evidence(environment: production, product: product, cache: cache, now: now)
            if let observation = evidence.observation, evidence.level >= .reported {
                if observation.health == .unhealthy { return StatusBadge("Unhealthy", .err) }
                if observation.health == .degraded { return StatusBadge("Degraded", .warn) }
                if observation.isMixed { return StatusBadge("Mixed rollout", .warn) }
                healthy = observation.health == .healthy
            }
            if incidents.contains(where: { $0.rule == .productionDrift }) { return StatusBadge("Deploy pending", .accent) }
        }
        for environment in product.environments {
            for probe in environment.probes {
                if let last = cache.health[probe.id]?.last { if last.ok { healthy = true } else { return StatusBadge("Check failing", .warn) } }
            }
        }
        if healthy { return StatusBadge("Healthy", .ok) }
        if !product.hasLocal && !product.hasRemote && product.environments.isEmpty { return StatusBadge("Not connected", .muted) }
        if product.lifecycle == .idea { return StatusBadge("Idea", .muted) }
        return StatusBadge("No signal", .muted)
    }

    public struct Cell: Sendable, Hashable {
        public var title: String
        public var value: String
        public var tone: Tone
    }

    /// The Local / GitHub / Production strip on a product card.
    public static func cells(_ product: Product, cache: ObservationCache, now: Date = .now) -> [Cell] {
        var cells: [Cell] = []
        if let checkout = product.primaryCheckout, let git = cache.git[checkout.id] {
            let tone: Tone = !git.available ? .err : git.conflicted > 0 ? .err : git.isDirty ? .warn
                : (git.ahead ?? 0) > 0 ? .accent : (git.behind ?? 0) > 0 ? .warn : .ok
            cells.append(Cell(title: "Local", value: git.summary, tone: tone))
        } else {
            cells.append(Cell(title: "Local", value: product.hasLocal ? "Not inspected" : "No checkout", tone: .muted))
        }
        if let repo = product.repositories.first, let remote = cache.remotes[repo.id] {
            if let problem = remote.problem, remote.headSHA == nil {
                cells.append(Cell(title: "GitHub", value: problem.title, tone: .warn))
            } else if let run = remote.defaultBranchRun, run.failed {
                cells.append(Cell(title: "GitHub", value: "CI failing", tone: .err))
            } else if let first = remote.pullRequests.first {
                cells.append(Cell(title: "GitHub", value: remote.pullRequests.count == 1 ? "PR #\(first.number) open" : "\(remote.pullRequests.count) PRs open", tone: .accent))
            } else if remote.provenance.effectiveLevel(now: now) == .stale {
                cells.append(Cell(title: "GitHub", value: "Stale · \(shortSHA(remote.headSHA))", tone: .muted))
            } else if let checkout = product.primaryCheckout, let local = cache.git[checkout.id]?.headSHA, let head = remote.headSHA {
                let comparison = local == head ? RevisionComparison.same : (cache.comparisons[DriftAnalyzer.comparisonKey(local, head)] ?? .notEnoughHistory)
                switch comparison {
                case .same: cells.append(Cell(title: "GitHub", value: "In sync", tone: .ok))
                case .notEnoughHistory, .unknown: cells.append(Cell(title: "GitHub", value: "\(remote.defaultBranch) · \(shortSHA(head))", tone: .muted))
                default: cells.append(Cell(title: "GitHub", value: "Local \(comparison.title)", tone: .accent))
                }
            } else {
                cells.append(Cell(title: "GitHub", value: "\(remote.defaultBranch) · \(shortSHA(remote.headSHA))", tone: .ok))
            }
        } else {
            cells.append(Cell(title: "GitHub", value: product.hasRemote ? "Not fetched" : "No repository", tone: .muted))
        }
        if let production = product.environment(tier: .production) {
            let evidence = DriftAnalyzer.evidence(environment: production, product: product, cache: cache, now: now)
            if let observation = evidence.observation {
                let value = observation.version ?? shortSHA(observation.sha)
                switch evidence.level {
                case .verified: cells.append(Cell(title: "Production", value: value, tone: observation.health == .degraded ? .warn : observation.health == .unhealthy ? .err : .ok))
                case .reported: cells.append(Cell(title: "Production", value: "\(value) · reported", tone: .accent))
                case .stale: cells.append(Cell(title: "Production", value: "\(value) · stale", tone: .muted))
                case .unknown: cells.append(Cell(title: "Production", value: "Unknown", tone: .muted))
                }
            } else {
                cells.append(Cell(title: "Production", value: evidence.problem == .notConfigured ? "Not connected" : (evidence.problem?.title ?? "Unknown"),
                                  tone: evidence.problem == .unauthorized ? .warn : .muted))
            }
        } else {
            cells.append(Cell(title: "Production", value: "No environment", tone: .muted))
        }
        return cells
    }
}

/// Short sentences built from measured data. Templates, not a language model.
public enum PortfolioPulse {
    public struct Insight: Sendable, Hashable, Identifiable {
        public var id: String
        public var text: String
        public var tone: Tone
        public var productID: UUID?
        public var isDemo: Bool
    }

    public static func insights(portfolio: Portfolio, cache: ObservationCache, now: Date = .now, limit: Int = 5) -> [Insight] {
        var insights: [Insight] = []
        let products = portfolio.products.filter { !$0.isArchived }
        for product in products {
            for incident in ProductStatus.openIncidents(product, cache: cache, now: now) where incident.needsAttention(now: now) {
                insights.append(Insight(id: "incident-\(incident.id)", text: "\(product.name): \(incident.title).", tone: .err, productID: product.id, isDemo: product.isDemo))
            }
        }
        for product in products {
            for relation in DriftAnalyzer.relations(product: product, cache: cache, now: now) where relation.from == .staging {
                if case .ahead(let n) = relation.comparison {
                    insights.append(Insight(id: "drift-\(product.id)", text: "Production for \(product.name) is \(n) commit\(n == 1 ? "" : "s") behind staging.",
                                            tone: .accent, productID: product.id, isDemo: product.isDemo))
                }
            }
        }
        for product in products {
            let leads = MetricMath.count(cache.leads, kinds: [.lead, .signup], productID: product.id, within: 86_400, now: now)
            if leads > 0 {
                insights.append(Insight(id: "leads-\(product.id)", text: "\(product.name) has \(leads) new lead\(leads == 1 ? "" : "s") in the last 24 hours.",
                                        tone: .ok, productID: product.id, isDemo: product.isDemo))
            }
        }
        let dirty = products.filter { product in product.checkouts.contains { cache.git[$0.id]?.isDirty == true } }
        if dirty.count > 0 {
            let names = dirty.prefix(3).map(\.name).joined(separator: ", ")
            insights.append(Insight(id: "dirty", text: "\(dirty.count) codebase\(dirty.count == 1 ? " has" : "s have") uncommitted work: \(names)\(dirty.count > 3 ? "…" : "").",
                                    tone: .warn, productID: dirty.count == 1 ? dirty[0].id : nil, isDemo: dirty.allSatisfy(\.isDemo)))
        }
        for product in products {
            if let production = product.environment(tier: .production) {
                let evidence = DriftAnalyzer.evidence(environment: production, product: product, cache: cache, now: now)
                if evidence.level == .stale {
                    insights.append(Insight(id: "stale-\(product.id)", text: "Production evidence for \(product.name) is stale. Refresh to check it again.",
                                            tone: .muted, productID: product.id, isDemo: product.isDemo))
                }
            }
        }
        return Array(insights.prefix(limit))
    }

    /// One sentence for the dashboard header.
    public static func headline(portfolio: Portfolio, cache: ObservationCache, now: Date = .now) -> String {
        let products = portfolio.products.filter { !$0.isArchived }
        guard !products.isEmpty else { return "Add a product to see its code, deployments, and leads in one place." }
        let badges = products.map { ProductStatus.badge($0, cache: cache, now: now) }
        let bad = zip(products, badges).filter { $0.1.tone == .err || $0.1.tone == .warn }
        let healthy = badges.filter { $0.tone == .ok }.count
        let silent = badges.filter { $0.tone == .muted }.count
        if let first = bad.first {
            let others = bad.count - 1
            return "\(first.0.name) is \(first.1.label.lowercased())\(others > 0 ? " and \(others) more need\(others == 1 ? "s" : "") attention" : ""). \(healthy) of \(products.count) report healthy."
        }
        if healthy == products.count { return "All \(products.count) products report healthy." }
        if healthy == 0 { return "\(products.count) product\(products.count == 1 ? "" : "s"), none connected to a health source yet." }
        return "\(healthy) of \(products.count) products report healthy. \(silent) have no health signal connected."
    }
}
