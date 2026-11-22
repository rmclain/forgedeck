import Foundation

// Observed facts. Every remote fact carries when it was seen, where it came from,
// how strong the evidence is, and when it stops being current.

public enum EvidenceLevel: String, Codable, CaseIterable, Sendable, Comparable {
    /// Nothing observed, or the observation failed.
    case unknown
    /// Observed once, but past its expiry.
    case stale
    /// A CI or provider record says so. The target did not confirm it.
    case reported
    /// The target itself reported it (authenticated status endpoint, release file over SSH, local checkout).
    case verified

    public var title: String {
        switch self {
        case .unknown: "Unknown"
        case .stale: "Stale"
        case .reported: "Reported"
        case .verified: "Verified"
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public enum FactSource: String, Codable, Sendable {
    case localCheckout, githubAPI, ciArtifact, deploymentRecord, runtimeProbe, sshInspection, metricsAPI, fixture, packageRegistry

    public var title: String {
        switch self {
        case .localCheckout: "Local checkout"
        case .githubAPI: "GitHub API"
        case .ciArtifact: "CI artifact"
        case .deploymentRecord: "Deployment record"
        case .runtimeProbe: "Runtime status endpoint"
        case .sshInspection: "SSH inspection"
        case .metricsAPI: "Metrics API"
        case .fixture: "Demo fixture"
        case .packageRegistry: "Package registry"
        }
    }
}

/// Why an observation has no value.
public enum ObservationProblem: String, Codable, Sendable {
    case notConfigured, unauthorized, forbidden, notFound, rateLimited, unavailable, malformed, unsupported, offline, tlsFailure, timeout, hostKeyUnknown, hostKeyChanged, cancelled

    public var title: String {
        switch self {
        case .notConfigured: "Not configured"
        case .unauthorized: "Authentication required"
        case .forbidden: "Permission denied"
        case .notFound: "Not found"
        case .rateLimited: "Rate limited"
        case .unavailable: "Unavailable"
        case .malformed: "Malformed response"
        case .unsupported: "Unsupported"
        case .offline: "Offline"
        case .tlsFailure: "TLS verification failed"
        case .timeout: "Timed out"
        case .hostKeyUnknown: "Unknown host key"
        case .hostKeyChanged: "Host key changed"
        case .cancelled: "Cancelled"
        }
    }
}

public struct Provenance: Codable, Hashable, Sendable {
    public var observedAt: Date
    public var source: FactSource
    public var level: EvidenceLevel
    public var expiresAt: Date
    public var isDemo: Bool

    public init(observedAt: Date = .now, source: FactSource, level: EvidenceLevel, ttl: TimeInterval = 900, isDemo: Bool = false) {
        self.observedAt = observedAt
        self.source = source
        self.level = level
        expiresAt = observedAt.addingTimeInterval(ttl)
        self.isDemo = isDemo
    }

    /// The level to show now: an expired observation is Stale, never Verified.
    public func effectiveLevel(now: Date = .now) -> EvidenceLevel {
        if level == .unknown { return .unknown }
        return now > expiresAt ? .stale : level
    }
}

// MARK: Git

public struct CommitSummary: Codable, Hashable, Sendable, Identifiable {
    public var sha = ""
    public var subject = ""
    public var author = ""
    public var date = Date.distantPast
    public var id: String { sha }
    public init() {}
    public init(sha: String, subject: String, author: String, date: Date) {
        self.sha = sha; self.subject = subject; self.author = author; self.date = date
    }
}

public struct GitSnapshot: Codable, Hashable, Sendable {
    public var available = true
    public var problem: String?
    public var isRepository = true
    public var branch: String?
    public var isDetached = false
    public var headSHA: String?
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var staged = 0
    public var unstaged = 0
    public var untracked = 0
    public var conflicted = 0
    public var stashes = 0
    public var isShallow = false
    public var isWorktree = false
    public var worktrees: [String] = []
    public var remotes: [String: String] = [:]
    public var lastFetch: Date?
    public var recentCommits: [CommitSummary] = []
    public var observedAt = Date.now
    public init() {}

    public var isDirty: Bool { staged + unstaged + untracked + conflicted > 0 }
    public var changeCount: Int { staged + unstaged + untracked + conflicted }

    /// One short line, like "main · clean" or "3 uncommitted".
    public var summary: String {
        guard available else { return problem ?? "Folder missing" }
        guard isRepository else { return "Not a Git repository" }
        let name = isDetached ? "detached \(shortSHA(headSHA))" : (branch ?? "no branch")
        if conflicted > 0 { return "\(name) · \(conflicted) conflicted" }
        if isDirty { return "\(name) · \(changeCount) uncommitted" }
        if let ahead, ahead > 0, let behind, behind > 0 { return "\(name) · \(ahead) ahead, \(behind) behind" }
        if let ahead, ahead > 0 { return "\(name) · \(ahead) ahead" }
        if let behind, behind > 0 { return "\(name) · \(behind) behind" }
        return "\(name) · clean"
    }
}

public func shortSHA(_ sha: String?) -> String {
    guard let sha, !sha.isEmpty else { return "—" }
    return String(sha.prefix(7))
}

// MARK: Remote repository

public struct PullRequestSummary: Codable, Hashable, Sendable, Identifiable {
    public var number = 0
    public var title = ""
    public var author = ""
    public var isDraft = false
    public var updatedAt = Date.distantPast
    public var url = ""
    public var id: Int { number }
    public init() {}
}

/// An open issue in the repository, as GitHub's REST API listed it. Pull requests are left out.
public struct GitHubIssueSummary: Codable, Hashable, Sendable, Identifiable {
    public var number = 0
    public var title = ""
    public var author = ""
    public var labels: [String] = []
    public var comments = 0
    public var createdAt = Date.distantPast
    public var updatedAt = Date.distantPast
    public var url = ""
    /// The start of the description, at most `bodyLimit` characters.
    public var body = ""
    public var id: Int { number }
    public static let bodyLimit = 2_000
    public init() {}
}

public struct WorkflowRunSummary: Codable, Hashable, Sendable, Identifiable {
    public var id = 0
    public var name = ""
    public var branch = ""
    public var headSHA = ""
    /// queued, in_progress, completed
    public var status = ""
    /// success, failure, cancelled, … Empty while running.
    public var conclusion = ""
    public var createdAt = Date.distantPast
    public var url = ""
    public init() {}

    public var failed: Bool { ["failure", "timed_out", "startup_failure"].contains(conclusion) }
    public var succeeded: Bool { conclusion == "success" }
}

public struct ReportedDeployment: Codable, Hashable, Sendable, Identifiable {
    public var id = 0
    public var environment = ""
    public var sha = ""
    public var ref = ""
    /// success, failure, error, in_progress, queued, inactive, pending
    public var state = ""
    public var createdAt = Date.distantPast
    public var creator = ""
    public init() {}
}

public struct RemoteSnapshot: Codable, Hashable, Sendable {
    public var defaultBranch = "main"
    public var headSHA: String?
    public var headMessage: String?
    public var headDate: Date?
    public var pullRequests: [PullRequestSummary] = []
    /// Open issues, most recently updated first. nil when not read (older caches, or issues turned off on GitHub).
    public var issues: [GitHubIssueSummary]?
    public var runs: [WorkflowRunSummary] = []
    public var deployments: [ReportedDeployment] = []
    public var latestReleaseTag: String?
    public var problem: ObservationProblem?
    public var provenance = Provenance(source: .githubAPI, level: .unknown)
    public init() {}

    /// The newest completed run on the default branch.
    public var defaultBranchRun: WorkflowRunSummary? {
        runs.filter { $0.branch == defaultBranch && $0.status == "completed" }.max { $0.createdAt < $1.createdAt }
    }
}

// MARK: Deployments and health

public enum HealthState: String, Codable, Sendable {
    case healthy, degraded, unhealthy, unknown

    public var title: String { rawValue.capitalized }
}

/// One observation of what runs in an environment.
public struct DeploymentObservation: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var productID = UUID()
    public var environmentID = UUID()
    public var componentID: UUID?
    public var sha: String?
    public var version: String?
    public var deployedAt: Date?
    public var deployState: String?
    public var health: HealthState = .unknown
    /// Distinct revisions seen across instances. More than one means a mixed rollout.
    public var instanceSHAs: [String] = []
    public var problem: ObservationProblem?
    public var detail = ""
    public var provenance = Provenance(source: .runtimeProbe, level: .unknown)
    public init() {}

    public var isMixed: Bool { Set(instanceSHAs).count > 1 }
}

public struct HealthSample: Codable, Hashable, Sendable {
    public var at = Date.now
    public var ok = false
    public var latencyMS: Int?
    public var statusCode: Int?
    public var problem: ObservationProblem?
    public init() {}
    public init(at: Date, ok: Bool, latencyMS: Int? = nil, statusCode: Int? = nil, problem: ObservationProblem? = nil) {
        self.at = at; self.ok = ok; self.latencyMS = latencyMS; self.statusCode = statusCode; self.problem = problem
    }
}

// MARK: Business

public enum BusinessEventKind: String, Codable, CaseIterable, Sendable {
    case lead, signup, paidConversion = "paid_conversion", renewal, cancellation, deploy, incident, custom

    public var title: String {
        switch self {
        case .lead: "Lead"
        case .signup: "Signup"
        case .paidConversion: "Paid conversion"
        case .renewal: "Renewal"
        case .cancellation: "Cancellation"
        case .deploy: "Deploy"
        case .incident: "Incident"
        case .custom: "Event"
        }
    }

    public var isRevenue: Bool { [.lead, .signup, .paidConversion, .renewal].contains(self) }
}

public enum LeadState: String, Codable, CaseIterable, Sendable { case new, read, flagged, handled }

public struct LeadEvent: Codable, Hashable, Sendable, Identifiable {
    /// "<sourceID>:<remote id>". The same remote event never counts twice.
    public var id = ""
    public var productID = UUID()
    public var sourceID = UUID()
    public var kind: BusinessEventKind = .lead
    public var occurredAt = Date.now
    public var title = ""
    public var sourceLabel = ""
    public var maskedContact: String?
    public var valueCents: Int?
    public var state: LeadState = .new
    public var isDemo = false
    public var receivedAt = Date.now
    public init() {}
}

/// A counter the source reported for a window, with its own provenance.
public struct MetricSample: Codable, Hashable, Sendable {
    public var productID = UUID()
    public var sourceID = UUID()
    public var key = ""
    public var window = "24h"
    public var value = 0.0
    public var sourceLabel = ""
    public var provenance = Provenance(source: .metricsAPI, level: .unknown)
    public init() {}
}

/// One point per day for spark lines. A missing day stays missing: it is not zero.
public struct MetricPoint: Codable, Hashable, Sendable {
    public var productID = UUID()
    public var key = ""
    public var day = Date.now
    public var value = 0.0
    public init() {}
    public init(productID: UUID, key: String, day: Date, value: Double) {
        self.productID = productID; self.key = key; self.day = day; self.value = value
    }
}

// MARK: Activity, incidents, sessions

public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case commit, pullRequest, deploy, checkFailed, checkRecovered, lead, purchase, alert, recovery, authFailure, terminal, custom

    public enum Category: String, CaseIterable, Sendable { case all = "All", revenue = "Revenue", deploys = "Deploys", alerts = "Alerts" }

    public var category: Category {
        switch self {
        case .lead, .purchase: .revenue
        case .deploy, .commit, .pullRequest: .deploys
        case .checkFailed, .checkRecovered, .alert, .recovery, .authFailure: .alerts
        case .terminal, .custom: .all
        }
    }
}

public struct ActivityEvent: Codable, Hashable, Sendable, Identifiable {
    /// A stable key. Recording the same key twice keeps one event.
    public var id = ""
    public var kind: ActivityKind = .custom
    public var productID: UUID?
    public var title = ""
    public var detail = ""
    public var at = Date.now
    public var sourceLabel = ""
    public var link: String?
    public var isDemo = false
    public init() {}
    public init(id: String, kind: ActivityKind, productID: UUID?, title: String, detail: String, at: Date, sourceLabel: String, isDemo: Bool = false) {
        self.id = id; self.kind = kind; self.productID = productID; self.title = title
        self.detail = detail; self.at = at; self.sourceLabel = sourceLabel; self.isDemo = isDemo
    }
}

public enum AlertRuleKind: String, Codable, CaseIterable, Sendable {
    case healthFailing, deployFailed, productionDrift, secretExpiring, pipelineBroken, leadIngestStalled, authFailure

    public var title: String {
        switch self {
        case .healthFailing: "Health check failing"
        case .deployFailed: "Deploy failed"
        case .productionDrift: "Production differs from staging"
        case .secretExpiring: "Secret needs rotation"
        case .pipelineBroken: "Pipeline failing"
        case .leadIngestStalled: "Lead source stalled"
        case .authFailure: "Authentication failed"
        }
    }
}

public struct Incident: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var rule: AlertRuleKind = .healthFailing
    /// What the incident is about, like a probe id. One open incident per rule and subject.
    public var subject = ""
    public var productID: UUID?
    public var title = ""
    public var detail = ""
    public var openedAt = Date.now
    public var resolvedAt: Date?
    public var acknowledgedAt: Date?
    public var snoozedUntil: Date?
    public var isDemo = false
    public init() {}

    public var isOpen: Bool { resolvedAt == nil }
    public func needsAttention(now: Date = .now) -> Bool {
        isOpen && acknowledgedAt == nil && (snoozedUntil.map { $0 <= now } ?? true)
    }
}

public struct SessionRecord: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var app = ""
    public var productID: UUID?
    public var checkoutID: UUID?
    public var environmentID: UUID?
    public var startedAt = Date.now
    /// A safe identifier like "open-terminal" or a recipe label. Never a transcript.
    public var commandIdentifier = ""
    public var exitStatus: Int32?
    public init() {}
}

public struct SyncState: Codable, Hashable, Sendable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastProblem: ObservationProblem?
    public init() {}
}

/// Result of comparing two revisions.
public enum RevisionComparison: Codable, Hashable, Sendable {
    case same
    case ahead(Int)
    case behind(Int)
    case diverged(ahead: Int, behind: Int)
    /// One of the commits is not in the local object database.
    case notEnoughHistory
    case unknown

    public var title: String {
        switch self {
        case .same: "In sync"
        case .ahead(let n): "\(n) ahead"
        case .behind(let n): "\(n) behind"
        case .diverged(let a, let b): "\(a) ahead, \(b) behind"
        case .notEnoughHistory: "Not enough history"
        case .unknown: "Unknown"
        }
    }
}

/// Everything observed. Bounded, and safe to delete.
public struct ObservationCache: Codable, Sendable {
    public var schemaVersion = 1
    public var git: [UUID: GitSnapshot] = [:]
    public var remotes: [UUID: RemoteSnapshot] = [:]
    public var deployments: [DeploymentObservation] = []
    public var health: [UUID: [HealthSample]] = [:]
    public var metrics: [MetricSample] = []
    public var points: [MetricPoint] = []
    public var leads: [LeadEvent] = []
    public var activity: [ActivityEvent] = []
    public var incidents: [Incident] = []
    public var sessions: [SessionRecord] = []
    public var sync: [String: SyncState] = [:]
    public var comparisons: [String: RevisionComparison] = [:]
    /// What each release channel's registry publishes, by channel id. Optional so older cache files load.
    public var releases: [UUID: ReleaseObservation]?
    public init() {}

    public static let maxHealthSamples = 90
    public static let maxActivity = 600
    public static let maxLeads = 2_000
    public static let maxDeployments = 400
    public static let maxSessions = 200

    /// Adds an event once. Returns false when the id was already recorded.
    @discardableResult
    public mutating func record(_ event: ActivityEvent) -> Bool {
        guard !activity.contains(where: { $0.id == event.id }) else { return false }
        activity.append(event)
        activity.sort { $0.at > $1.at }
        if activity.count > Self.maxActivity { activity.removeLast(activity.count - Self.maxActivity) }
        return true
    }

    public mutating func record(_ sample: HealthSample, probe: UUID) {
        var list = health[probe] ?? []
        list.append(sample)
        if list.count > Self.maxHealthSamples { list.removeFirst(list.count - Self.maxHealthSamples) }
        health[probe] = list
    }

    /// Keeps a history: a new observation is appended when the release or the evidence changed,
    /// otherwise the newest one is refreshed.
    public mutating func record(_ observation: DeploymentObservation) {
        if let index = deployments.lastIndex(where: {
            $0.environmentID == observation.environmentID && $0.componentID == observation.componentID
                && $0.provenance.source == observation.provenance.source
        }), deployments[index].sha == observation.sha, deployments[index].problem == observation.problem,
           deployments[index].deployState == observation.deployState {
            var updated = observation
            updated.id = deployments[index].id
            deployments[index] = updated
        } else {
            deployments.append(observation)
        }
        if deployments.count > Self.maxDeployments { deployments.removeFirst(deployments.count - Self.maxDeployments) }
    }

    /// Adds leads the cache has not seen. Returns the new ones.
    @discardableResult
    public mutating func merge(leads incoming: [LeadEvent]) -> [LeadEvent] {
        let known = Set(leads.map(\.id))
        var seen = Set<String>()
        let fresh = incoming.filter { !known.contains($0.id) && seen.insert($0.id).inserted }
        leads.append(contentsOf: fresh)
        leads.sort { $0.occurredAt > $1.occurredAt }
        if leads.count > Self.maxLeads { leads.removeLast(leads.count - Self.maxLeads) }
        return fresh
    }

    public mutating func set(_ sample: MetricSample) {
        metrics.removeAll { $0.sourceID == sample.sourceID && $0.key == sample.key && $0.window == sample.window }
        metrics.append(sample)
    }

    public mutating func setPoint(_ point: MetricPoint, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: point.day)
        points.removeAll { $0.productID == point.productID && $0.key == point.key && calendar.isDate($0.day, inSameDayAs: day) }
        points.append(MetricPoint(productID: point.productID, key: point.key, day: day, value: point.value))
    }

    /// Drops observations older than the retention window. Definitions are untouched.
    public mutating func prune(retentionDays: Int, now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        activity.removeAll { $0.at < cutoff }
        leads.removeAll { $0.occurredAt < cutoff }
        points.removeAll { $0.day < cutoff }
        incidents.removeAll { ($0.resolvedAt ?? now) < cutoff }
        if sessions.count > Self.maxSessions { sessions.removeFirst(sessions.count - Self.maxSessions) }
    }

    /// Removes everything observed for one product.
    public mutating func remove(product: Product) {
        for checkout in product.checkouts { git[checkout.id] = nil }
        for repo in product.repositories { remotes[repo.id] = nil }
        for env in product.environments { for probe in env.probes { health[probe.id] = nil } }
        deployments.removeAll { $0.productID == product.id }
        metrics.removeAll { $0.productID == product.id }
        points.removeAll { $0.productID == product.id }
        leads.removeAll { $0.productID == product.id }
        activity.removeAll { $0.productID == product.id }
        incidents.removeAll { $0.productID == product.id }
        sessions.removeAll { $0.productID == product.id }
    }
}
