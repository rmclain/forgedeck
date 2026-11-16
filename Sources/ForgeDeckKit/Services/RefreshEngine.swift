import Foundation

// Refresh: connectors produce `CacheUpdate` values off the main thread, and the
// cache applies them in one place. Applying is where activity events and alerts are
// derived, so two refreshes running at once cannot overwrite each other.

public enum CacheUpdate: Sendable {
    case git(checkout: UUID, GitSnapshot)
    case remote(repository: UUID, product: UUID, ConnectorResult<RemoteSnapshot>)
    case probe(probe: UUID, environment: UUID, product: UUID, ProbeOutcome)
    case deployment(DeploymentObservation)
    case metrics(source: UUID, ConnectorResult<[MetricSample]>)
    case leads(source: UUID, product: UUID, ConnectorResult<[LeadEvent]>)
    case comparison(key: String, RevisionComparison)
}

extension ObservationCache {
    private mutating func touch(_ key: String, problem: ObservationProblem?, at: Date) {
        var state = sync[key] ?? SyncState()
        state.lastAttempt = at
        state.lastProblem = problem
        if problem == nil { state.lastSuccess = at }
        sync[key] = state
    }

    /// Applies updates and derives activity and alerts. `now` is injectable for tests.
    public mutating func apply(_ updates: [CacheUpdate], portfolio: Portfolio, now: Date = .now) {
        for update in updates {
            switch update {
            case .git(let checkout, let snapshot):
                git[checkout] = snapshot

            case .remote(let repositoryID, let productID, let result):
                guard let product = portfolio.product(id: productID), let repo = product.repository(id: repositoryID) else { continue }
                let previous = remotes[repositoryID]
                switch result {
                case .success(let snapshot), .partial(let snapshot, _):
                    remotes[repositoryID] = snapshot
                    touch("github:\(repositoryID.uuidString)", problem: nil, at: now)
                    deriveActivity(from: snapshot, previous: previous, repo: repo, product: product)
                    recordReportedDeployments(snapshot, product: product)
                case .failure(let problem, _, _):
                    // Keep the last known head, marked with the problem. It turns Stale by its own expiry.
                    var kept = previous ?? RemoteSnapshot()
                    kept.problem = problem
                    if previous == nil { kept.provenance = Provenance(observedAt: now, source: .githubAPI, level: .unknown) }
                    remotes[repositoryID] = kept
                    touch("github:\(repositoryID.uuidString)", problem: problem, at: now)
                }

            case .probe(let probeID, let environmentID, let productID, let outcome):
                guard let product = portfolio.product(id: productID), let environment = product.environment(id: environmentID),
                      let probe = environment.probes.first(where: { $0.id == probeID }) else { continue }
                record(outcome.sample, probe: probeID)
                touch("probe:\(probeID.uuidString)", problem: outcome.sample.problem, at: outcome.sample.at)
                if var observation = outcome.deployment {
                    observation.productID = productID
                    observation.environmentID = environmentID
                    observation.componentID = probe.componentID
                    let before = DriftAnalyzer.evidence(environment: environment, product: product, cache: self, now: now).observation?.sha
                    record(observation)
                    if let sha = observation.sha, observation.problem == nil, let before, before != sha {
                        record(ActivityEvent(id: "runtime:\(environmentID.uuidString):\(sha)", kind: .deploy, productID: productID,
                                             title: "\(environment.name) now runs \(observation.version ?? shortSHA(sha))",
                                             detail: "Verified by the status endpoint · was \(shortSHA(before))",
                                             at: observation.provenance.observedAt, sourceLabel: FactSource.runtimeProbe.title))
                    }
                }
                AlertEngine.evaluateHealth(probe: probe, environment: environment, product: product, cache: &self)

            case .deployment(let observation):
                record(observation)

            case .metrics(let sourceID, let result):
                switch result {
                case .success(let samples), .partial(let samples, _):
                    for sample in samples {
                        set(sample)
                        if sample.window == "24h" { setPoint(MetricPoint(productID: sample.productID, key: sample.key, day: now, value: sample.value)) }
                    }
                    touch("metrics:\(sourceID.uuidString)", problem: nil, at: now)
                case .failure(let problem, _, _):
                    // The old numbers stay, with their old timestamps: they show as Stale, never as zero.
                    touch("metrics:\(sourceID.uuidString)", problem: problem, at: now)
                }

            case .leads(let sourceID, let productID, let result):
                switch result {
                case .success(let events), .partial(let events, _):
                    let firstSync = !leads.contains { $0.sourceID == sourceID }
                    let fresh = merge(leads: events)
                    // The first sync imports history quietly. Later events appear in the feed.
                    if !firstSync {
                        for event in fresh {
                            let money = event.valueCents.map { " · " + Money.format(cents: $0) } ?? ""
                            record(ActivityEvent(id: "lead:\(event.id)", kind: event.kind == .paidConversion || event.kind == .renewal ? .purchase : .lead,
                                                 productID: productID, title: event.title, detail: "\(event.sourceLabel)\(money)",
                                                 at: event.occurredAt, sourceLabel: event.sourceLabel))
                        }
                    }
                    touch("leads:\(sourceID.uuidString)", problem: nil, at: now)
                case .failure(let problem, _, _):
                    touch("leads:\(sourceID.uuidString)", problem: problem, at: now)
                }

            case .comparison(let key, let comparison):
                comparisons[key] = comparison
            }
        }
        AlertEngine.evaluate(portfolio: portfolio, cache: &self, now: now)
    }

    private mutating func deriveActivity(from snapshot: RemoteSnapshot, previous: RemoteSnapshot?, repo: Repository, product: Product) {
        // Nothing is announced on the first fetch: history is not news.
        guard let previous, previous.headSHA != nil else { return }
        if let head = snapshot.headSHA, head != previous.headSHA {
            record(ActivityEvent(id: "head:\(repo.id.uuidString):\(head)", kind: .commit, productID: product.id,
                                 title: snapshot.headMessage ?? "New commit on \(snapshot.defaultBranch)",
                                 detail: "\(repo.fullName) · \(snapshot.defaultBranch) → \(shortSHA(head))",
                                 at: snapshot.headDate ?? snapshot.provenance.observedAt, sourceLabel: "GitHub"))
        }
        let knownPRs = Set(previous.pullRequests.map(\.number))
        for pr in snapshot.pullRequests where !knownPRs.contains(pr.number) {
            record(ActivityEvent(id: "pr:\(repo.id.uuidString):\(pr.number)", kind: .pullRequest, productID: product.id,
                                 title: "PR #\(pr.number) opened: \(pr.title)", detail: "\(repo.fullName) · \(pr.author)",
                                 at: pr.updatedAt, sourceLabel: "GitHub"))
        }
        let knownRuns = Dictionary(previous.runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for run in snapshot.runs where run.status == "completed" && knownRuns[run.id]?.conclusion != run.conclusion {
            if run.failed {
                record(ActivityEvent(id: "run:\(run.id):failed", kind: .checkFailed, productID: product.id,
                                     title: "\(run.name.isEmpty ? "Workflow" : run.name) failed",
                                     detail: "\(repo.fullName) · \(run.branch) · \(shortSHA(run.headSHA))", at: run.createdAt, sourceLabel: "GitHub Actions"))
            }
        }
    }

    /// GitHub deployment records become Reported evidence for environments mapped to them.
    private mutating func recordReportedDeployments(_ snapshot: RemoteSnapshot, product: Product) {
        for environment in product.environments {
            guard let name = environment.githubEnvironmentName?.lowercased(), !name.isEmpty,
                  let record = snapshot.deployments.filter({ $0.environment.lowercased() == name && !$0.state.isEmpty })
                    .max(by: { $0.createdAt < $1.createdAt }) else { continue }
            var observation = DeploymentObservation()
            observation.productID = product.id
            observation.environmentID = environment.id
            observation.sha = record.sha
            observation.deployedAt = record.createdAt
            observation.deployState = record.state
            observation.detail = "GitHub deployment #\(record.id) by \(record.creator): \(record.state)"
            observation.provenance = Provenance(observedAt: snapshot.provenance.observedAt, source: .deploymentRecord, level: .reported,
                                                ttl: snapshot.provenance.expiresAt.timeIntervalSince(snapshot.provenance.observedAt))
            let known = deployments.contains { $0.environmentID == environment.id && $0.provenance.source == .deploymentRecord && $0.sha == record.sha && $0.deployState == record.state }
            self.record(observation)
            if !known {
                self.record(ActivityEvent(id: "ghdeploy:\(record.id):\(record.state)", kind: .deploy, productID: product.id,
                                          title: "Deploy to \(environment.name) \(record.state == "success" ? "reported" : record.state)",
                                          detail: "\(shortSHA(record.sha)) · reported by GitHub, not verified at runtime",
                                          at: record.createdAt, sourceLabel: "GitHub deployments"))
            }
        }
    }
}

public enum Money {
    public static func format(cents: Int, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = cents % 100 == 0 ? 0 : 2
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "$\(cents / 100)"
    }
}

/// Runs the connectors for one product and returns the updates.
public struct RefreshEngine: Sendable {
    public var git: GitService
    public var http: any HTTPClient
    public var ssh: SSHInspector
    public var credentials: CredentialResolver
    public var etags: ETagCache
    public var ttl: TimeInterval

    public init(git: GitService = GitService(), http: any HTTPClient = URLSessionHTTPClient(), ssh: SSHInspector = SSHInspector(),
                credentials: CredentialResolver = CredentialResolver(), etags: ETagCache = ETagCache(), ttl: TimeInterval = 900) {
        self.git = git
        self.http = http
        self.ssh = ssh
        self.credentials = credentials
        self.etags = etags
        self.ttl = ttl
    }

    public func refreshGit(_ product: Product) async -> [CacheUpdate] {
        guard !product.isDemo else { return [] }
        var updates: [CacheUpdate] = []
        for checkout in product.checkouts {
            updates.append(.git(checkout: checkout.id, await git.snapshot(path: checkout.path)))
        }
        return updates
    }

    public func githubToken(_ portfolio: Portfolio) async -> String? {
        guard let reference = portfolio.connection(provider: .github)?.credential else { return nil }
        return try? await credentials.value(for: reference)
    }

    public func refreshRemote(_ product: Product, portfolio: Portfolio) async -> [CacheUpdate] {
        guard !product.isDemo, !product.repositories.isEmpty else { return [] }
        let connector = GitHubConnector(http: http, token: await githubToken(portfolio), etags: etags)
        let environments = product.environments.compactMap(\.githubEnvironmentName)
        var updates: [CacheUpdate] = []
        for repo in product.repositories where repo.provider == "github" {
            var result = await connector.snapshot(owner: repo.owner, name: repo.name, environments: environments)
            if case .success(var snapshot) = result {
                snapshot.provenance = Provenance(source: .githubAPI, level: .verified, ttl: ttl)
                result = .success(snapshot)
            }
            updates.append(.remote(repository: repo.id, product: product.id, result))
        }
        return updates
    }

    /// The value of a variable for this environment, for a bearer token. nil when it is not defined or not allowed here.
    public func bearer(key: String?, product: Product, environment: ProductEnvironment, portfolio: Portfolio) async -> String? {
        guard let key, !key.isEmpty else { return nil }
        let context = ResolutionContext(product: product, environment: environment)
        guard let resolved = VariableResolver.resolve(portfolio.variables, context: context).first(where: { $0.key == key }),
              resolved.state.delivers, let definition = resolved.winner else { return nil }
        if definition.isSecret {
            guard let reference = definition.credential else { return nil }
            return try? await credentials.value(for: reference)
        }
        return definition.plainValue
    }

    public func refreshProbes(_ product: Product, portfolio: Portfolio) async -> [CacheUpdate] {
        guard !product.isDemo, !product.isArchived else { return [] }
        let connector = HTTPProbeConnector(http: http, ttl: ttl)
        var updates: [CacheUpdate] = []
        for environment in product.environments {
            for probe in environment.probes {
                let token = await bearer(key: probe.bearerVariableKey, product: product, environment: environment, portfolio: portfolio)
                var outcome = await connector.status(probe, bearer: token, expectedTier: environment.tier)
                // A token that should exist but could not be read is an authentication problem, not an outage.
                if probe.bearerVariableKey != nil, token == nil, !outcome.sample.ok {
                    outcome.sample.problem = .unauthorized
                    outcome.deployment?.problem = .unauthorized
                    outcome.deployment?.detail = "The token variable \(probe.bearerVariableKey ?? "") is missing or not allowed in \(environment.name)."
                }
                updates.append(.probe(probe: probe.id, environment: environment.id, product: product.id, outcome))
            }
            for host in environment.sshHosts {
                guard let path = host.releaseFilePath, !path.isEmpty else { continue }
                var observation = await ssh.release(alias: host.alias, path: path, ttl: ttl)
                observation.productID = product.id
                observation.environmentID = environment.id
                observation.componentID = host.componentID
                updates.append(.deployment(observation))
            }
        }
        return updates
    }

    public func refreshMetrics(_ product: Product, portfolio: Portfolio) async -> [CacheUpdate] {
        guard !product.isDemo, !product.isArchived else { return [] }
        let connector = CompanionMetricsConnector(http: http, ttl: ttl)
        var updates: [CacheUpdate] = []
        for environment in product.environments {
            for source in environment.metricSources {
                let token = await bearer(key: source.bearerVariableKey, product: product, environment: environment, portfolio: portfolio)
                for window in ["24h", "7d", "30d"] {
                    let result = await connector.metrics(source, productID: product.id, window: window, bearer: token)
                    updates.append(.metrics(source: source.id, result))
                    if result.problem != nil { break }
                }
                if source.leadsEnabled {
                    updates.append(.leads(source: source.id, product: product.id,
                                          await connector.events(source, productID: product.id, bearer: token, maxPages: 5)))
                }
            }
        }
        return updates
    }

    /// Counts commits between neighbouring stages when a local checkout has both commits.
    public func refreshComparisons(_ product: Product, cache: ObservationCache, now: Date = .now) async -> [CacheUpdate] {
        guard !product.isDemo, let checkout = product.primaryCheckout else { return [] }
        let nodes = DriftAnalyzer.chain(product: product, cache: cache, now: now)
        func sha(_ stage: ChainNode.Stage) -> String? { nodes.first { $0.stage == stage }?.sha }
        var updates: [CacheUpdate] = []
        for (from, to) in [(ChainNode.Stage.local, ChainNode.Stage.github), (.github, .production), (.staging, .production)] {
            guard let a = sha(from), let b = sha(to), a != b else { continue }
            updates.append(.comparison(key: DriftAnalyzer.comparisonKey(a, b), await git.compare(a, to: b, path: checkout.path)))
        }
        return updates
    }
}
