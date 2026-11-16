import Foundation
import Testing
@testable import ForgeDeckKit

// End-to-end walkthroughs from the build contract (section 15), against a real local
// companion server (Companions/node/example-server.js), real HTTP, and real Git repositories.
// Run with scripts/acceptance.sh, which sets FORGEDECK_ACCEPTANCE=1. They need `node`.

private let acceptanceEnabled = ProcessInfo.processInfo.environment["FORGEDECK_ACCEPTANCE"] == "1"

/// The example companion server, started on a free local port.
final class CompanionServer: @unchecked Sendable {
    let process = Process()
    let port: Int
    let token = "acceptance-token-0123456789"

    var base: String { "http://127.0.0.1:\(port)" }

    init(sha: String, environment: String) throws {
        guard let node = ExecutableLocator.find("node") else { throw ToolFailure(description: "node is not installed") }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Companions/node/example-server.js")
        port = Int.random(in: 20_000...40_000)
        process.executableURL = node
        process.arguments = [script.path, "--port", String(port), "--token", token, "--test-controls", "--quiet",
                             "--sha", sha, "--environment", environment, "--product-id", "acme"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func waitUntilReady() async throws {
        for _ in 0..<50 {
            var request = URLRequest(url: URL(string: "\(base)/_forgedeck/v1/status")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ToolFailure(description: "the companion server did not start")
    }

    func control(_ path: String) async throws {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolFailure(description: "test control \(path) failed") }
    }

    func stop() {
        guard process.isRunning else { return }
        // SIGKILL and a short poll: waitUntilExit can block a cooperative thread forever.
        kill(process.processIdentifier, SIGKILL)
        for _ in 0..<100 where process.isRunning { usleep(20_000) }
    }
}

/// One product with a production environment pointed at the companion server.
struct AcceptanceWorld {
    var portfolio = Portfolio()
    let secrets = MemorySecretStore()
    let reference = CredentialReference.keychain()
    let engine: RefreshEngine

    var product: Product { portfolio.products[0] }
    var production: ProductEnvironment { product.environment(tier: .production)! }
    var probe: ProbeConfig { production.probes[0] }
    var source: MetricSource { production.metricSources[0] }

    init(server: CompanionServer, checkoutPath: String? = nil) throws {
        var product = Product(name: "Acme")
        var environment = ProductEnvironment(name: "Production", tier: .production)
        var probe = ProbeConfig()
        probe.name = "Status endpoint"
        probe.kind = .companion
        probe.url = "\(server.base)/_forgedeck/v1/status"
        probe.bearerVariableKey = "COMPANION_TOKEN"
        probe.expectedProductID = "acme"
        var source = MetricSource()
        source.name = "App metrics"
        source.baseURL = server.base
        source.bearerVariableKey = "COMPANION_TOKEN"
        environment.probes = [probe]
        environment.metricSources = [source]
        product.environments = [environment]
        var repository = Repository()
        repository.owner = "acme"
        repository.name = "widget"
        product.repositories = [repository]
        if let checkoutPath {
            var checkout = LocalCheckout()
            checkout.name = "widget"
            checkout.path = checkoutPath
            checkout.repositoryID = repository.id
            product.checkouts = [checkout]
        }
        portfolio.products = [product]
        var variable = VariableDefinition()
        variable.key = "COMPANION_TOKEN"
        variable.scope = .environment(product: product.id, environment: environment.id)
        variable.isSecret = true
        variable.allowedTiers = [.production]
        variable.credential = reference
        portfolio.variables = [variable]
        try secrets.write(server.token, locator: reference.locator)
        engine = RefreshEngine(http: URLSessionHTTPClient(timeout: 5), credentials: CredentialResolver(keychain: secrets), ttl: 900)
    }

    func sample(_ key: String, in cache: ObservationCache) -> MetricSample? {
        cache.metrics.first { $0.key == key && $0.window == "24h" }
    }
}

@Suite(.enabled(if: acceptanceEnabled), .serialized) struct AcceptanceWalkthroughs {
    private static let shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    /// Walkthrough 8: 12 leads and 9 signups, then one more event, then the API goes away.
    @Test func leadsAreCountedOnceAndGoStaleNotZero() async throws {
        let server = try CompanionServer(sha: Self.shaA, environment: "production")
        defer { server.stop() }
        try await server.waitUntilReady()
        let world = try AcceptanceWorld(server: server)
        var cache = ObservationCache()

        cache.apply(await world.engine.refreshMetrics(world.product, portfolio: world.portfolio), portfolio: world.portfolio)
        #expect(world.sample("leads", in: cache)?.value == 12)
        #expect(world.sample("signups", in: cache)?.value == 9)
        #expect(world.sample("leads", in: cache)?.sourceLabel == "example-in-memory")
        #expect(world.sample("leads", in: cache)?.provenance.effectiveLevel() == .reported)
        let imported = cache.leads.count
        #expect(imported > 0)
        // History arrives quietly on the first sync.
        #expect(cache.activity.isEmpty)

        let leadsBefore = MetricMath.count(cache.leads, kinds: [.lead], within: 86_400)
        try await server.control("/__test/add-lead")
        cache.apply(await world.engine.refreshMetrics(world.product, portfolio: world.portfolio), portfolio: world.portfolio)
        #expect(world.sample("leads", in: cache)?.value == 13)
        #expect(cache.leads.count == imported + 1)
        #expect(cache.activity.filter { $0.kind == .lead }.count == 1)
        #expect(MetricMath.count(cache.leads, kinds: [.lead], within: 86_400) == leadsBefore + 1)

        // Reading the same pages again changes nothing.
        cache.apply(await world.engine.refreshMetrics(world.product, portfolio: world.portfolio), portfolio: world.portfolio)
        #expect(cache.leads.count == imported + 1)
        #expect(cache.activity.filter { $0.kind == .lead }.count == 1)
        #expect(Set(cache.leads.map(\.id)).count == cache.leads.count)

        // Connectivity removed: the number stays, with its age, and is Stale. It never becomes 0.
        server.stop()
        let later = Date.now.addingTimeInterval(3_600)
        cache.apply(await world.engine.refreshMetrics(world.product, portfolio: world.portfolio), portfolio: world.portfolio, now: later)
        #expect(world.sample("leads", in: cache)?.value == 13)
        #expect(world.sample("leads", in: cache)?.provenance.effectiveLevel(now: later) == .stale)
        #expect(cache.sync["metrics:\(world.source.id.uuidString)"]?.lastProblem != nil)
        #expect(cache.sync["metrics:\(world.source.id.uuidString)"]?.lastSuccess != nil)
    }

    /// Walkthrough 10: three failures in a row, then recovery: one alert and one recovery.
    @Test func threeFailuresMakeOneAlertAndOneRecovery() async throws {
        let server = try CompanionServer(sha: Self.shaA, environment: "production")
        defer { server.stop() }
        try await server.waitUntilReady()
        let world = try AcceptanceWorld(server: server)
        var cache = ObservationCache()
        func check() async { cache.apply(await world.engine.refreshProbes(world.product, portfolio: world.portfolio), portfolio: world.portfolio) }
        func open() -> Int { cache.incidents.filter { $0.rule == .healthFailing && $0.isOpen }.count }

        await check()
        #expect(open() == 0)
        try await server.control("/__test/health?state=unhealthy")
        await check()
        await check()
        #expect(open() == 0)
        await check()
        #expect(open() == 1)
        await check()
        await check()
        #expect(open() == 1)
        #expect(cache.incidents.filter { $0.rule == .healthFailing }.count == 1)
        #expect(cache.activity.filter { $0.kind == .alert }.count == 1)
        #expect(ProductStatus.badge(world.product, cache: cache).label == "Unhealthy")

        try await server.control("/__test/health?state=healthy")
        await check()
        await check()
        #expect(open() == 0)
        #expect(cache.activity.filter { $0.kind == .alert }.count == 1)
        #expect(cache.activity.filter { $0.kind == .recovery }.count == 1)
        #expect(ProductStatus.badge(world.product, cache: cache).label == "Healthy")
    }

    /// Walkthroughs 5 and 6: production on A, GitHub main on B, local on C with uncommitted work.
    /// Then the production token is removed.
    @Test func localGitHubAndProductionStayDistinct() async throws {
        let directory = try makeTempDir("acceptance repo with spaces")
        defer { removeTemp(directory) }
        let repo = try TestRepo.create(at: directory)
        let a = try repo.commit(file: "a.txt", content: "a", message: "A: what production runs")
        let b = try repo.commit(file: "b.txt", content: "b", message: "B: what GitHub main has")
        let c = try repo.commit(file: "c.txt", content: "c", message: "C: local only")
        try write("not committed", to: directory.appending(path: "wip.txt"))

        let server = try CompanionServer(sha: a, environment: "production")
        defer { server.stop() }
        try await server.waitUntilReady()
        var world = try AcceptanceWorld(server: server, checkoutPath: directory.path)

        let github = MockHTTPClient()
        github.on("/repos/acme/widget", json: #"{"default_branch":"main"}"#)
        github.on("/repos/acme/widget/branches/main", json: #"{"commit":{"sha":"\#(b)","commit":{"message":"B","committer":{"date":"2026-11-15T10:00:00Z"}}}}"#)
        github.on("/repos/acme/widget/pulls", json: "[]")
        github.on("/repos/acme/widget/actions/runs", json: #"{"workflow_runs":[{"id":1,"name":"CI","head_branch":"main","head_sha":"\#(b)","status":"completed","conclusion":"success","created_at":"2026-11-15T10:05:00Z"}]}"#)
        github.on("/repos/acme/widget/deployments", json: "[]")

        var cache = ObservationCache()
        cache.apply(await world.engine.refreshGit(world.product), portfolio: world.portfolio)
        cache.apply([.remote(repository: world.product.repositories[0].id, product: world.product.id,
                             await GitHubConnector(http: github).snapshot(owner: "acme", name: "widget"))], portfolio: world.portfolio)
        cache.apply(await world.engine.refreshProbes(world.product, portfolio: world.portfolio), portfolio: world.portfolio)
        cache.apply(await world.engine.refreshComparisons(world.product, cache: cache), portfolio: world.portfolio)

        let chain = DriftAnalyzer.chain(product: world.product, cache: cache)
        func node(_ stage: ChainNode.Stage) -> ChainNode { chain.first { $0.stage == stage }! }
        #expect(node(.local).sha == c)
        #expect(node(.local).isDirty)
        #expect(node(.local).sourceTitle == FactSource.localCheckout.title)
        #expect(node(.github).sha == b)
        #expect(node(.github).sourceTitle == FactSource.githubAPI.title)
        #expect(node(.production).sha == a)
        #expect(node(.production).level == .verified)
        #expect(node(.production).sourceTitle == FactSource.runtimeProbe.title)
        #expect(node(.production).observedAt != nil)
        #expect(Set([a, b, c]).count == 3)
        // A green CI run on B did not move production off A.
        #expect(cache.remotes.values.first?.defaultBranchRun?.succeeded == true)

        let relations = DriftAnalyzer.relations(product: world.product, cache: cache)
        #expect(relations.first { $0.from == .local && $0.to == .github }?.comparison == .ahead(1))
        #expect(relations.first { $0.from == .github && $0.to == .production }?.comparison == .ahead(1))

        // Walkthrough 6: the token is gone. Production is no longer verified, and says why.
        world.portfolio.variables = []
        let later = Date.now.addingTimeInterval(60)
        cache.apply(await world.engine.refreshProbes(world.product, portfolio: world.portfolio), portfolio: world.portfolio, now: later)
        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: later)
        #expect(evidence.level == .stale)
        #expect(evidence.problem == .unauthorized)

        // With no earlier observation at all: Unknown, authentication required. Never "in sync".
        var empty = ObservationCache()
        empty.apply(await world.engine.refreshProbes(world.product, portfolio: world.portfolio), portfolio: world.portfolio)
        let unknown = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: empty)
        #expect(unknown.level == .unknown)
        #expect(unknown.observation == nil)
        #expect(unknown.problem == .unauthorized)
        let cells = ProductStatus.cells(world.product, cache: empty)
        #expect(cells.first { $0.title == "Production" }?.value == ObservationProblem.unauthorized.title)
        #expect(ProductStatus.badge(world.product, cache: empty).label != "Healthy")
        #expect(DriftAnalyzer.relations(product: world.product, cache: empty).allSatisfy { $0.comparison != .same })
    }

    /// Walkthrough 7, last part: rotating a token changes what the dependent connection reports.
    @Test func rotatingATokenChangesTheConnection() async throws {
        let server = try CompanionServer(sha: Self.shaA, environment: "production")
        defer { server.stop() }
        try await server.waitUntilReady()
        let world = try AcceptanceWorld(server: server)
        func level() async -> (EvidenceLevel, ObservationProblem?) {
            var cache = ObservationCache()
            cache.apply(await world.engine.refreshProbes(world.product, portfolio: world.portfolio), portfolio: world.portfolio)
            let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache)
            return (evidence.level, evidence.problem)
        }
        let before = await level()
        #expect(before.0 == .verified && before.1 == nil)
        try world.secrets.write("rotated-to-a-value-the-server-does-not-know", locator: world.reference.locator)
        let rotated = await level()
        #expect(rotated.0 == .unknown && rotated.1 == .unauthorized)
        try world.secrets.write(server.token, locator: world.reference.locator)
        let restored = await level()
        #expect(restored.0 == .verified && restored.1 == nil)
    }

    /// Walkthrough 1 and the staging-environment guard: a staging build on the production URL is not production.
    @Test func aStagingBuildIsNotRecordedAsProduction() async throws {
        let server = try CompanionServer(sha: Self.shaA, environment: "staging")
        defer { server.stop() }
        try await server.waitUntilReady()
        let world = try AcceptanceWorld(server: server)
        var cache = ObservationCache()
        cache.apply(await world.engine.refreshProbes(world.product, portfolio: world.portfolio), portfolio: world.portfolio)
        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache)
        #expect(evidence.observation == nil)
        #expect(evidence.level == .unknown)
    }
}

/// Reads one public repository from the real GitHub API, without a token.
/// Run with FORGEDECK_LIVE_GITHUB=1. Read-only, one small set of requests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FORGEDECK_LIVE_GITHUB"] == "1")) struct LiveGitHub {
    @Test func aPublicRepositoryReportsItsDefaultBranchHead() async {
        let result = await GitHubConnector().snapshot(owner: "apple", name: "swift-argument-parser")
        switch result {
        case .success(let snapshot), .partial(let snapshot, _):
            #expect(snapshot.defaultBranch == "main")
            #expect(GitService.isRevision(snapshot.headSHA ?? ""))
            #expect(snapshot.provenance.source == .githubAPI)
        case .failure(let problem, let detail, _):
            // The anonymous rate limit is a real, typed outcome, not a crash.
            #expect(problem == .rateLimited, "\(problem): \(detail)")
        }
    }
}

/// Discovery over many repositories stays fast and bounded.
@Suite struct DiscoveryPerformance {
    @Test func threeHundredRepositoriesScanQuickly() async throws {
        let root = try makeTempDir("many")
        defer { removeTemp(root) }
        for index in 0..<300 {
            let project = root.appending(path: "group\(index % 10)/project\(index)")
            try FileManager.default.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
            try write("[remote \"origin\"]\n\turl = git@github.com:acme/project\(index).git\n", to: project.appending(path: ".git/config"))
            try write("{\"dependencies\":{\"next\":\"1\"}}", to: project.appending(path: "package.json"))
            try FileManager.default.createDirectory(at: project.appending(path: "node_modules/big/deep"), withIntermediateDirectories: true)
        }
        let started = Date.now
        let result = await ProjectDiscovery().scan(root: root)
        let elapsed = Date.now.timeIntervalSince(started)
        #expect(result.projects.count == 300)
        #expect(!result.hitLimit)
        #expect(elapsed < 5, "scan took \(elapsed) s")
        let planning = Date.now
        let proposals = ImportPlanner.plan(result.projects, portfolio: Portfolio())
        #expect(proposals.count == 300)
        #expect(Date.now.timeIntervalSince(planning) < 2)
    }
}
