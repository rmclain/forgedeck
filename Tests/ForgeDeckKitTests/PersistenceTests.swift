import Foundation
import Testing
@testable import ForgeDeckKit

/// A portfolio document as schema version 1 wrote it: the last lifecycle stage is
/// "retired" and products have no `profiles` or `recipes`.
private let schemaV1Document = """
{
  "schemaVersion": 1,
  "organizations": [{"id": "0A0A0A0A-0000-4000-8000-000000000001", "name": "My Portfolio", "tags": []}],
  "products": [
    {
      "id": "11111111-1111-4111-8111-111111111111", "slug": "old-app", "name": "Old App", "tagline": "Legacy billing",
      "notes": "", "group": "Products", "tags": ["legacy"], "stack": ["PHP"], "links": [], "isFavorite": false,
      "lifecycle": "retired", "hue": 120, "monogram": "Oa", "createdAt": "2024-03-01T10:00:00Z", "isDemo": false,
      "components": [], "repositories": [], "checkouts": [], "environments": []
    },
    {
      "id": "22222222-2222-4222-8222-222222222222", "slug": "live-app", "name": "Live App", "tagline": "",
      "notes": "", "group": "Products", "tags": [], "stack": [], "links": [], "isFavorite": true,
      "lifecycle": "active", "hue": 200, "monogram": "La", "createdAt": "2024-05-01T10:00:00Z", "isDemo": false,
      "components": [], "repositories": [], "checkouts": [],
      "environments": [{"id": "33333333-3333-4333-8333-333333333333", "name": "Local", "tier": "development",
                        "domains": [], "probes": [], "sshHosts": [], "metricSources": []}]
    }
  ],
  "connections": [],
  "variables": [],
  "settings": {
    "preferredTerminalBundleID": "com.apple.Terminal", "preferredEditorBundleID": "com.microsoft.VSCode",
    "projectRoots": ["/Users/someone/code"], "pollingIntervalSeconds": 120, "pollingEnabled": true,
    "cacheRetentionDays": 30, "revealTimeoutSeconds": 30, "requireAuthForProductionSecrets": true,
    "showMenuBarExtra": true, "aiAgentProgram": "claude", "trustedExecutables": ["git"], "appearance": "dark"
  }
}
"""

@Suite struct PortfolioStoreTests {
    private func makeStore() throws -> (PortfolioStore, URL) {
        let directory = try makeTempDir("store")
        return (PortfolioStore(location: StoreLocation(directory: directory.appending(path: "data", directoryHint: .isDirectory))), directory)
    }

    @Test func missingFilesLoadAsEmpty() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        let portfolio = try store.loadPortfolio()
        #expect(portfolio.products.isEmpty)
        #expect(portfolio.schemaVersion == Portfolio.currentSchemaVersion)
        #expect(store.loadCache().deployments.isEmpty)
    }

    @Test func portfolioSaveAndLoadRoundTrip() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        let world = SecretWorld()
        try store.save(world.portfolio)
        let loaded = try store.loadPortfolio()
        #expect(loaded.products.map(\.id) == world.portfolio.products.map(\.id))
        #expect(loaded.products.map(\.slug) == world.portfolio.products.map(\.slug))
        #expect(loaded.products[0].profiles.map(\.name) == ["dev", "prod", "leaky"])
        #expect(loaded.products[0].profiles[0].variableAllowlist == ["API_TOKEN", "FEATURE_FLAG"])
        #expect(loaded.products[0].recipes == world.portfolio.products[0].recipes)
        #expect(loaded.products[0].environments == world.portfolio.products[0].environments)
        #expect(loaded.variables.map(\.key) == world.portfolio.variables.map(\.key))
        #expect(loaded.variables.map(\.scope) == world.portfolio.variables.map(\.scope))
        #expect(loaded.variables.map(\.credential?.locator) == world.portfolio.variables.map(\.credential?.locator))
        #expect(loaded.settings == world.portfolio.settings)
        // A second cycle writes the same bytes: nothing drifts between saves.
        let first = try Data(contentsOf: store.location.portfolioURL)
        try store.save(loaded)
        #expect(try Data(contentsOf: store.location.portfolioURL) == first)
    }

    @Test func filesArePrivateToTheUser() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        try store.save(Portfolio())
        try store.save(ObservationCache())
        let fm = FileManager.default
        #expect(try fm.attributesOfItem(atPath: store.location.portfolioURL.path)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.attributesOfItem(atPath: store.location.cacheURL.path)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.attributesOfItem(atPath: store.location.directory.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func cacheSaveAndLoadRoundTrip() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.git[world.checkout.id] = world.gitSnapshot(head: shaA, at: fixedNow)
        cache.remotes[world.repo.id] = world.remote(head: shaB, at: fixedNow, runs: [workflowRun(id: 1, sha: shaB, conclusion: "success", at: fixedNow)])
        cache.deployments = [world.observation(world.production, sha: shaC, version: "v1.2.3", at: fixedNow, instances: [shaC, shaD])]
        cache.health[world.productionProbe.id] = [HealthSample(at: fixedNow, ok: true, latencyMS: 42, statusCode: 200)]
        cache.comparisons = ["\(shaA)...\(shaB)": .diverged(ahead: 2, behind: 3), "x...y": .notEnoughHistory, "p...q": .behind(4)]
        var lead = LeadEvent()
        lead.id = "source:1"
        lead.occurredAt = fixedNow
        lead.receivedAt = fixedNow
        lead.maskedContact = "j***@e***.com"
        cache.leads = [lead]
        var state = SyncState()
        state.lastAttempt = fixedNow
        state.lastProblem = .rateLimited
        cache.sync["github:x"] = state
        try store.save(cache)

        let loaded = store.loadCache()
        #expect(loaded.git == cache.git)
        #expect(loaded.remotes == cache.remotes)
        #expect(loaded.deployments == cache.deployments)
        #expect(loaded.health == cache.health)
        #expect(loaded.comparisons == cache.comparisons)
        #expect(loaded.leads == cache.leads)
        #expect(loaded.sync == cache.sync)
    }

    @Test func schemaVersion1MigratesToCurrent() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        try write(schemaV1Document, to: store.location.portfolioURL)
        let portfolio = try store.loadPortfolio()
        #expect(portfolio.schemaVersion == Portfolio.currentSchemaVersion)
        #expect(portfolio.products.count == 2)
        let old = try #require(portfolio.product(slug: "old-app"))
        #expect(old.lifecycle == .archived)
        #expect(old.isArchived)
        #expect(old.profiles.isEmpty && old.recipes.isEmpty)
        #expect(old.tags == ["legacy"])
        #expect(old.createdAt == ISO8601DateFormatter().date(from: "2024-03-01T10:00:00Z"))
        let live = try #require(portfolio.product(slug: "live-app"))
        #expect(live.lifecycle == .active)
        #expect(live.isFavorite)
        #expect(live.environments.first?.tier == .development)
        #expect(portfolio.settings.pollingIntervalSeconds == 120)
        #expect(portfolio.settings.appearance == "dark")
    }

    @Test func migrationIsWrittenBackAsTheCurrentVersion() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        try write(schemaV1Document, to: store.location.portfolioURL)
        try store.save(try store.loadPortfolio())
        let text = try String(contentsOf: store.location.portfolioURL, encoding: .utf8)
        #expect(text.contains("\"schemaVersion\" : \(Portfolio.currentSchemaVersion)"))
        #expect(!text.contains("retired"))
        #expect(try store.loadPortfolio().products.count == 2)
    }

    @Test func aDocumentWithoutAVersionIsTreatedAsVersion1() throws {
        let stripped = schemaV1Document.replacingOccurrences(of: "\"schemaVersion\": 1,", with: "")
        let migrated = try PortfolioMigrator.migrate(Data(stripped.utf8))
        let portfolio = try JSONCoding.decoder().decode(Portfolio.self, from: migrated)
        #expect(portfolio.schemaVersion == Portfolio.currentSchemaVersion)
        #expect(portfolio.products[0].lifecycle == .archived)
    }

    @Test func aNewerSchemaIsRefused() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        let newer = Portfolio.currentSchemaVersion + 1
        try write("{\"schemaVersion\": \(newer), \"products\": [], \"somethingNew\": true}", to: store.location.portfolioURL)
        #expect(throws: StoreError.newerSchema(found: newer, supported: Portfolio.currentSchemaVersion)) {
            _ = try store.loadPortfolio()
        }
        // The file is left exactly as it was.
        #expect(try String(contentsOf: store.location.portfolioURL, encoding: .utf8).contains("somethingNew"))
    }

    @Test func corruptDocumentsThrowInsteadOfLoadingEmpty() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        try write("[1, 2, 3]", to: store.location.portfolioURL)
        #expect(throws: StoreError.corrupt("top level is not an object")) { _ = try store.loadPortfolio() }
        try write("{\"schemaVersion\": 2, \"products\": \"nope\"}", to: store.location.portfolioURL)
        #expect(throws: StoreError.self) { _ = try store.loadPortfolio() }
        try write("this is not json", to: store.location.portfolioURL)
        #expect(throws: (any Error).self) { _ = try store.loadPortfolio() }
    }

    @Test func aCorruptCacheLoadsAsEmpty() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        try write("{ broken", to: store.location.cacheURL)
        #expect(store.loadCache().deployments.isEmpty)
    }

    @Test func clearingTheCacheLeavesThePortfolioIntact() throws {
        let (store, directory) = try makeStore()
        defer { removeTemp(directory) }
        let world = EvidenceWorld()
        try store.save(world.portfolio)
        var cache = ObservationCache()
        cache.deployments = [world.observation(world.production, sha: shaA, at: fixedNow)]
        try store.save(cache)
        let before = try Data(contentsOf: store.location.portfolioURL)

        try store.clearCache()
        #expect(!FileManager.default.fileExists(atPath: store.location.cacheURL.path))
        #expect(try Data(contentsOf: store.location.portfolioURL) == before)
        #expect(try store.loadPortfolio().products.map(\.id) == [world.product.id])
        #expect(store.loadCache().deployments.isEmpty)
        // Clearing twice is not an error.
        try store.clearCache()
    }

    @Test func storeLocationHonorsTheOverride() throws {
        let directory = try makeTempDir("home")
        defer { removeTemp(directory) }
        let location = StoreLocation.resolve(environment: ["FORGEDECK_HOME": directory.path])
        #expect(location.directory.path == directory.path)
        #expect(StoreLocation.isOverridden(environment: ["FORGEDECK_HOME": directory.path]))
        #expect(!StoreLocation.isOverridden(environment: [:]))
        #expect(location.portfolioURL.lastPathComponent == "portfolio.json")
        #expect(location.cacheURL.lastPathComponent == "cache.json")
        #expect(location.auditURL.lastPathComponent == "audit.jsonl")
    }
}

@Suite struct IntegrityTests {
    private func brokenPortfolio() -> Portfolio {
        var product = Product(name: "Acme")
        var repo = Repository(); repo.owner = "acme"; repo.name = "app"; repo.componentID = UUID()
        product.repositories = [repo]
        var checkout = LocalCheckout(); checkout.name = "app"; checkout.repositoryID = UUID(); checkout.componentID = UUID()
        product.checkouts = [checkout]
        var recipe = ActionRecipe(); recipe.label = "Test"; recipe.checkoutID = UUID(); recipe.environmentID = UUID()
        var profile = TerminalProfile(); profile.name = "dev"; profile.checkoutID = UUID(); profile.environmentID = UUID()
        product.recipes = [recipe]
        product.profiles = [profile]
        var twin = Product(name: "Acme")
        twin.slug = product.slug
        var orphan = VariableDefinition(); orphan.key = "ORPHAN"; orphan.scope = .product(UUID())
        var leaky = VariableDefinition(); leaky.key = "LEAKY"; leaky.isSecret = true; leaky.plainValue = "should-not-be-here"
        var portfolio = Portfolio()
        portfolio.products = [product, twin]
        portfolio.variables = [orphan, leaky]
        return portfolio
    }

    @Test func problemsNameEveryDanglingReference() {
        let problems = IntegrityChecker.problems(in: brokenPortfolio())
        let expected = ["repository acme/app points at a missing component", "checkout app points at a missing repository",
                        "checkout app points at a missing component", "recipe Test points at a missing checkout",
                        "recipe Test points at a missing environment", "profile dev points at a missing checkout",
                        "profile dev points at a missing environment", "duplicate slug acme",
                        "variable ORPHAN is scoped to a missing product", "secret variable LEAKY carries a plain value"]
        for fragment in expected {
            #expect(problems.contains { $0.contains(fragment) }, "missing problem: \(fragment)")
        }
        #expect(problems.count == expected.count)
    }

    @Test func repairClearsDanglingReferencesAndKeepsDefinitions() {
        let repaired = IntegrityChecker.repair(brokenPortfolio())
        #expect(IntegrityChecker.problems(in: repaired).isEmpty)
        #expect(repaired.products.count == 2)
        #expect(Set(repaired.products.map(\.slug)) == ["acme", "acme-2"])
        #expect(repaired.products[0].checkouts.count == 1)
        #expect(repaired.products[0].checkouts[0].repositoryID == nil)
        #expect(repaired.products[0].recipes[0].checkoutID == nil)
        #expect(repaired.products[0].profiles[0].environmentID == nil)
        #expect(repaired.variables.map(\.key) == ["LEAKY"])
        #expect(repaired.variables[0].plainValue == nil)
    }

    @Test func repairKeepsValidReferences() {
        let world = SecretWorld()
        let repaired = IntegrityChecker.repair(world.portfolio)
        #expect(IntegrityChecker.problems(in: world.portfolio).isEmpty)
        #expect(repaired.products[0].profiles.map(\.environmentID) == world.portfolio.products[0].profiles.map(\.environmentID))
        #expect(repaired.products[0].recipes[0].checkoutID == world.portfolio.products[0].checkouts[0].id)
        #expect(repaired.variables.count == world.portfolio.variables.count)
    }

    @Test func loadingRepairsInsteadOfRefusing() throws {
        let directory = try makeTempDir("repair")
        defer { removeTemp(directory) }
        let store = PortfolioStore(location: StoreLocation(directory: directory))
        try store.save(brokenPortfolio())
        let loaded = try store.loadPortfolio()
        #expect(IntegrityChecker.problems(in: loaded).isEmpty)
        #expect(loaded.products.count == 2)
    }
}

@Suite struct CacheMaintenanceTests {
    @Test func pruneDropsOldObservationsOnly() {
        var cache = ObservationCache()
        let old = fixedNow.addingTimeInterval(-40 * 86_400)
        let recent = fixedNow.addingTimeInterval(-5 * 86_400)
        cache.record(ActivityEvent(id: "old", kind: .commit, productID: nil, title: "old", detail: "", at: old, sourceLabel: ""))
        cache.record(ActivityEvent(id: "recent", kind: .commit, productID: nil, title: "recent", detail: "", at: recent, sourceLabel: ""))
        var oldLead = LeadEvent(); oldLead.id = "l-old"; oldLead.occurredAt = old
        var recentLead = LeadEvent(); recentLead.id = "l-recent"; recentLead.occurredAt = recent
        cache.merge(leads: [oldLead, recentLead])
        cache.points = [MetricPoint(productID: UUID(), key: "mrr", day: old, value: 1), MetricPoint(productID: UUID(), key: "mrr", day: recent, value: 2)]
        var resolvedLongAgo = Incident(); resolvedLongAgo.openedAt = old; resolvedLongAgo.resolvedAt = old
        var stillOpen = Incident(); stillOpen.openedAt = old
        var resolvedRecently = Incident(); resolvedRecently.openedAt = old; resolvedRecently.resolvedAt = recent
        cache.incidents = [resolvedLongAgo, stillOpen, resolvedRecently]
        cache.sessions = (0..<(ObservationCache.maxSessions + 10)).map { _ in SessionRecord() }

        cache.prune(retentionDays: 30, now: fixedNow)
        #expect(cache.activity.map(\.id) == ["recent"])
        #expect(cache.leads.map(\.id) == ["l-recent"])
        #expect(cache.points.map(\.value) == [2])
        #expect(Set(cache.incidents.map(\.id)) == [stillOpen.id, resolvedRecently.id])
        #expect(cache.sessions.count == ObservationCache.maxSessions)
    }

    @Test func activityIsRecordedOncePerKeyAndBounded() {
        var cache = ObservationCache()
        let event = ActivityEvent(id: "same", kind: .deploy, productID: nil, title: "t", detail: "", at: fixedNow, sourceLabel: "")
        let first = cache.record(event)
        let second = cache.record(event)
        #expect(first)
        #expect(!second)
        #expect(cache.activity.count == 1)
        for index in 0..<(ObservationCache.maxActivity + 20) {
            cache.record(ActivityEvent(id: "e\(index)", kind: .commit, productID: nil, title: "", detail: "",
                                       at: fixedNow.addingTimeInterval(Double(index)), sourceLabel: ""))
        }
        #expect(cache.activity.count == ObservationCache.maxActivity)
        // Newest first: the oldest fall off.
        #expect(cache.activity.first?.id == "e\(ObservationCache.maxActivity + 19)")
    }

    @Test func healthHistoryIsBounded() {
        var cache = ObservationCache()
        let probe = UUID()
        for index in 0..<(ObservationCache.maxHealthSamples + 15) {
            cache.record(HealthSample(at: fixedNow.addingTimeInterval(Double(index)), ok: true), probe: probe)
        }
        #expect(cache.health[probe]?.count == ObservationCache.maxHealthSamples)
        #expect(cache.health[probe]?.last?.at == fixedNow.addingTimeInterval(Double(ObservationCache.maxHealthSamples + 14)))
    }

    @Test func deploymentHistoryAppendsOnChangeAndRefreshesOtherwise() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.record(world.observation(world.production, sha: shaA, at: fixedNow))
        cache.record(world.observation(world.production, sha: shaA, at: fixedNow.addingTimeInterval(60)))
        #expect(cache.deployments.count == 1)
        #expect(cache.deployments[0].provenance.observedAt == fixedNow.addingTimeInterval(60))
        cache.record(world.observation(world.production, sha: shaB, at: fixedNow.addingTimeInterval(120)))
        #expect(cache.deployments.map(\.sha) == [shaA, shaB])
        // Another source for the same environment is its own history.
        cache.record(world.observation(world.production, sha: shaB, source: .deploymentRecord, level: .reported,
                                       at: fixedNow.addingTimeInterval(130), deployState: "success"))
        #expect(cache.deployments.count == 3)
    }

    @Test func removingAProductDropsOnlyItsObservations() {
        let world = EvidenceWorld()
        let otherID = UUID()
        var cache = ObservationCache()
        cache.git[world.checkout.id] = world.gitSnapshot(head: shaA, at: fixedNow)
        cache.remotes[world.repo.id] = world.remote(head: shaA, at: fixedNow)
        cache.health[world.productionProbe.id] = [HealthSample(at: fixedNow, ok: true)]
        cache.deployments = [world.observation(world.production, sha: shaA, at: fixedNow)]
        var foreign = DeploymentObservation(); foreign.productID = otherID
        cache.deployments.append(foreign)
        var lead = LeadEvent(); lead.id = "a"; lead.productID = world.product.id
        var foreignLead = LeadEvent(); foreignLead.id = "b"; foreignLead.productID = otherID
        cache.leads = [lead, foreignLead]

        cache.remove(product: world.product)
        #expect(cache.git.isEmpty && cache.remotes.isEmpty && cache.health.isEmpty)
        #expect(cache.deployments.map(\.productID) == [otherID])
        #expect(cache.leads.map(\.id) == ["b"])
    }
}

@Suite struct AuditLogTests {
    @Test func appendsAndReadsBackNewestFirst() throws {
        let directory = try makeTempDir("audit")
        defer { removeTemp(directory) }
        let log = AuditLog(url: directory.appending(path: "nested/audit.jsonl"))
        #expect(log.read().isEmpty)
        log.record(AuditEvent(actor: "cli", action: "exec.denied", product: "acme", environment: "production", detail: "first", outcome: "denied"))
        log.record(AuditEvent(actor: "app", action: "open", product: "acme", detail: "second"))
        log.record(AuditEvent(actor: "app", action: "open", product: "acme", detail: "third"))

        let events = log.read()
        #expect(events.map(\.detail) == ["third", "second", "first"])
        #expect(events.last?.actor == "cli")
        #expect(events.last?.outcome == "denied")
        #expect(events.last?.environment == "production")
        #expect(log.read(limit: 2).map(\.detail) == ["third", "second"])
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func tokenShapedTextInDetailIsRedactedBeforeItIsWritten() throws {
        let directory = try makeTempDir("audit")
        defer { removeTemp(directory) }
        let log = AuditLog(url: directory.appending(path: "audit.jsonl"))
        let github = "ghp_" + String(repeating: "Z9", count: 18)
        let stripe = "sk_live_" + String(repeating: "4eC3", count: 6)
        log.record(AuditEvent(actor: "cli", action: "exec.finished",
                              detail: "program=curl note=\(github) Authorization: Bearer abcdefghijklmnop123456 key \(stripe) https://bob:hunter2pass@example.com/x"))
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!text.contains(github))
        #expect(!text.contains(stripe))
        #expect(!text.contains("abcdefghijklmnop123456"))
        #expect(!text.contains("hunter2pass"))
        #expect(text.contains("program=curl"))
        #expect(log.read().first?.detail.contains(Redactor.mask) == true)
    }

    @Test func aLineThatIsNotAnEventIsSkipped() throws {
        let directory = try makeTempDir("audit")
        defer { removeTemp(directory) }
        let url = directory.appending(path: "audit.jsonl")
        let log = AuditLog(url: url)
        log.record(AuditEvent(actor: "app", action: "one"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage line\n".utf8))
        try handle.close()
        log.record(AuditEvent(actor: "app", action: "two"))
        #expect(log.read().map(\.action) == ["two", "one"])
    }

    @Test func memorySinkKeepsEventsInOrder() {
        let sink = MemoryAuditSink()
        sink.record(AuditEvent(actor: "app", action: "a"))
        sink.record(AuditEvent(actor: "app", action: "b"))
        #expect(sink.events.map(\.action) == ["a", "b"])
    }
}
