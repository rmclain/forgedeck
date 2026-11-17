import Foundation

// Sample products for first run, screenshots, and tests. Everything made here is
// marked `isDemo` and its evidence source is `.fixture`, so the app labels it Demo
// and never refreshes it against a real system. The names are invented.

public enum DemoFixtures {
    struct Spec {
        var id: String
        var name: String
        var group: String
        var tagline: String
        var monogram: String
        var hue: Double
        var stack: [String]
        var version: String
        var next: String
        var deployedHoursAgo: Double
        var git: (branch: String, staged: Int, unstaged: Int, ahead: Int, behind: Int)
        var openPR: Int?
        var ciFailing = false
        var health: HealthState = .healthy
        var productionLevel: EvidenceLevel? = .verified
        var drift: Int?
        var mrrCents: Int?
        var leadsPerDay: Double = 0
        var components: [(String, ComponentKind)] = []
        var hasProduction = true
    }

    static let specs: [Spec] = [
        Spec(id: "lumen", name: "Lumen", group: "SaaS Products", tagline: "Product analytics for indie SaaS", monogram: "Lu", hue: 205,
             stack: ["Next.js", "Postgres", "Vercel"], version: "v2.14.0", next: "v2.15.0-rc.2", deployedHoursAgo: 0.3,
             git: ("main", 0, 0, 0, 0), mrrCents: 1_842_000, leadsPerDay: 5,
             components: [("Web app", .frontend), ("API", .backend), ("Ingest worker", .worker), ("Marketing site", .site)]),
        Spec(id: "parcelwise", name: "Parcelwise", group: "SaaS Products", tagline: "Shipping rates and labels API", monogram: "Pw", hue: 55,
             stack: ["Go", "Redis", "Fly.io"], version: "v1.31.2", next: "v1.32.0", deployedHoursAgo: 3,
             git: ("main", 0, 0, 3, 0), openPR: 212, productionLevel: .reported, mrrCents: 920_400, leadsPerDay: 3,
             components: [("API", .backend), ("Dashboard", .frontend)]),
        Spec(id: "quillnote", name: "Quillnote", group: "SaaS Products", tagline: "Collaborative notes for small teams", monogram: "Qn", hue: 285,
             stack: ["SvelteKit", "Supabase", "Cloudflare"], version: "v0.42.1", next: "v0.42.2", deployedHoursAgo: 26,
             git: ("main", 0, 0, 0, 0), health: .degraded, mrrCents: 611_800, leadsPerDay: 2,
             components: [("Web app", .frontend), ("Sync API", .backend), ("iOS app", .mobile)]),
        Spec(id: "beacon", name: "Beacon", group: "SaaS Products", tagline: "Status pages for engineering teams", monogram: "Bc", hue: 155,
             stack: ["Rails", "Sidekiq", "Hetzner"], version: "v3.8.0", next: "v3.9.0", deployedHoursAgo: 50,
             git: ("main", 1, 1, 0, 0), drift: 6, mrrCents: 469_000, leadsPerDay: 1.5,
             components: [("App", .backend), ("Workers", .worker)]),
        Spec(id: "ledgerly", name: "Ledgerly", group: "Client Work", tagline: "Invoicing portal for a client", monogram: "Lg", hue: 250,
             stack: ["Django", "Celery", "AWS"], version: "v5.2.0", next: "v5.2.1", deployedHoursAgo: 96,
             git: ("main", 0, 0, 0, 2), productionLevel: .stale, components: [("Portal", .backend)]),
        Spec(id: "orbit-crm", name: "Orbit CRM", group: "Client Work", tagline: "Lightweight CRM for a design studio", monogram: "Or", hue: 15,
             stack: ["Remix", "Prisma", "Railway"], version: "v1.9.4", next: "v1.10.0", deployedHoursAgo: 144,
             git: ("feat/import", 0, 0, 2, 0), ciFailing: true, productionLevel: nil, components: [("App", .frontend)]),
        Spec(id: "forge-cli", name: "forge-cli", group: "Internal", tagline: "Deploy scripts and release tooling", monogram: "fc", hue: 260,
             stack: ["Rust", "GitHub Actions"], version: "v0.9.3", next: "v0.10.0", deployedHoursAgo: 168,
             git: ("main", 0, 0, 0, 0), components: [("CLI", .cli)], hasProduction: false),
        Spec(id: "northwind-site", name: "northwind.example", group: "Internal", tagline: "Company site and changelog", monogram: "nw", hue: 185,
             stack: ["Astro", "Cloudflare Pages"], version: "a41f9c2", next: "main", deployedHoursAgo: 5,
             git: ("main", 0, 0, 0, 0), components: [("Site", .site)]),
    ]

    /// A stable UUID from text, so adding the demo twice makes the same ids.
    static func uuid(_ text: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for round in 0..<2 {
            for byte in "\(round):forgedeck-demo:\(text)".utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            for i in 0..<8 { bytes[round * 8 + i] = UInt8((hash >> (UInt64(i) * 8)) & 0xFF) }
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func sha(_ text: String) -> String {
        var out = ""
        var hash: UInt64 = 1_469_598_103_934_665_603
        while out.count < 40 {
            for byte in "\(out.count)\(text)".utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            out += String(hash, radix: 16)
        }
        return String(out.prefix(40))
    }

    /// A small deterministic generator: the demo looks the same on every launch.
    struct Generator {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 10_000) / 10_000
        }
    }

    public static func products(count: Int = 8) -> [Product] {
        specs.prefix(count).map { spec in
            var product = Product(name: spec.name, group: spec.group)
            product.id = uuid(spec.id)
            product.slug = spec.id
            product.tagline = spec.tagline
            product.monogram = spec.monogram
            product.hue = spec.hue
            product.stack = spec.stack
            product.isDemo = true
            product.isFavorite = ["lumen", "beacon"].contains(spec.id)
            if spec.id == "lumen" {
                product.agentSkills = [AgentSkill(id: "demo-release-notes", repo: "example/demo-skills", why: "Writes release notes from merged pull requests.")]
                product.issues = DemoFixtures.issues()
            }
            product.lifecycle = spec.id == "ledgerly" ? .maintenance : .active
            product.tags = [spec.group == "Client Work" ? "client" : spec.group == "Internal" ? "internal" : "saas"]
            product.links = [ProductLink(label: "Site", url: "https://\(spec.id).example", kind: .site),
                             ProductLink(label: "Admin", url: "https://admin.\(spec.id).example", kind: .dashboard)]
            product.components = spec.components.map { name, kind in
                with(Component(name: name, kind: kind)) { $0.id = uuid("\(spec.id)-component-\(name)") }
            }
            var repo = Repository()
            repo.id = uuid("\(spec.id)-repo")
            repo.owner = "northwind-demo"
            repo.name = spec.id
            repo.webURL = "https://github.com/northwind-demo/\(spec.id)"
            repo.cloneURL = "git@github.com:northwind-demo/\(spec.id).git"
            repo.componentID = product.components.first?.id
            product.repositories = [repo]
            var checkout = LocalCheckout()
            checkout.id = uuid("\(spec.id)-checkout")
            checkout.name = spec.id
            checkout.path = "~/code/\(spec.id)"
            checkout.repositoryID = repo.id
            checkout.componentID = product.components.first?.id
            product.checkouts = [checkout]
            var local = ProductEnvironment(name: "Local", tier: .development)
            local.id = uuid("\(spec.id)-env-local")
            local.domains = ["localhost:3000"]
            var staging = ProductEnvironment(name: "Staging", tier: .staging)
            staging.id = uuid("\(spec.id)-env-staging")
            staging.domains = ["staging.\(spec.id).example"]
            product.environments = [local, staging]
            if spec.hasProduction {
                var production = ProductEnvironment(name: "Production", tier: .production)
                production.id = uuid("\(spec.id)-env-production")
                production.domains = ["\(spec.id).example"]
                var probe = ProbeConfig()
                probe.id = uuid("\(spec.id)-probe")
                probe.name = "Status endpoint"
                probe.kind = .companion
                probe.url = "https://\(spec.id).example/_forgedeck/v1/status"
                production.probes = [probe]
                var host = SSHHostConfig()
                host.id = uuid("\(spec.id)-host")
                host.alias = "\(spec.id)-prod-1"
                host.label = "Primary"
                production.sshHosts = [host]
                product.environments.append(production)
            }
            return product
        }
    }

    public static func cache(for products: [Product], now: Date = .now) -> ObservationCache {
        var cache = ObservationCache()
        for product in products {
            guard let spec = specs.first(where: { $0.id == product.slug }) else { continue }
            var random = Generator(state: UInt64(abs(spec.id.hashValue % 1_000)) &+ UInt64(spec.hue * 1_000))
            random.state = UInt64(spec.hue * 7_919) &+ UInt64(spec.id.utf8.reduce(0) { $0 &+ Int($1) })
            let fresh = Provenance(observedAt: now.addingTimeInterval(-120), source: .fixture, level: .verified, ttl: 86_400 * 365, isDemo: true)
            let headSHA = sha("\(spec.id)-head")
            let productionSHA = sha("\(spec.id)-prod")
            let stagingSHA = spec.drift == nil && spec.id != "lumen" ? productionSHA : sha("\(spec.id)-staging")

            if let checkout = product.checkouts.first {
                var git = GitSnapshot()
                git.branch = spec.git.branch
                git.headSHA = spec.git.ahead > 0 ? sha("\(spec.id)-local") : headSHA
                git.staged = spec.git.staged
                git.unstaged = spec.git.unstaged
                git.ahead = spec.git.ahead
                git.behind = spec.git.behind
                git.upstream = "origin/\(spec.git.branch)"
                git.remotes = ["origin": product.repositories.first?.cloneURL ?? ""]
                git.lastFetch = now.addingTimeInterval(-120)
                git.observedAt = now.addingTimeInterval(-120)
                git.recentCommits = [
                    CommitSummary(sha: git.headSHA ?? headSHA, subject: "Fix timezone drift in retention chart", author: "You", date: now.addingTimeInterval(-3_600 * 5)),
                    CommitSummary(sha: sha("\(spec.id)-c2"), subject: "Batch event ingestion", author: "Theo Park", date: now.addingTimeInterval(-3_600 * 28)),
                    CommitSummary(sha: sha("\(spec.id)-c3"), subject: "Upgrade database driver", author: "Maya Chen", date: now.addingTimeInterval(-3_600 * 70)),
                ]
                cache.git[checkout.id] = git
                if spec.git.ahead > 0 { cache.comparisons[DriftAnalyzer.comparisonKey(git.headSHA ?? "", headSHA)] = .ahead(spec.git.ahead) }
                if spec.git.behind > 0 {
                    git.headSHA = sha("\(spec.id)-local")
                    cache.git[checkout.id] = git
                    cache.comparisons[DriftAnalyzer.comparisonKey(git.headSHA ?? "", headSHA)] = .behind(spec.git.behind)
                }
            }
            if let repo = product.repositories.first {
                var remote = RemoteSnapshot()
                remote.headSHA = headSHA
                remote.headMessage = "Fix timezone drift in retention chart"
                remote.headDate = now.addingTimeInterval(-3_600 * 5)
                remote.provenance = fresh
                if let number = spec.openPR {
                    var pr = PullRequestSummary()
                    pr.number = number
                    pr.title = "Rate shopping for multi-parcel shipments"
                    pr.author = "maya"
                    pr.updatedAt = now.addingTimeInterval(-3_600 * 2)
                    remote.pullRequests = [pr]
                }
                var run = WorkflowRunSummary()
                run.id = Int(spec.hue * 1_000)
                run.name = "CI"
                run.branch = "main"
                run.headSHA = headSHA
                run.status = "completed"
                run.conclusion = spec.ciFailing ? "failure" : "success"
                run.createdAt = now.addingTimeInterval(-3_600 * (spec.ciFailing ? 1 : 5))
                remote.runs = [run]
                remote.latestReleaseTag = spec.version
                cache.remotes[repo.id] = remote
                if headSHA != productionSHA { cache.comparisons[DriftAnalyzer.comparisonKey(headSHA, productionSHA)] = .ahead(spec.drift ?? 14) }
            }
            if let staging = product.environment(tier: .staging) {
                var observation = DeploymentObservation()
                observation.id = uuid("\(spec.id)-obs-staging")
                observation.productID = product.id
                observation.environmentID = staging.id
                observation.sha = stagingSHA
                observation.version = stagingSHA == productionSHA ? spec.version : spec.next
                observation.deployedAt = now.addingTimeInterval(-7_200)
                observation.health = .healthy
                observation.provenance = fresh
                cache.deployments.append(observation)
                if stagingSHA != productionSHA {
                    cache.comparisons[DriftAnalyzer.comparisonKey(stagingSHA, productionSHA)] = .ahead(spec.drift ?? 14)
                }
            }
            if let production = product.environment(tier: .production) {
                var observation = DeploymentObservation()
                observation.id = uuid("\(spec.id)-obs-production")
                observation.productID = product.id
                observation.environmentID = production.id
                observation.sha = productionSHA
                observation.version = spec.version
                observation.deployedAt = now.addingTimeInterval(-spec.deployedHoursAgo * 3_600)
                observation.health = spec.health
                switch spec.productionLevel {
                case .verified?:
                    observation.provenance = fresh
                    cache.deployments.append(observation)
                case .reported?:
                    observation.provenance = Provenance(observedAt: now.addingTimeInterval(-600), source: .fixture, level: .reported, ttl: 86_400 * 365, isDemo: true)
                    observation.deployState = "success"
                    observation.health = .unknown
                    observation.detail = "Reported by a deployment record. No status endpoint is connected."
                    cache.deployments.append(observation)
                case .stale?:
                    observation.provenance = Provenance(observedAt: now.addingTimeInterval(-86_400 * 3), source: .fixture, level: .verified, ttl: 900, isDemo: true)
                    cache.deployments.append(observation)
                default:
                    var failure = DeploymentObservation()
                    failure.id = uuid("\(spec.id)-obs-production-failure")
                    failure.productID = product.id
                    failure.environmentID = production.id
                    failure.problem = .unauthorized
                    failure.detail = "The status endpoint rejected the token."
                    failure.provenance = Provenance(observedAt: now.addingTimeInterval(-300), source: .fixture, level: .unknown, isDemo: true)
                    cache.deployments.append(failure)
                }
                // Earlier releases, so the deployment history has something to show.
                for (index, version) in previousVersions(spec.version).enumerated() {
                    var old = DeploymentObservation()
                    old.id = uuid("\(spec.id)-obs-old-\(index)")
                    old.productID = product.id
                    old.environmentID = production.id
                    old.sha = sha("\(spec.id)-old-\(index)")
                    old.version = version
                    old.deployedAt = now.addingTimeInterval(-86_400 * Double(index + 1) - spec.deployedHoursAgo * 3_600)
                    old.health = .healthy
                    old.provenance = Provenance(observedAt: old.deployedAt ?? now, source: .fixture, level: .verified, ttl: 60, isDemo: true)
                    cache.deployments.insert(old, at: 0)
                }
                if let probe = production.probes.first, spec.productionLevel != nil {
                    cache.health[probe.id] = (0..<30).map { index in
                        let at = now.addingTimeInterval(-Double(30 - index) * 300)
                        let slow = spec.health == .degraded && index > 20
                        let failed = spec.health == .degraded && index == 23
                        return HealthSample(at: at, ok: !failed, latencyMS: slow ? 900 + Int(random.next() * 900) : 40 + Int(random.next() * 90),
                                            statusCode: failed ? 503 : 200, problem: failed ? .unavailable : nil)
                    }
                }
            }
            let sourceID = uuid("\(spec.id)-metrics")
            if let cents = spec.mrrCents {
                for (key, value, window) in [("mrr_cents", Double(cents), "30d"), ("leads", (spec.leadsPerDay * 1).rounded(), "24h"),
                                             ("signups", (spec.leadsPerDay * 0.7).rounded(), "24h")] {
                    var sample = MetricSample()
                    sample.productID = product.id
                    sample.sourceID = sourceID
                    sample.key = key
                    sample.window = window
                    sample.value = value
                    sample.sourceLabel = "Demo fixture"
                    sample.provenance = Provenance(observedAt: now.addingTimeInterval(-120), source: .fixture, level: .reported, ttl: 86_400 * 365, isDemo: true)
                    cache.metrics.append(sample)
                }
                for day in 0..<30 {
                    let growth = 1 - Double(day) * 0.006
                    cache.points.append(MetricPoint(productID: product.id, key: "mrr_cents",
                                                    day: Calendar.current.startOfDay(for: now.addingTimeInterval(-86_400 * Double(day))),
                                                    value: Double(cents) * growth))
                }
            }
            if spec.leadsPerDay > 0 {
                let titles: [(BusinessEventKind, String, Int?)] = [(.lead, "Demo requested", nil), (.signup, "Trial started", nil), (.signup, "Signed up", nil),
                                                                   (.paidConversion, "New Pro subscription", 4_900), (.lead, "Contact form", nil),
                                                                   (.paidConversion, "Upgraded to Team", 19_900)]
                var index = 0
                for day in 0..<30 {
                    let count = Int((spec.leadsPerDay * (0.5 + random.next())).rounded())
                    for _ in 0..<count {
                        let pick = titles[Int(random.next() * Double(titles.count)) % titles.count]
                        var lead = LeadEvent()
                        lead.id = "\(sourceID.uuidString):demo-\(index)"
                        lead.productID = product.id
                        lead.sourceID = sourceID
                        lead.kind = pick.0
                        lead.title = pick.1
                        lead.valueCents = pick.2
                        lead.occurredAt = now.addingTimeInterval(-86_400 * Double(day) - random.next() * 80_000 - 60)
                        lead.sourceLabel = "Demo fixture"
                        lead.maskedContact = ["a***@b***.io", "s***@t***.co", "m***@f***.dev", "k***@r***.app"][index % 4]
                        lead.state = day > 1 ? .handled : (index % 3 == 0 ? .read : .new)
                        lead.isDemo = true
                        cache.leads.append(lead)
                        index += 1
                    }
                }
            }
        }
        cache.leads.sort { $0.occurredAt > $1.occurredAt }

        func product(_ slug: String) -> Product? { products.first { $0.slug == slug } }
        func event(_ id: String, _ kind: ActivityKind, _ slug: String, _ title: String, _ detail: String, minutes: Double) {
            guard let product = product(slug) else { return }
            cache.record(ActivityEvent(id: "demo:\(id)", kind: kind, productID: product.id, title: title, detail: detail,
                                       at: now.addingTimeInterval(-minutes * 60), sourceLabel: "Demo fixture", isDemo: true))
        }
        event("1", .purchase, "lumen", "New Pro subscription", "$49/mo", minutes: 1)
        event("2", .lead, "parcelwise", "Trial started", "Signup form", minutes: 3)
        event("3", .deploy, "lumen", "v2.14.0 live in Production", "Verified by the status endpoint", minutes: 18)
        event("4", .alert, "quillnote", "p95 latency 1.8 s on /api/sync", "Threshold 800 ms", minutes: 24)
        event("5", .lead, "beacon", "Demo requested", "40 seats", minutes: 33)
        event("6", .alert, "beacon", "Disk 86% on beacon-prod-2", "SSH probe", minutes: 41)
        event("7", .checkFailed, "orbit-crm", "CI failed on main", "TS2345 in routes/import.tsx", minutes: 62)
        event("8", .purchase, "quillnote", "Upgraded to Team", "$199/mo", minutes: 95)

        func incident(_ slug: String, _ rule: AlertRuleKind, _ title: String, _ detail: String, minutes: Double) {
            guard let product = product(slug) else { return }
            var incident = Incident()
            incident.id = uuid("\(slug)-incident-\(rule.rawValue)")
            incident.rule = rule
            incident.subject = "demo-\(slug)"
            incident.productID = product.id
            incident.title = title
            incident.detail = detail
            incident.openedAt = now.addingTimeInterval(-minutes * 60)
            incident.isDemo = true
            cache.incidents.append(incident)
        }
        incident("orbit-crm", .pipelineBroken, "CI is failing on main", "northwind-demo/orbit-crm · TS2345 in routes/import.tsx", minutes: 62)
        incident("orbit-crm", .authFailure, "Status endpoint rejected the token", "Production version is unknown until the token is replaced.", minutes: 300)
        incident("beacon", .productionDrift, "Production is 6 commits behind staging", "v3.9.0 is verified on Staging. Production runs v3.8.0.", minutes: 120)
        return cache
    }

    static func previousVersions(_ version: String) -> [String] {
        guard version.hasPrefix("v") else { return [] }
        let parts = version.dropFirst().split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return [] }
        return (1...3).compactMap { step in
            parts[1] - step >= 0 ? "v\(parts[0]).\(parts[1] - 1).\(max(0, 4 - step))" : nil
        }
    }

    /// Adds demo products that are not there yet, with their fixture observations.
    @discardableResult
    public static func install(count: Int = 3, into portfolio: inout Portfolio, cache: inout ObservationCache, now: Date = .now) -> Int {
        let wanted = products(count: count).filter { candidate in !portfolio.products.contains { $0.slug == candidate.slug || $0.id == candidate.id } }
        guard !wanted.isEmpty else { return 0 }
        portfolio.products += wanted
        let fixture = self.cache(for: wanted, now: now)
        cache.git.merge(fixture.git) { _, new in new }
        cache.remotes.merge(fixture.remotes) { _, new in new }
        cache.health.merge(fixture.health) { _, new in new }
        cache.comparisons.merge(fixture.comparisons) { _, new in new }
        cache.deployments += fixture.deployments
        cache.metrics += fixture.metrics
        cache.points += fixture.points
        cache.merge(leads: fixture.leads)
        for event in fixture.activity { cache.record(event) }
        cache.incidents += fixture.incidents
        return wanted.count
    }

    /// Removes every demo product and what was observed for it.
    public static func remove(from portfolio: inout Portfolio, cache: inout ObservationCache) {
        for product in portfolio.products where product.isDemo { cache.remove(product: product) }
        portfolio.products.removeAll(where: \.isDemo)
    }
}
