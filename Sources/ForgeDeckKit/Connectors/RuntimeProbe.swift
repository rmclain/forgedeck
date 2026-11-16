import Foundation

// HTTP health checks and the ForgeDeck companion status contract.
// A plain health check proves the endpoint answers. Only a companion status response
// proves which release is running: that is the "runtime verified" evidence.

public struct CompanionStatus: Decodable, Sendable, Equatable {
    public struct Release: Decodable, Sendable, Equatable {
        public var commit_sha: String?
        public var version: String?
        public var deployed_at: String?
    }

    public struct Check: Decodable, Sendable, Equatable {
        public var id: String
        public var state: String
    }

    public struct Health: Decodable, Sendable, Equatable {
        public var state: String
        public var checks: [Check]?
    }

    public struct Instance: Decodable, Sendable, Equatable {
        public var id: String?
        public var commit_sha: String?
    }

    public var schema_version: String
    public var product_id: String?
    public var component_id: String?
    public var environment: String?
    public var observed_at: String?
    public var release: Release?
    public var health: Health?
    public var metrics: [String: Double]?
    public var capabilities: [String]?
    public var instances: [Instance]?
}

public struct ProbeOutcome: Sendable {
    public var sample: HealthSample
    /// Set for companion probes: what the target says it runs.
    public var deployment: DeploymentObservation?
    public var detail: String
}

public struct HTTPProbeConnector: RuntimeProbe {
    public static let provider = ProviderKind.http
    public static let capabilities: [ConnectorCapability] = [.health, .runtimeStatus]
    public static let supportedSchemaMajor = "1"

    public let http: any HTTPClient
    public let ttl: TimeInterval

    public init(http: any HTTPClient = URLSessionHTTPClient(timeout: 8), ttl: TimeInterval = 900) {
        self.http = http
        self.ttl = ttl
    }

    public func status(_ probe: ProbeConfig, bearer: String?, expectedTier: EnvironmentTier) async -> ProbeOutcome {
        let started = Date.now
        func failed(_ problem: ObservationProblem, _ detail: String, status: Int? = nil) -> ProbeOutcome {
            var observation: DeploymentObservation?
            if probe.kind.reportsRelease {
                var o = DeploymentObservation()
                o.problem = problem
                o.detail = detail
                o.provenance = Provenance(observedAt: started, source: .runtimeProbe, level: .unknown, ttl: ttl)
                observation = o
            }
            return ProbeOutcome(sample: HealthSample(at: started, ok: false, statusCode: status, problem: problem),
                                deployment: observation, detail: detail)
        }
        let url: URL
        do { url = try URLPolicy.validate(probe.url) } catch { return failed(.notConfigured, String(describing: error)) }
        var request = URLRequest(url: url)
        request.timeoutInterval = probe.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Brand.name, forHTTPHeaderField: "User-Agent")
        if let bearer, !bearer.isEmpty { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let response: HTTPResponse
        do { response = try await http.send(request) } catch {
            let (problem, detail) = HTTPFailure.problem(for: error)
            return failed(problem, detail)
        }
        let latency = Int(Date.now.timeIntervalSince(started) * 1000)
        if probe.kind == .health {
            let ok = response.status == probe.expectedStatus
            let problem = ok ? nil : (HTTPFailure.problem(status: response.status, headers: response.headers)?.0 ?? .unavailable)
            return ProbeOutcome(sample: HealthSample(at: started, ok: ok, latencyMS: latency, statusCode: response.status, problem: problem),
                                deployment: nil, detail: ok ? "HTTP \(response.status) in \(latency) ms" : "Expected \(probe.expectedStatus), got \(response.status)")
        }
        if let (problem, detail, _) = HTTPFailure.problem(status: response.status, headers: response.headers) {
            return failed(problem, detail, status: response.status)
        }
        if probe.kind == .release {
            guard (200..<300).contains(response.status) else {
                return failed(.unavailable, "Expected HTTP 200, got \(response.status).", status: response.status)
            }
            let found = ReleaseMarker.read(body: response.body, headers: response.headers)
            var observation = DeploymentObservation()
            observation.sha = found.sha
            observation.version = found.version
            observation.deployedAt = found.deployedAt
            observation.health = .healthy
            let hasRelease = found.sha != nil || found.version != nil
            observation.provenance = Provenance(observedAt: started, source: .runtimeProbe, level: hasRelease ? .verified : .unknown, ttl: ttl)
            if !hasRelease {
                observation.problem = .malformed
                observation.detail = "The URL answered but names no commit or version. Serve forgedeck-release.json, or send an X-Release header."
            }
            return ProbeOutcome(sample: HealthSample(at: started, ok: true, latencyMS: latency, statusCode: response.status, problem: nil),
                                deployment: observation,
                                detail: hasRelease ? "Release \(found.version ?? String(found.sha?.prefix(7) ?? "")) in \(latency) ms" : "Answered in \(latency) ms, no release named")
        }
        guard let status = try? JSONDecoder().decode(CompanionStatus.self, from: response.body) else {
            return failed(.malformed, "The response does not follow the status contract.", status: response.status)
        }
        guard status.schema_version.split(separator: ".").first.map(String.init) == Self.supportedSchemaMajor else {
            return failed(.unsupported, "Status schema \(status.schema_version) is not supported.", status: response.status)
        }
        // The target says which environment it is. A staging build answering on the
        // production URL must not be recorded as production.
        if let declared = status.environment?.lowercased(), declared != expectedTier.rawValue,
           !(expectedTier == .development && ["local", "dev"].contains(declared)) {
            return failed(.malformed, "The endpoint reports environment \"\(declared)\", expected \(expectedTier.rawValue).", status: response.status)
        }
        if let expected = probe.expectedProductID, !expected.isEmpty, let declared = status.product_id, declared != expected {
            return failed(.malformed, "The endpoint reports product \"\(declared)\", expected \(expected).", status: response.status)
        }
        let health = HealthState(rawValue: status.health?.state.lowercased() ?? "") ?? .unknown
        var observation = DeploymentObservation()
        observation.sha = status.release?.commit_sha.flatMap { GitService.isRevision($0) ? $0.lowercased() : nil }
        observation.version = status.release?.version
        observation.deployedAt = FlexibleDate.parse(status.release?.deployed_at)
        observation.health = health
        observation.instanceSHAs = (status.instances ?? []).compactMap(\.commit_sha).filter(GitService.isRevision)
        // Without a commit or a version there is nothing to verify.
        let hasRelease = observation.sha != nil || observation.version != nil
        observation.provenance = Provenance(observedAt: started, source: .runtimeProbe, level: hasRelease ? .verified : .unknown, ttl: ttl)
        if !hasRelease {
            observation.problem = .malformed
            observation.detail = "The endpoint answered without a commit or version."
        } else if observation.isMixed {
            observation.detail = "Instances report \(Set(observation.instanceSHAs).count) different revisions."
        }
        let failing = (status.health?.checks ?? []).filter { $0.state.lowercased() != "healthy" }.map(\.id)
        let ok = health == .healthy || health == .degraded
        let detail = failing.isEmpty ? "\(health.title) in \(latency) ms" : "\(health.title): \(failing.joined(separator: ", "))"
        return ProbeOutcome(sample: HealthSample(at: started, ok: ok, latencyMS: latency, statusCode: response.status, problem: ok ? nil : .unavailable),
                            deployment: observation, detail: detail)
    }
}

/// The versioned companion metrics and events contract.
public struct CompanionMetricsConnector: MetricProvider {
    public static let provider = ProviderKind.companion
    public static let capabilities: [ConnectorCapability] = [.metrics, .leadEvents]
    public static let windows = ["24h", "7d", "30d", "90d"]
    public static let basePath = "/_forgedeck/v1"

    public let http: any HTTPClient
    public let ttl: TimeInterval

    public init(http: any HTTPClient = URLSessionHTTPClient(timeout: 10), ttl: TimeInterval = 900) {
        self.http = http
        self.ttl = ttl
    }

    private func get(_ source: MetricSource, path: String, query: [String: String], bearer: String?) async -> ConnectorResult<Data> {
        let base: URL
        do { base = try URLPolicy.validate(source.baseURL) } catch { return .failure(.notConfigured, String(describing: error)) }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return .failure(.notConfigured, "Bad URL") }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        // A base that already names the contract root is used as it is.
        components.path = (basePath.hasSuffix("/v1") ? basePath : basePath + Self.basePath) + path
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return .failure(.notConfigured, "Bad URL") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Brand.name, forHTTPHeaderField: "User-Agent")
        if let bearer, !bearer.isEmpty { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        do {
            let response = try await http.send(request)
            if let (problem, detail, retry) = HTTPFailure.problem(status: response.status, headers: response.headers) {
                return .failure(problem, detail: detail, retryAfter: retry)
            }
            return .success(response.body)
        } catch {
            let (problem, detail) = HTTPFailure.problem(for: error)
            return .failure(problem, detail)
        }
    }

    private struct MetricsBody: Decodable {
        var schema_version: String
        var observed_at: String?
        var window: String?
        var source: String?
        var metrics: [String: Double]
    }

    public func metrics(_ source: MetricSource, productID: UUID, window: String, bearer: String?) async -> ConnectorResult<[MetricSample]> {
        guard Self.windows.contains(window) else { return .failure(.unsupported, "Window \(window) is not part of the contract.") }
        switch await get(source, path: "/metrics", query: ["window": window], bearer: bearer) {
        case .success(let data), .partial(let data, _):
            guard let body = try? JSONDecoder().decode(MetricsBody.self, from: data) else {
                return .failure(.malformed, "The response does not follow the metrics contract.")
            }
            // The observation time is when this Mac received the answer. A wrong server clock
            // cannot make an old number look fresh.
            let provenance = Provenance(observedAt: .now, source: .metricsAPI, level: .reported, ttl: ttl)
            return .success(body.metrics.keys.sorted().map { key in
                var sample = MetricSample()
                sample.productID = productID
                sample.sourceID = source.id
                sample.key = key
                sample.window = body.window ?? window
                sample.value = body.metrics[key] ?? 0
                sample.sourceLabel = body.source ?? source.name
                sample.provenance = provenance
                return sample
            })
        case .failure(let problem, let detail, let retry):
            return .failure(problem, detail: detail, retryAfter: retry)
        }
    }

    private struct EventsBody: Decodable {
        struct Item: Decodable {
            var id: String
            var kind: String?
            var occurred_at: String?
            var source: String?
            var title: String?
            var value_cents: Int?
            var contact: String?
            /// The companion packages send an already-masked contact as `label`.
            var label: String?
        }

        var items: [Item]
        var next_cursor: String?
    }

    /// Reads lead events page by page. Events keep the source's ids, so reading the
    /// same page twice, or two sources, can never count one event twice.
    public func events(_ source: MetricSource, productID: UUID, bearer: String?, maxPages: Int = 5) async -> ConnectorResult<[LeadEvent]> {
        var all: [LeadEvent] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var skipped = 0
        for _ in 0..<max(1, maxPages) {
            if Task.isCancelled { return .failure(.cancelled, "Cancelled") }
            var query = ["limit": "100"]
            if let cursor { query["cursor"] = cursor }
            switch await get(source, path: "/leads", query: query, bearer: bearer) {
            case .success(let data), .partial(let data, _):
                guard let body = try? JSONDecoder().decode(EventsBody.self, from: data) else {
                    return all.isEmpty ? .failure(.malformed, "The response does not follow the events contract.")
                                       : .partial(all, missing: ["a malformed page"])
                }
                for item in body.items {
                    // An event without an id or a readable time cannot be deduplicated or placed.
                    guard !item.id.isEmpty, let occurred = FlexibleDate.parse(item.occurred_at) else { skipped += 1; continue }
                    var event = LeadEvent()
                    event.id = "\(source.id.uuidString):\(item.id)"
                    event.productID = productID
                    event.sourceID = source.id
                    event.kind = BusinessEventKind(rawValue: item.kind ?? "lead") ?? .custom
                    event.occurredAt = occurred
                    event.title = item.title ?? event.kind.title
                    event.sourceLabel = item.source ?? source.name
                    // Contact details are masked on arrival. The full value is never stored.
                    event.maskedContact = item.contact.map { $0.contains("@") ? Masking.email($0) : Masking.generic($0) } ?? item.label
                    event.valueCents = item.value_cents
                    all.append(event)
                }
                guard let next = body.next_cursor, !next.isEmpty, seenCursors.insert(next).inserted else {
                    return skipped == 0 ? .success(all) : .partial(all, missing: ["\(skipped) malformed events"])
                }
                cursor = next
            case .failure(let problem, let detail, let retry):
                return all.isEmpty ? .failure(problem, detail: detail, retryAfter: retry)
                                   : .partial(all, missing: ["later pages (\(problem.title))"])
            }
        }
        return skipped == 0 ? .success(all) : .partial(all, missing: ["\(skipped) malformed events"])
    }
}

public enum MetricMath {
    /// Counts events of one kind inside a window ending now. Events are unique by id,
    /// so merging several sources does not count one event twice.
    public static func count(_ events: [LeadEvent], kinds: Set<BusinessEventKind>, productID: UUID? = nil,
                             within: TimeInterval, now: Date = .now) -> Int {
        var seen = Set<String>()
        return events.filter { event in
            kinds.contains(event.kind) && (productID == nil || event.productID == productID)
                && event.occurredAt <= now && event.occurredAt > now.addingTimeInterval(-within)
                && seen.insert(event.id).inserted
        }.count
    }

    /// The change against the equally long period before. nil when the earlier period has no data:
    /// "no data" is not zero.
    public static func change(current: Double, previous: Double?) -> Double? {
        guard let previous, previous > 0 else { return nil }
        return (current - previous) / previous
    }

    /// Daily counts for the last `days` days in a calendar's time zone. Days before the
    /// first known event are nil (unknown), not zero.
    public static func dailyCounts(_ events: [LeadEvent], kinds: Set<BusinessEventKind>, productID: UUID? = nil, days: Int,
                                   now: Date = .now, calendar: Calendar = .current) -> [Double?] {
        let relevant = events.filter { kinds.contains($0.kind) && (productID == nil || $0.productID == productID) }
        guard let earliest = relevant.map(\.occurredAt).min() else { return Array(repeating: nil, count: days) }
        let today = calendar.startOfDay(for: now)
        var seen = Set<String>()
        var buckets: [Date: Double] = [:]
        for event in relevant where seen.insert(event.id).inserted {
            buckets[calendar.startOfDay(for: event.occurredAt), default: 0] += 1
        }
        return (0..<days).reversed().map { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            if day < calendar.startOfDay(for: earliest) { return nil }
            return buckets[day] ?? 0
        }
    }

    /// The freshest sample per key across sources: used for "reported by the source" tiles.
    public static func latest(_ samples: [MetricSample], productID: UUID? = nil, key: String, window: String) -> [MetricSample] {
        samples.filter { $0.key == key && $0.window == window && (productID == nil || $0.productID == productID) }
    }
}
