import Foundation
import Testing
@testable import ForgeDeckKit

private func project(_ path: String, remote: String? = nil, worktreeOf main: String? = nil,
                     metadata: DetectedMetadata = DetectedMetadata(), description: String? = nil) -> DiscoveredProject {
    DiscoveredProject(path: path, name: (path as NSString).lastPathComponent, isGitRepository: true, isWorktree: main != nil,
                      mainWorktreePath: main, remoteURL: remote, repository: remote.flatMap(RepositoryURL.parse),
                      metadata: metadata, description: description)
}

@Suite struct ModelTests {
    @Test func slugsAreStableAndUnique() {
        #expect(Slug.make("Orbit CRM") == "orbit-crm")
        #expect(Slug.make("  Café -- Déjà Vu!  ") == "cafe-deja-vu")
        #expect(Slug.make("!!!") == "product")
        #expect(Slug.unique("Lumen", taken: ["lumen"]) == "lumen-2")
        #expect(Slug.unique("Lumen", taken: ["lumen", "lumen-2"]) == "lumen-3")
        #expect(Slug.unique("Lumen", taken: []) == "lumen")
    }

    @Test func monogramAndHueAreDeterministic() {
        #expect(Monogram.make("Orbit CRM") == "Oc")
        #expect(Monogram.make("lumen") == "Lu")
        #expect(Monogram.make("") == "•")
        #expect(Monogram.hue("Lumen") == Monogram.hue("Lumen"))
        #expect((0..<360).contains(Monogram.hue("Lumen")))
    }

    @Test func oneProductHoldsSeveralRepositoriesAndCheckouts() {
        var product = Product(name: "Acme Suite")
        let api = Component(name: "API", kind: .backend)
        let web = Component(name: "Web", kind: .frontend)
        product.components = [api, web]
        var apiRepo = Repository(); apiRepo.owner = "acme"; apiRepo.name = "api"; apiRepo.componentID = api.id
        var webRepo = Repository(); webRepo.owner = "acme"; webRepo.name = "web"; webRepo.componentID = web.id
        product.repositories = [apiRepo, webRepo]
        var first = LocalCheckout(); first.name = "api"; first.path = "/code/api"; first.repositoryID = apiRepo.id
        var second = LocalCheckout(); second.name = "api-hotfix"; second.path = "/code/api-hotfix"; second.repositoryID = apiRepo.id
        var third = LocalCheckout(); third.name = "web"; third.path = "/code/web"; third.repositoryID = webRepo.id
        product.checkouts = [first, second, third]

        #expect(product.repositories.count == 2)
        #expect(product.checkouts.filter { $0.repositoryID == apiRepo.id }.count == 2)
        #expect(product.repository(id: third.repositoryID)?.fullName == "acme/web")
        #expect(product.component(id: apiRepo.componentID)?.name == "API")
        #expect(product.primaryCheckout?.id == first.id)
        #expect(product.hasLocal && product.hasRemote && !product.hasProduction)
        var portfolio = Portfolio()
        portfolio.products = [product]
        #expect(IntegrityChecker.problems(in: portfolio).isEmpty)
    }

    @Test func productLookupBySlugAndIDPrefix() {
        var portfolio = Portfolio()
        let product = Product(name: "Orbit CRM")
        portfolio.products = [product, Product(name: "Lumen")]
        #expect(portfolio.product(slug: "orbit-crm")?.id == product.id)
        #expect(portfolio.product(slug: "ORBIT-CRM")?.id == product.id)
        #expect(portfolio.product(slug: String(product.id.uuidString.prefix(8)))?.id == product.id)
        #expect(portfolio.product(slug: "no-such-product-zz") == nil)
        #expect(portfolio.groups == ["Products"])
    }

    /// BUG (Models.swift, Portfolio.product(slug:)): the id-prefix fallback uses `hasPrefix`, and every
    /// string has the empty prefix, so "" resolves to the first product. `forgedeck exec --product ""`
    /// reaches a product nobody named. Fix: require a minimum prefix length (e.g. 8) before the fallback.
    @Test func emptySlugMatchesNoProduct() {
        var portfolio = Portfolio()
        portfolio.products = [Product(name: "Orbit CRM")]
        #expect(portfolio.product(slug: "") == nil)
    }

    @Test func evidenceLevelsAndSafetyAreOrdered() {
        #expect(EvidenceLevel.unknown < .stale)
        #expect(EvidenceLevel.stale < .reported)
        #expect(EvidenceLevel.reported < .verified)
        #expect(ActionSafety.readOnly < .localWrite)
        #expect(ActionSafety.remoteWrite < .productionCritical)
    }

    @Test func provenanceExpiresToStaleAndUnknownStaysUnknown() {
        let verified = Provenance(observedAt: fixedNow, source: .runtimeProbe, level: .verified, ttl: 900)
        #expect(verified.effectiveLevel(now: fixedNow.addingTimeInterval(899)) == .verified)
        #expect(verified.effectiveLevel(now: fixedNow.addingTimeInterval(901)) == .stale)
        let unknown = Provenance(observedAt: fixedNow, source: .runtimeProbe, level: .unknown, ttl: 900)
        #expect(unknown.effectiveLevel(now: fixedNow.addingTimeInterval(5_000)) == .unknown)
    }

    @Test func gitSnapshotSummaries() {
        var git = GitSnapshot()
        git.branch = "main"
        #expect(git.summary == "main · clean")
        git.ahead = 2
        #expect(git.summary == "main · 2 ahead")
        git.behind = 1
        #expect(git.summary == "main · 2 ahead, 1 behind")
        git.untracked = 1; git.staged = 2
        #expect(git.summary == "main · 3 uncommitted")
        #expect(git.isDirty)
        git.conflicted = 1
        #expect(git.summary == "main · 1 conflicted")
        git.available = false
        git.problem = "Folder missing"
        #expect(git.summary == "Folder missing")
        #expect(shortSHA(nil) == "—")
        #expect(shortSHA(shaA) == "aaaaaaa")
    }

    @Test func credentialExpiryAndRotation() {
        var reference = CredentialReference()
        reference.createdAt = fixedNow
        #expect(!reference.isExpired(now: fixedNow))
        #expect(reference.rotationDue(now: fixedNow) == nil)
        reference.expiresAt = fixedNow.addingTimeInterval(-1)
        #expect(reference.isExpired(now: fixedNow))
        reference.rotationIntervalDays = 30
        #expect(reference.rotationDue(now: fixedNow) == fixedNow.addingTimeInterval(30 * 86_400))
        let keychain = CredentialReference.keychain()
        #expect(keychain.locator == keychain.id.uuidString)
    }

    @Test func relativeTimeIsReadable() {
        #expect(RelativeTime.short(fixedNow.addingTimeInterval(-10), now: fixedNow) == "now")
        #expect(RelativeTime.short(fixedNow.addingTimeInterval(-300), now: fixedNow) == "5m ago")
        #expect(RelativeTime.short(fixedNow.addingTimeInterval(-7_200), now: fixedNow) == "2h ago")
        #expect(RelativeTime.short(fixedNow.addingTimeInterval(7_200), now: fixedNow) == "in 2h")
        #expect(RelativeTime.compact(fixedNow.addingTimeInterval(-300), now: fixedNow) == "5m")
    }
}

@Suite struct ImportPlannerTests {
    @Test func twoCheckoutsOfOneRepositoryBecomeOneProduct() {
        var portfolio = Portfolio()
        let projects = [project("/code/app", remote: "git@github.com:acme/app.git"),
                        project("/code/app-hotfix", remote: "https://github.com/acme/app.git")]
        let proposals = ImportPlanner.plan(projects, portfolio: portfolio)
        #expect(proposals.map(\.action) == [.createProduct, .createProduct])
        let touched = ImportPlanner.apply(proposals, to: &portfolio)
        #expect(touched.count == 1)
        #expect(portfolio.products.count == 1)
        #expect(portfolio.products[0].checkouts.map(\.path) == ["/code/app", "/code/app-hotfix"])
        #expect(portfolio.products[0].repositories.count == 1)
        #expect(portfolio.products[0].name == "app")
        #expect(IntegrityChecker.problems(in: portfolio).isEmpty)
    }

    @Test func repositoryThatBelongsToAProductProposesAddCheckout() {
        var portfolio = Portfolio()
        ImportPlanner.apply(ImportPlanner.plan([project("/code/app", remote: "git@github.com:acme/app.git")], portfolio: portfolio), to: &portfolio)
        let productID = portfolio.products[0].id
        let proposals = ImportPlanner.plan([project("/elsewhere/app-2", remote: "https://github.com/Acme/App")], portfolio: portfolio)
        #expect(proposals.map(\.action) == [.addCheckout(productID: productID)])
        ImportPlanner.apply(proposals, to: &portfolio)
        #expect(portfolio.products.count == 1)
        #expect(portfolio.products[0].checkouts.count == 2)
        #expect(portfolio.products[0].repositories.count == 1)
    }

    @Test func rescanProposesRefreshAndIsIdempotent() {
        var portfolio = Portfolio()
        var metadata = DetectedMetadata()
        metadata.stack = ["Next.js"]
        metadata.testCommand = ["npm", "test"]
        let projects = [project("/code/app", remote: "git@github.com:acme/app.git", metadata: metadata, description: "Detected tagline"),
                        project("/code/tool", remote: nil)]
        ImportPlanner.apply(ImportPlanner.plan(projects, portfolio: portfolio), to: &portfolio)
        #expect(portfolio.products.count == 2)
        let before = portfolio.products.map { ($0.id, $0.checkouts.count, $0.repositories.count, $0.recipes.count, $0.components.count) }

        let second = ImportPlanner.plan(projects, portfolio: portfolio)
        #expect(second.allSatisfy { if case .refresh = $0.action { true } else { false } })
        ImportPlanner.apply(second, to: &portfolio)
        ImportPlanner.apply(ImportPlanner.plan(projects, portfolio: portfolio), to: &portfolio)
        let after = portfolio.products.map { ($0.id, $0.checkouts.count, $0.repositories.count, $0.recipes.count, $0.components.count) }
        #expect(before.count == after.count)
        for (a, b) in zip(before, after) { #expect(a == b) }
    }

    @Test func rescanKeepsUserEditedFields() {
        var portfolio = Portfolio()
        let first = project("/code/app", remote: "git@github.com:acme/app.git", description: "Detected tagline")
        ImportPlanner.apply(ImportPlanner.plan([first], portfolio: portfolio), to: &portfolio)
        portfolio.products[0].name = "My Renamed App"
        portfolio.products[0].tagline = "My tagline"
        portfolio.products[0].tags = ["mine"]
        portfolio.products[0].group = "Favorites"
        portfolio.products[0].isFavorite = true

        var metadata = DetectedMetadata()
        metadata.stack = ["Swift"]
        let rescanned = project("/code/app", remote: "git@github.com:acme/app.git", metadata: metadata, description: "Another tagline")
        ImportPlanner.apply(ImportPlanner.plan([rescanned], portfolio: portfolio), to: &portfolio)
        let product = portfolio.products[0]
        #expect(portfolio.products.count == 1)
        #expect(product.name == "My Renamed App")
        #expect(product.tagline == "My tagline")
        #expect(product.tags == ["mine"])
        #expect(product.group == "Favorites")
        #expect(product.isFavorite)
        #expect(product.checkouts.count == 1)
        // The refresh still picks up what was detected.
        #expect(product.stack.contains("Swift"))
        #expect(product.checkouts[0].detected.stack == ["Swift"])
    }

    @Test func linkedWorktreeFollowsItsMainCheckout() {
        var portfolio = Portfolio()
        ImportPlanner.apply(ImportPlanner.plan([project("/code/tool")], portfolio: portfolio), to: &portfolio)
        let productID = portfolio.products[0].id
        let proposals = ImportPlanner.plan([project("/code/tool-wt", worktreeOf: "/code/tool")], portfolio: portfolio)
        #expect(proposals.map(\.action) == [.addCheckout(productID: productID)])
        ImportPlanner.apply(proposals, to: &portfolio)
        #expect(portfolio.products.count == 1)
        #expect(portfolio.products[0].checkouts.last?.isWorktree == true)
        #expect(portfolio.products[0].checkouts.last?.mainWorktreePath == "/code/tool")
    }

    @Test func unselectedProposalsAreNotApplied() {
        var portfolio = Portfolio()
        var proposals = ImportPlanner.plan([project("/code/a"), project("/code/b")], portfolio: portfolio)
        proposals[1].isSelected = false
        ImportPlanner.apply(proposals, to: &portfolio)
        #expect(portfolio.products.map(\.name) == ["a"])
    }

    @Test func detectedCommandsBecomeUnapprovedSuggestions() {
        var portfolio = Portfolio()
        var metadata = DetectedMetadata()
        metadata.testCommand = ["npm", "test"]
        metadata.startCommand = ["npm", "run", "dev"]
        metadata.devURL = "http://localhost:3000"
        ImportPlanner.apply(ImportPlanner.plan([project("/code/web", metadata: metadata)], portfolio: portfolio), to: &portfolio)
        let product = portfolio.products[0]
        #expect(product.recipes.count == 2)
        #expect(product.recipes.allSatisfy { $0.isSuggested && !$0.isApproved })
        #expect(product.environment(tier: .development)?.domains == ["http://localhost:3000"])
        #expect(product.slug == "web")
    }

    @Test func slugsStayUniqueAcrossImports() {
        var portfolio = Portfolio()
        ImportPlanner.apply(ImportPlanner.plan([project("/one/app")], portfolio: portfolio), to: &portfolio)
        ImportPlanner.apply(ImportPlanner.plan([project("/two/app")], portfolio: portfolio), to: &portfolio)
        #expect(portfolio.products.map(\.slug) == ["app", "app-2"])
    }
}

@Suite struct VariableResolverTests {
    struct World {
        var product: Product
        var environment: ProductEnvironment
        var component: Component
        var profile: TerminalProfile
        var organization: UUID

        init(tier: EnvironmentTier = .development) {
            organization = UUID()
            product = Product(name: "Acme")
            product.organizationID = organization
            environment = ProductEnvironment(name: tier.title, tier: tier)
            component = Component(name: "API", kind: .backend)
            profile = TerminalProfile()
            profile.name = "dev"
            product.environments = [environment]
            product.components = [component]
            product.profiles = [profile]
        }

        var scopes: [VariableScope] {
            [.global, .organization(organization), .product(product.id), .component(product: product.id, component: component.id),
             .environment(product: product.id, environment: environment.id), .profile(product: product.id, profile: profile.id)]
        }

        func context(allowlist: Set<String>? = nil) -> ResolutionContext {
            ResolutionContext(product: product, environment: environment, componentID: component.id, profile: profile, allowlist: allowlist)
        }
    }

    static func plain(_ key: String, _ value: String, scope: VariableScope, tiers: [EnvironmentTier] = [.development]) -> VariableDefinition {
        var variable = VariableDefinition()
        variable.key = key
        variable.scope = scope
        variable.plainValue = value
        variable.allowedTiers = tiers
        return variable
    }

    static func secret(_ key: String, scope: VariableScope, tiers: [EnvironmentTier], expiresAt: Date? = nil) -> VariableDefinition {
        var variable = VariableDefinition()
        variable.key = key
        variable.scope = scope
        variable.isSecret = true
        variable.allowedTiers = tiers
        var reference = CredentialReference.keychain()
        reference.expiresAt = expiresAt
        variable.credential = reference
        return variable
    }

    @Test func precedenceRunsFromGlobalToProfile() {
        let world = World()
        var variables: [VariableDefinition] = []
        for scope in world.scopes {
            // Insert at the front, so the result cannot depend on definition order.
            variables.insert(Self.plain("K", scope.title, scope: scope), at: 0)
            let resolved = VariableResolver.resolve(variables, context: world.context(), now: fixedNow)
            #expect(resolved.count == 1)
            #expect(resolved.first?.winner?.plainValue == scope.title)
        }
        #expect(world.scopes.map(\.precedence) == [0, 1, 2, 3, 4, 5])
    }

    @Test func overrideReportsWhatItShadows() {
        let world = World()
        let variables = world.scopes.reversed().map { Self.plain("K", $0.title, scope: $0) }
        let resolved = VariableResolver.resolve(variables, context: world.context(), now: fixedNow)[0]
        #expect(resolved.state == .overridden)
        #expect(resolved.shadowed.map(\.scope.title) == ["Global", "Organization", "Product", "Component", "Environment"])
        #expect(resolved.note.contains("replaces"))
        #expect(resolved.state.delivers)
    }

    @Test func inheritedAndDirectStates() {
        let world = World()
        let inherited = VariableResolver.resolve([Self.plain("A", "1", scope: .global)], context: world.context(), now: fixedNow)[0]
        #expect(inherited.state == .inherited)
        let direct = VariableResolver.resolve([Self.plain("A", "1", scope: world.scopes[4])], context: world.context(), now: fixedNow)[0]
        #expect(direct.state == .direct)
    }

    @Test func scopesOfOtherProductsDoNotApply() {
        let world = World()
        let foreign = [Self.plain("A", "1", scope: .product(UUID())), Self.plain("B", "2", scope: .organization(UUID())),
                       Self.plain("C", "3", scope: .environment(product: world.product.id, environment: UUID()))]
        #expect(VariableResolver.resolve(foreign, context: world.context(), now: fixedNow).isEmpty)
    }

    @Test func productionSecretIsBlockedInDevelopment() {
        let world = World(tier: .development)
        let variables = [Self.secret("STRIPE_KEY", scope: .product(world.product.id), tiers: [.production])]
        let resolved = VariableResolver.resolve(variables, context: world.context(), now: fixedNow)[0]
        #expect(resolved.state == .blocked)
        #expect(resolved.winner == nil)
        #expect(resolved.isSecret)
        #expect(!resolved.state.delivers)
        #expect(resolved.note.contains("Production"))
    }

    @Test func productionSecretResolvesInProduction() {
        let world = World(tier: .production)
        let variables = [Self.secret("STRIPE_KEY", scope: .product(world.product.id), tiers: [.production])]
        let resolved = VariableResolver.resolve(variables, context: world.context(), now: fixedNow)[0]
        #expect(resolved.state == .inherited)
        #expect(resolved.winner != nil)
    }

    @Test func aWiderAllowedDefinitionWinsWhenTheNarrowerIsForAnotherTier() {
        let world = World(tier: .development)
        let variables = [Self.plain("URL", "dev", scope: .global, tiers: [.development]),
                         Self.plain("URL", "prod", scope: world.scopes[4], tiers: [.production])]
        let resolved = VariableResolver.resolve(variables, context: world.context(), now: fixedNow)[0]
        #expect(resolved.winner?.plainValue == "dev")
        #expect(resolved.state == .inherited)
    }

    @Test func expiredCredentialResolvesAsExpired() {
        let world = World()
        let variables = [Self.secret("TOKEN", scope: .product(world.product.id), tiers: [.development], expiresAt: fixedNow.addingTimeInterval(-60))]
        let resolved = VariableResolver.resolve(variables, context: world.context(), now: fixedNow)[0]
        #expect(resolved.state == .expired)
        #expect(!resolved.state.delivers)
        let fresh = VariableResolver.resolve(variables, context: world.context(), now: fixedNow.addingTimeInterval(-120))[0]
        #expect(fresh.state == .inherited)
    }

    @Test func allowlistGivesNotGrantedAndMissing() {
        let world = World()
        let variables = [Self.plain("GRANTED", "1", scope: .global), Self.plain("EXTRA", "2", scope: .global)]
        let resolved = VariableResolver.resolve(variables, context: world.context(allowlist: ["GRANTED", "UNDEFINED"]), now: fixedNow)
        let states = Dictionary(uniqueKeysWithValues: resolved.map { ($0.key, $0.state) })
        #expect(states == ["GRANTED": .inherited, "EXTRA": .notGranted, "UNDEFINED": .missing])
        #expect(resolved.map(\.key) == ["EXTRA", "GRANTED", "UNDEFINED"])
    }

    @Test func warningsFlagDuplicatesAndCrossTierSecrets() {
        let world = World()
        let duplicate = [Self.plain("A", "1", scope: .global), Self.plain("A", "2", scope: .global)]
        #expect(VariableResolver.warnings(duplicate) == ["A is defined 2 times at Global scope."])
        let crossTier = [Self.secret("KEY", scope: .product(world.product.id), tiers: [.development, .production])]
        let warnings = VariableResolver.warnings(crossTier)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("KEY") && warnings[0].contains("Production"))
        let clean = [Self.secret("KEY", scope: .product(world.product.id), tiers: [.production]), Self.plain("B", "1", scope: .global)]
        #expect(VariableResolver.warnings(clean).isEmpty)
    }

    @Test func keyValidation() {
        #expect(VariableResolver.isValidKey("API_TOKEN"))
        #expect(VariableResolver.isValidKey("_x9"))
        #expect(!VariableResolver.isValidKey("9LIVES"))
        #expect(!VariableResolver.isValidKey("A B"))
        #expect(!VariableResolver.isValidKey("A=B"))
        #expect(!VariableResolver.isValidKey(""))
        #expect(!VariableResolver.isValidKey("CLÉ"))
    }
}

@Suite struct DemoFixtureTests {
    @Test func everyDemoProductIsMarkedDemo() {
        let products = DemoFixtures.products()
        #expect(products.count == 8)
        #expect(products.allSatisfy { $0.isDemo })
        #expect(Set(products.map(\.slug)).count == products.count)
        #expect(Set(products.map(\.id)).count == products.count)
        var portfolio = Portfolio()
        portfolio.products = products
        #expect(IntegrityChecker.problems(in: portfolio).isEmpty)
    }

    @Test func everyFixtureObservationCarriesDemoProvenance() {
        let products = DemoFixtures.products()
        let cache = DemoFixtures.cache(for: products, now: fixedNow)
        #expect(!cache.deployments.isEmpty && !cache.remotes.isEmpty && !cache.metrics.isEmpty && !cache.leads.isEmpty)
        for observation in cache.deployments {
            #expect(observation.provenance.isDemo)
            #expect(observation.provenance.source == .fixture)
        }
        for remote in cache.remotes.values {
            #expect(remote.provenance.isDemo)
            #expect(remote.provenance.source == .fixture)
        }
        for sample in cache.metrics {
            #expect(sample.provenance.isDemo)
            #expect(sample.provenance.source == .fixture)
        }
        #expect(cache.leads.allSatisfy { $0.isDemo })
        #expect(cache.activity.allSatisfy { $0.isDemo })
        #expect(cache.incidents.allSatisfy { $0.isDemo })
    }

    @Test func demoChainIsLabelledAsFixture() {
        let products = DemoFixtures.products(count: 1)
        let cache = DemoFixtures.cache(for: products, now: fixedNow)
        let chain = DriftAnalyzer.chain(product: products[0], cache: cache, now: fixedNow)
        #expect(chain.count == 4)
        #expect(chain.allSatisfy { $0.isDemo && $0.sourceTitle == FactSource.fixture.title })
    }

    @Test func fixturesAreDeterministic() {
        let a = DemoFixtures.cache(for: DemoFixtures.products(), now: fixedNow)
        let b = DemoFixtures.cache(for: DemoFixtures.products(), now: fixedNow)
        #expect(a.deployments == b.deployments)
        #expect(a.leads.map(\.id) == b.leads.map(\.id))
        #expect(a.leads.map(\.occurredAt) == b.leads.map(\.occurredAt))
        #expect(DemoFixtures.products().map(\.id) == DemoFixtures.products().map(\.id))
    }

    @Test func installingTwiceAddsNothingTheSecondTime() {
        var portfolio = Portfolio()
        var cache = ObservationCache()
        #expect(DemoFixtures.install(count: 3, into: &portfolio, cache: &cache, now: fixedNow) == 3)
        let counts = [portfolio.products.count, cache.deployments.count, cache.leads.count, cache.activity.count,
                      cache.incidents.count, cache.metrics.count, cache.points.count]
        #expect(DemoFixtures.install(count: 3, into: &portfolio, cache: &cache, now: fixedNow) == 0)
        let again = [portfolio.products.count, cache.deployments.count, cache.leads.count, cache.activity.count,
                     cache.incidents.count, cache.metrics.count, cache.points.count]
        #expect(counts == again)
        #expect(portfolio.products.count == 3)
    }

    @Test func removeClearsDemoProductsAndTheirCachedData() {
        var portfolio = Portfolio()
        let real = Product(name: "Real Thing")
        portfolio.products = [real]
        var cache = ObservationCache()
        var realIncident = Incident()
        realIncident.productID = real.id
        cache.incidents = [realIncident]
        DemoFixtures.install(count: 8, into: &portfolio, cache: &cache, now: fixedNow)
        #expect(portfolio.products.count == 9)

        DemoFixtures.remove(from: &portfolio, cache: &cache)
        #expect(portfolio.products.map(\.id) == [real.id])
        #expect(cache.git.isEmpty && cache.remotes.isEmpty && cache.health.isEmpty)
        #expect(cache.deployments.isEmpty && cache.metrics.isEmpty && cache.points.isEmpty)
        #expect(cache.leads.isEmpty && cache.activity.isEmpty)
        #expect(cache.incidents.map(\.id) == [realIncident.id])
    }

    @Test func refreshEngineNeverContactsAnythingForDemoProducts() async {
        let http = MockHTTPClient()
        let runner = FakeRunner(result: ProcessResult(exitCode: 0))
        let engine = RefreshEngine(git: GitService(runner: runner, git: URL(fileURLWithPath: "/usr/bin/git")), http: http,
                                   ssh: SSHInspector(runner: runner),
                                   credentials: CredentialResolver(keychain: MemorySecretStore(), runner: runner, environment: [:]))
        var portfolio = Portfolio()
        portfolio.products = DemoFixtures.products(count: 2)
        for product in portfolio.products {
            #expect(await engine.refreshGit(product).isEmpty)
            #expect(await engine.refreshRemote(product, portfolio: portfolio).isEmpty)
            #expect(await engine.refreshProbes(product, portfolio: portfolio).isEmpty)
            #expect(await engine.refreshMetrics(product, portfolio: portfolio).isEmpty)
        }
        #expect(http.requests.isEmpty)
        #expect(runner.requests.isEmpty)
    }
}
