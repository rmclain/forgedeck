import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct SecretsNeverPersistedTests {
    @Test func savedPortfolioHoldsNoSecretValue() throws {
        let directory = try makeTempDir("persist")
        defer { removeTemp(directory) }
        let world = SecretWorld()
        let store = PortfolioStore(location: StoreLocation(directory: directory))
        try store.save(world.portfolio)
        let text = String(decoding: try Data(contentsOf: store.location.portfolioURL), as: UTF8.self)
        expectNoMarkers(text, "portfolio.json")
        // The references are there, so the app can find the Keychain items again.
        #expect(text.contains("loc-dev") && text.contains("loc-prod"))
        #expect(text.contains("API_TOKEN"))
    }

    /// A probe that authenticates with a production secret: the token goes out in the
    /// Authorization header and nowhere else.
    @Test func cacheWrittenAfterAnAuthenticatedRefreshHoldsNoSecretValue() async throws {
        let directory = try makeTempDir("persist")
        defer { removeTemp(directory) }
        var world = SecretWorld()
        var probe = ProbeConfig()
        probe.name = "Status"
        probe.kind = .companion
        probe.url = "https://api.acme.example/_forgedeck/v1/status"
        probe.bearerVariableKey = "API_TOKEN"
        var source = MetricSource()
        source.name = "Companion"
        source.baseURL = "https://api.acme.example"
        source.bearerVariableKey = "API_TOKEN"
        let productionIndex = try #require(world.portfolio.products[0].environments.firstIndex { $0.tier == .production })
        world.portfolio.products[0].environments[productionIndex].probes = [probe]
        world.portfolio.products[0].environments[productionIndex].metricSources = [source]

        let http = MockHTTPClient()
        http.on("/_forgedeck/v1/status", json: """
        {"schema_version": "1.0", "environment": "production", "release": {"commit_sha": "\(shaA)", "version": "v1.0.0"}, "health": {"state": "healthy"}}
        """)
        http.on("/_forgedeck/v1/metrics", json: "{\"schema_version\": \"1.0\", \"metrics\": {\"leads\": 3}}")
        http.on("/_forgedeck/v1/leads", status: 401, json: "{\"error\": \"bad token\"}")
        let runner = FakeRunner(result: ProcessResult(exitCode: 1))
        let engine = RefreshEngine(git: GitService(runner: runner, git: URL(fileURLWithPath: "/usr/bin/git")), http: http,
                                   ssh: SSHInspector(runner: runner),
                                   credentials: CredentialResolver(keychain: world.secrets, runner: runner, environment: [:]))
        let probeUpdates = await engine.refreshProbes(world.product, portfolio: world.portfolio)
        let metricUpdates = await engine.refreshMetrics(world.product, portfolio: world.portfolio)
        let updates = probeUpdates + metricUpdates
        // The secret did travel, in the header only.
        let sent = http.requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { $0 == "Bearer \(SecretWorld.prodMarker)" })
        #expect(http.requests.allSatisfy { !($0.url?.absoluteString ?? "").contains(SecretWorld.prodMarker) })

        var cache = ObservationCache()
        cache.apply(updates, portfolio: world.portfolio, now: .now)
        #expect(cache.deployments.first?.sha == shaA)
        #expect(cache.metrics.first?.value == 3)
        let store = PortfolioStore(location: StoreLocation(directory: directory))
        try store.save(cache)
        expectNoMarkers(String(decoding: try Data(contentsOf: store.location.cacheURL), as: UTF8.self), "cache.json")
    }

    @Test func exportHoldsNoSecretValue() throws {
        let world = SecretWorld()
        let text = String(decoding: try PortfolioExporter.export(world.portfolio), as: UTF8.self)
        expectNoMarkers(text, "export")
    }

    @Test func auditFileHoldsNoSecretValueAfterGrantsAndDenials() async throws {
        let directory = try makeTempDir("persist")
        defer { removeTemp(directory) }
        let world = SecretWorld()
        let log = AuditLog(url: directory.appending(path: "audit.jsonl"))
        let granting = world.exec(authorizer: FixedAuthorizer(true), audit: log)
        let refusing = world.exec(authorizer: FixedAuthorizer(false), audit: log)

        _ = try await granting.plan(world.request(), portfolio: world.portfolio)
        _ = try await granting.plan(world.request(environment: "production", profile: "prod"), portfolio: world.portfolio)
        #expect(await denial(refusing, world.request(environment: "production", profile: "prod"), world.portfolio) == .authenticationFailed)
        #expect(await denial(refusing, world.request(profile: "leaky"), world.portfolio) == .blocked(["PROD_ONLY_KEY"]))
        #expect(await denial(refusing, world.request(command: ["curl", "-H", "Authorization: \(SecretWorld.devMarker)"]), world.portfolio) != nil)

        let text = try String(contentsOf: log.url, encoding: .utf8)
        expectNoMarkers(text, "audit.jsonl")
        #expect(!text.contains(SecretWorld.plainMarker))
        let events = log.read()
        #expect(events.filter { $0.action == "exec.granted" }.count == 2)
        #expect(events.filter { $0.action == "exec.denied" }.count == 3)
    }

    @Test func planArgumentsAndLaunchTextHoldNoSecretValue() async throws {
        let world = SecretWorld()
        let plan = try await world.exec().plan(world.request(command: ["env", "-u", "HOME"]), portfolio: world.portfolio)
        #expect(plan.arguments == ["-u", "HOME"])
        expectNoMarkers(plan.arguments.joined(separator: " "), "ExecPlan.arguments")
        expectNoMarkers(plan.executable.path, "ExecPlan.executable")
        expectNoMarkers(plan.grantedKeys.joined(separator: " "), "ExecPlan.grantedKeys")

        let command = ["forgedeck", "exec", "--product", world.product.slug, "--environment", "local", "--profile", "dev", "--", "env"]
        expectNoMarkers(TerminalLauncher.script(directory: world.product.checkouts[0].path, command: command), "launch script")
        expectNoMarkers(TerminalLauncher.copyCommand(directory: world.product.checkouts[0].path, command: command), "copy command")
    }

    @Test func agentContextHoldsNoSecretOrPlainValue() {
        let world = SecretWorld()
        let text = AgentPrograms.contextFile(for: world.product, cache: ObservationCache())
        expectNoMarkers(text, "agent context")
        #expect(!text.contains(SecretWorld.plainMarker))
        #expect(!text.contains(SecretWorld.argumentMarker))
        #expect(text.contains("# Acme API"))
        #expect(text.contains("Secrets are not included"))
    }
}

@Suite struct PortfolioExporterTests {
    private func exportable() -> Portfolio {
        var portfolio = SecretWorld().portfolio
        var sneaky = VariableDefinition()
        sneaky.key = "LOOKS_PLAIN"
        sneaky.plainValue = "ghp_" + String(repeating: "q7", count: 15)
        var ordinary = VariableDefinition()
        ordinary.key = "LOG_LEVEL"
        ordinary.plainValue = "debug"
        portfolio.variables += [sneaky, ordinary]
        return portfolio
    }

    @Test func exportDropsBookmarksAndTokenLookingValuesAndListsPlaceholders() throws {
        let portfolio = exportable()
        #expect(portfolio.products[0].checkouts[0].bookmark != nil)
        let data = try PortfolioExporter.export(portfolio)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("ghp_"))
        #expect(!text.contains(Data("bookmark-bytes".utf8).base64EncodedString()))

        let export = try JSONCoding.decoder().decode(PortfolioExport.self, from: data)
        #expect(export.format == PortfolioExport.format)
        #expect(export.portfolio.products.flatMap(\.checkouts).allSatisfy { $0.bookmark == nil })
        #expect(export.portfolio.variables.first { $0.key == "LOOKS_PLAIN" }?.plainValue == nil)
        #expect(export.portfolio.variables.first { $0.key == "LOG_LEVEL" }?.plainValue == "debug")
        #expect(export.portfolio.variables.first { $0.key == "FEATURE_FLAG" }?.plainValue == SecretWorld.plainMarker)
        #expect(export.portfolio.variables.filter(\.isSecret).allSatisfy { $0.plainValue == nil })
        #expect(export.credentialPlaceholders == ["API_TOKEN", "API_TOKEN", "PROD_ONLY_KEY", "LOOKS_PLAIN", "connection:GitHub"])
        // The original is untouched.
        #expect(portfolio.products[0].checkouts[0].bookmark != nil)
    }

    @Test func demoProductsAreLeftOutUnlessAsked() throws {
        var portfolio = exportable()
        portfolio.products += DemoFixtures.products(count: 2)
        let without = try PortfolioExporter.validate(PortfolioExporter.export(portfolio))
        #expect(without.portfolio.products.count == 3)
        #expect(!without.portfolio.products.contains { $0.isDemo })
        let with = try PortfolioExporter.validate(PortfolioExporter.export(portfolio, includeDemo: true))
        #expect(with.portfolio.products.count == 5)
    }

    @Test func validateAndMergeRoundTrip() throws {
        let source = exportable()
        let export = try PortfolioExporter.validate(PortfolioExporter.export(source))
        var target = Portfolio()
        let report = PortfolioExporter.merge(export, into: &target)
        #expect(report.productsAdded == 3 && report.productsSkipped == 0)
        #expect(report.variablesAdded == source.variables.count)
        #expect(report.credentialsToReenter == export.credentialPlaceholders)
        #expect(target.products.map(\.id) == source.products.map(\.id))
        #expect(target.products[0].profiles == source.products[0].profiles)
        #expect(target.connections.map(\.id) == source.connections.map(\.id))
        #expect(IntegrityChecker.problems(in: target).isEmpty)

        // Importing the same file again changes nothing.
        let again = PortfolioExporter.merge(export, into: &target)
        #expect(again.productsAdded == 0 && again.productsSkipped == 3 && again.variablesAdded == 0)
        #expect(target.products.count == 3)
        #expect(target.variables.count == source.variables.count)
        #expect(target.connections.count == 1)
    }

    @Test func mergeKeepsAnExistingProductWithTheSameSlug() throws {
        let source = exportable()
        let export = try PortfolioExporter.validate(PortfolioExporter.export(source))
        var target = Portfolio()
        var mine = Product(name: "Acme API")
        mine.tagline = "my local edits"
        target.products = [mine]
        let report = PortfolioExporter.merge(export, into: &target)
        #expect(report.productsSkipped == 1 && report.productsAdded == 2)
        #expect(target.product(slug: "acme-api")?.tagline == "my local edits")
        // Variables scoped to the skipped product are not attached to a product that is not there.
        #expect(target.variables.allSatisfy { $0.scope.productID == nil })
        #expect(IntegrityChecker.problems(in: target).isEmpty)
    }

    @Test func nonExportJSONIsRejected() throws {
        let portfolioFile = try JSONCoding.encoder().encode(SecretWorld().portfolio)
        let wrongFormat = Data("{\"format\": \"something-else\", \"exportVersion\": 1, \"portfolio\": {}}".utf8)
        let noPortfolio = Data("{\"format\": \"forgedeck-export\", \"exportVersion\": 1}".utf8)
        let newer = Data("{\"format\": \"forgedeck-export\", \"exportVersion\": 2, \"portfolio\": {}}".utf8)
        let badInner = Data("{\"format\": \"forgedeck-export\", \"exportVersion\": 1, \"portfolio\": {\"schemaVersion\": 2, \"products\": 7}}".utf8)
        for data in [Data("{}".utf8), Data("[]".utf8), Data("not json".utf8), Data(), portfolioFile, wrongFormat, noPortfolio, newer, badInner] {
            #expect(throws: StoreError.self) { _ = try PortfolioExporter.validate(data) }
        }
    }

    @Test func anExportWithDanglingReferencesIsRejected() throws {
        var portfolio = Portfolio()
        var product = Product(name: "Acme")
        var profile = TerminalProfile()
        profile.name = "dev"
        profile.environmentID = UUID()
        product.profiles = [profile]
        portfolio.products = [product]
        let data = try PortfolioExporter.export(portfolio)
        #expect(throws: StoreError.self) { _ = try PortfolioExporter.validate(data) }
    }

    /// BUG (PortfolioStore.swift, PortfolioExporter.export): demo products are removed from the export, but
    /// variables scoped to them stay. `validate` then fails its integrity check ("scoped to a missing
    /// product"), so the app's own export cannot be imported. Fix: in `export`, also drop variables whose
    /// `scope.productID` names a product that was removed.
    @Test func anExportMadeWhileDemoProductsHaveVariablesCanBeImported() throws {
        var portfolio = Portfolio()
        let demo = DemoFixtures.products(count: 1)[0]
        portfolio.products = [Product(name: "Real"), demo]
        var variable = VariableDefinition()
        variable.key = "DEMO_FLAG"
        variable.scope = .product(demo.id)
        variable.plainValue = "on"
        portfolio.variables = [variable]
        let data = try PortfolioExporter.export(portfolio)
        _ = try PortfolioExporter.validate(data)
    }
}

@Suite struct ExecServiceTests {
    @Test func developmentProfileReceivesOnlyItsDevelopmentToken() async throws {
        let world = SecretWorld()
        let plan = try await world.exec().plan(world.request(command: ["env", "FOO=1"]), portfolio: world.portfolio)
        #expect(plan.environment["API_TOKEN"] == SecretWorld.devMarker)
        #expect(plan.environment["FEATURE_FLAG"] == SecretWorld.plainMarker)
        #expect(!plan.environment.values.contains(SecretWorld.prodMarker))
        #expect(!plan.environment.values.contains(SecretWorld.prodOnlyMarker))
        #expect(plan.environment["PROD_ONLY_KEY"] == nil)
        #expect(plan.environment["FORGEDECK_PRODUCT"] == "acme-api")
        #expect(plan.environment["FORGEDECK_ENVIRONMENT"] == "development")
        #expect(plan.environment["PATH"] == "/usr/bin:/bin")
        #expect(plan.grantedKeys == ["API_TOKEN", "FEATURE_FLAG"])
        #expect(plan.secretKeys == ["API_TOKEN"])
        #expect(plan.secretValues == [SecretWorld.devMarker])
        #expect(plan.executable.path == "/usr/bin/env")
        #expect(plan.arguments == ["FOO=1"])
        #expect(plan.workingDirectory?.path == "/nonexistent/acme/api")
        #expect(!plan.isProduction)
        #expect(world.secrets.reads == 1)
    }

    @Test func environmentNamesResolveByNameTierOrLocal() {
        let world = SecretWorld()
        #expect(ExecService.environment(named: "Local", in: world.product)?.tier == .development)
        #expect(ExecService.environment(named: "local", in: world.product)?.tier == .development)
        #expect(ExecService.environment(named: "development", in: world.product)?.tier == .development)
        #expect(ExecService.environment(named: "PRODUCTION", in: world.product)?.tier == .production)
        #expect(ExecService.environment(named: "staging", in: world.product) == nil)
    }

    @Test func aDevelopmentProfileCannotBePointedAtProduction() async {
        let world = SecretWorld()
        let result = await denial(world.exec(authorizer: FixedAuthorizer(true)), world.request(environment: "production", profile: "dev"), world.portfolio)
        #expect(result == .profileEnvironmentMismatch(profile: "dev", environment: "Production"))
        #expect(world.secrets.reads == 0)
    }

    @Test func aProductionOnlySecretIsBlockedInDevelopment() async {
        let world = SecretWorld()
        let result = await denial(world.exec(authorizer: FixedAuthorizer(true)), world.request(profile: "leaky"), world.portfolio)
        #expect(result == .blocked(["PROD_ONLY_KEY"]))
        #expect(world.secrets.reads == 0)
    }

    @Test(arguments: ["/bin/sh", "sh", "npm; rm -rf", "env; id", "env && id", "env id", "/usr/bin/env/../../../bin/sh", "$(env)", "`env`",
                      "-env", "ENV", "env\n", "printenv ", "bash", "/usr/bin/sudo"])
    func programsOutsideTheAllowlistAreDenied(program: String) async {
        let world = SecretWorld()
        let result = await denial(world.exec(authorizer: FixedAuthorizer(true)), world.request(command: [program, "x"]), world.portfolio)
        guard case .executableNotAllowed(_, let allowed) = result else {
            Issue.record("\(program) was not denied as executableNotAllowed: \(String(describing: result))")
            return
        }
        #expect(allowed == ["env", "printenv"])
        #expect(world.secrets.reads == 0)
    }

    @Test func anEmptyCommandIsDenied() async {
        let world = SecretWorld()
        #expect(await denial(world.exec(), world.request(command: []), world.portfolio) == .executableNotAllowed("", allowed: ["env", "printenv"]))
        #expect(await denial(world.exec(), world.request(command: [""]), world.portfolio) == .executableNotAllowed("", allowed: ["env", "printenv"]))
    }

    @Test func aProfileWithNoAllowedProgramsRunsNothing() async {
        var world = SecretWorld()
        world.portfolio.products[0].profiles[0].allowedExecutables = []
        #expect(await denial(world.exec(), world.request(), world.portfolio) == .executableNotAllowed("env", allowed: []))
    }

    /// BUG (ExecService.swift, ExecService.plan): the allowlist compares only the last path component, and
    /// `ExecutableLocator.find` then runs whatever path was given. Any executable that is *named* like an
    /// allowed program receives the profile's secrets: `forgedeck exec … -- /tmp/x/env` runs /tmp/x/env.
    /// An agent that may run `npm` can write its own `./npm` and read every granted secret.
    /// Fix: refuse a program that contains "/" (or resolve the bare name through fixed system paths and
    /// require the resolved path to match), and do not let the caller's PATH pick the binary.
    @Test func aLookalikeProgramAtAnotherPathIsDenied() async throws {
        let directory = try makeTempDir("lookalike")
        defer { removeTemp(directory) }
        let impostor = directory.appending(path: "env")
        try write("#!/bin/sh\necho impostor\n", to: impostor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: impostor.path)
        let world = SecretWorld()
        let result = await denial(world.exec(), world.request(command: [impostor.path]), world.portfolio)
        #expect(result != nil)
        #expect(world.secrets.reads == 0)
    }

    /// Same root cause as above: for a bare name that is not in a system folder, the caller's PATH decides
    /// which binary receives the secrets.
    @Test func theCallersPathDoesNotChooseTheBinary() async throws {
        let directory = try makeTempDir("pathhijack")
        defer { removeTemp(directory) }
        let name = "forgedeck-test-tool-\(UUID().uuidString.prefix(8))"
        let impostor = directory.appending(path: name)
        try write("#!/bin/sh\necho impostor\n", to: impostor)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: impostor.path)
        var world = SecretWorld()
        world.portfolio.products[0].profiles[0].allowedExecutables = [name]
        let service = ExecService(credentials: CredentialResolver(keychain: world.secrets, runner: FakeRunner(result: ProcessResult(exitCode: 1)), environment: [:]),
                                  authorizer: FixedAuthorizer(false), audit: world.audit, baseEnvironment: ["PATH": directory.path])
        let result = await denial(service, world.request(command: [name]), world.portfolio)
        #expect(result != nil)
    }

    @Test func productionWithoutAuthenticationReadsNoSecret() async {
        let world = SecretWorld()
        let result = await denial(world.exec(authorizer: FixedAuthorizer(false)), world.request(environment: "production", profile: "prod"), world.portfolio)
        #expect(result == .authenticationFailed)
        #expect(world.secrets.reads == 0)
        #expect(world.audit.events.map(\.action) == ["exec.denied"])
        #expect(world.audit.events[0].detail.contains("reason=authentication-failed"))
    }

    @Test func productionWithAuthenticationIsGrantedAndAuditedByNameOnly() async throws {
        let world = SecretWorld()
        let plan = try await world.exec(authorizer: FixedAuthorizer(true)).plan(world.request(environment: "production", profile: "prod"), portfolio: world.portfolio)
        #expect(plan.isProduction)
        #expect(plan.environment["API_TOKEN"] == SecretWorld.prodMarker)
        #expect(!plan.environment.values.contains(SecretWorld.devMarker))
        #expect(plan.environment["FORGEDECK_ENVIRONMENT"] == "production")
        #expect(plan.environmentName == "Production")
        #expect(world.secrets.reads == 1)

        let events = world.audit.events
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.action == "exec.granted")
        #expect(event.outcome == "ok")
        #expect(event.actor == "cli")
        #expect(event.product == "acme-api")
        #expect(event.environment == "Production")
        #expect(event.detail == "profile=prod program=env variables=API_TOKEN")
        expectNoMarkers(event.detail, "audit detail")
    }

    @Test func authenticationIsNotAskedWhenNoSecretIsGranted() async throws {
        var world = SecretWorld()
        world.portfolio.products[0].profiles[1].variableAllowlist = []
        let plan = try await world.exec(authorizer: FixedAuthorizer(false)).plan(world.request(environment: "production", profile: "prod"), portfolio: world.portfolio)
        #expect(plan.grantedKeys.isEmpty)
        #expect(world.secrets.reads == 0)
    }

    @Test func theSettingCanTurnProductionAuthenticationOff() async throws {
        var world = SecretWorld()
        world.portfolio.settings.requireAuthForProductionSecrets = false
        let plan = try await world.exec(authorizer: FixedAuthorizer(false)).plan(world.request(environment: "production", profile: "prod"), portfolio: world.portfolio)
        #expect(plan.environment["API_TOKEN"] == SecretWorld.prodMarker)
    }

    @Test func anArchivedProductIsDenied() async {
        let world = SecretWorld()
        let result = await denial(world.exec(authorizer: FixedAuthorizer(true)), world.request(profile: "dev", product: "old-thing"), world.portfolio)
        #expect(result == .archived("Old Thing"))
        #expect(world.secrets.reads == 0)
    }

    @Test func unknownProductEnvironmentAndProfileAreDenied() async {
        let world = SecretWorld()
        let service = world.exec(authorizer: FixedAuthorizer(true))
        #expect(await denial(service, world.request(product: "nope-zz"), world.portfolio) == .unknownProduct("nope-zz"))
        #expect(await denial(service, world.request(environment: "staging"), world.portfolio) == .unknownEnvironment("staging"))
        #expect(await denial(service, world.request(profile: "ghost"), world.portfolio) == .unknownProfile("ghost"))
        // A profile that belongs to another product is not a profile of this one.
        #expect(await denial(service, world.request(profile: "otherprof"), world.portfolio) == .unknownProfile("otherprof"))
        #expect(world.secrets.reads == 0)
    }

    @Test func anExpiredCredentialIsDenied() async {
        var world = SecretWorld()
        world.portfolio.variables[0].credential?.expiresAt = Date.now.addingTimeInterval(-3_600)
        #expect(await denial(world.exec(), world.request(), world.portfolio) == .blocked(["API_TOKEN"]))
        #expect(world.secrets.reads == 0)
    }

    @Test func anAllowlistedVariableThatNothingDefinesIsDenied() async {
        var world = SecretWorld()
        world.portfolio.products[0].profiles[0].variableAllowlist.append("NOT_DEFINED")
        #expect(await denial(world.exec(), world.request(), world.portfolio) == .missing(["NOT_DEFINED"]))
        #expect(world.secrets.reads == 0)
    }

    @Test func aSecretMissingFromTheStoreIsDeniedWithoutLeakingOthers() async throws {
        let world = SecretWorld()
        try world.secrets.delete("loc-dev")
        let result = await denial(world.exec(), world.request(), world.portfolio)
        guard case .secretUnavailable(let key, _) = result else { Issue.record("expected secretUnavailable, got \(String(describing: result))"); return }
        #expect(key == "API_TOKEN")
        #expect(world.audit.events.last?.detail.contains("reason=secret-unavailable:API_TOKEN") == true)
    }

    @Test func aProgramThatIsNotInstalledIsDenied() async {
        var world = SecretWorld()
        let name = "forgedeck-no-such-program-\(UUID().uuidString.prefix(8))"
        world.portfolio.products[0].profiles[0].allowedExecutables = [name]
        #expect(await denial(world.exec(), world.request(command: [name]), world.portfolio) == .executableNotFound(name))
        #expect(world.secrets.reads == 0)
    }

    @Test func everyDenialWritesOneAuditEventWithNoCommandLineText() async {
        let world = SecretWorld()
        let service = world.exec(authorizer: FixedAuthorizer(false))
        let requests: [(ExecRequest, String)] = [
            (world.request(product: "nope-zz"), "unknown-product"),
            (world.request(profile: "dev", product: "old-thing"), "archived"),
            (world.request(environment: "staging"), "unknown-environment"),
            (world.request(profile: "ghost"), "unknown-profile"),
            (world.request(environment: "production", profile: "dev"), "profile-environment-mismatch"),
            (world.request(command: ["/bin/sh", "-c", "echo SHELL-TEXT-MARKER"]), "executable-not-allowed"),
            (world.request(profile: "leaky"), "blocked:PROD_ONLY_KEY"),
            (world.request(environment: "production", profile: "prod"), "authentication-failed"),
        ]
        for (index, (request, code)) in requests.enumerated() {
            #expect(await denial(service, request, world.portfolio) != nil, "\(code)")
            let events = world.audit.events
            #expect(events.count == index + 1, "\(code)")
            #expect(events.last?.action == "exec.denied")
            #expect(events.last?.outcome == "denied")
            #expect(events.last?.detail.hasSuffix("reason=\(code)") == true, "\(events.last?.detail ?? "")")
        }
        #expect(world.audit.events.allSatisfy { !$0.detail.contains("SHELL-TEXT-MARKER") })
        #expect(world.secrets.reads == 0)
    }

    @Test func denialsExplainThemselves() {
        #expect(ExecDenial.unknownProduct("x").description.contains("forgedeck list"))
        #expect(ExecDenial.executableNotAllowed("sh", allowed: []).description.contains("nothing"))
        #expect(ExecDenial.blocked(["A", "B"]).description == "Denied: A, B may not be used in this environment.")
        #expect(ExecDenial.authenticationFailed.description.contains("Nothing ran"))
    }

    @Test func aRealChildSeesTheDevelopmentVariableAndNotTheProductionOne() async throws {
        let world = SecretWorld(checkoutPath: FileManager.default.temporaryDirectory.path)
        let plan = try await world.exec().plan(world.request(command: ["env"]), portfolio: world.portfolio)
        let result = try await SystemProcessRunner().run(ProcessRequest(executable: plan.executable, arguments: plan.arguments,
                                                                         workingDirectory: plan.workingDirectory, environment: plan.environment))
        #expect(result.ok)
        let lines = Set(result.stdout.split(separator: "\n").map(String.init))
        #expect(lines.contains("API_TOKEN=\(SecretWorld.devMarker)"))
        #expect(lines.contains("FEATURE_FLAG=\(SecretWorld.plainMarker)"))
        #expect(lines.contains("FORGEDECK_ENVIRONMENT=development"))
        #expect(!result.stdout.contains(SecretWorld.prodMarker))
        #expect(!result.stdout.contains(SecretWorld.prodOnlyMarker))
        #expect(!result.stdout.contains("PROD_ONLY_KEY"))
        // Nothing from the test process leaks in beyond the base environment the service was given.
        #expect(lines.allSatisfy { $0.hasPrefix("API_TOKEN=") || $0.hasPrefix("FEATURE_FLAG=") || $0.hasPrefix("FORGEDECK_") || $0.hasPrefix("PATH=") })
    }

    @Test func childProcessRunsThePlanAndReturnsItsExitCode() async throws {
        let world = SecretWorld(checkoutPath: FileManager.default.temporaryDirectory.path)
        let present = try await world.exec().plan(world.request(command: ["printenv", "API_TOKEN"]), portfolio: world.portfolio)
        // Redacted, so the marker is masked on the way to this process's stdout.
        #expect(await ChildProcess.run(present, redactOutput: true) == 0)
        let absent = try await world.exec().plan(world.request(command: ["printenv", "PROD_ONLY_KEY"]), portfolio: world.portfolio)
        #expect(await ChildProcess.run(absent, redactOutput: true) == 1)
    }

    @Test func lineBufferKeepsASplitSecretOnOneLine() {
        let buffer = LineBuffer()
        #expect(buffer.feed(Data("first line\nsecret-part-".utf8)) == ["first line"])
        #expect(buffer.feed(Data("one-part-two".utf8)).isEmpty)
        #expect(buffer.feed(Data("\nlast\n".utf8)) == ["secret-part-one-part-two", "last"])
    }
}

@Suite struct RedactorTests {
    let redactor = Redactor()

    @Test func everyPatternCompiles() throws {
        for pattern in Redactor.tokenPatterns {
            #expect(throws: Never.self, "\(pattern)") { _ = try NSRegularExpression(pattern: pattern) }
        }
    }

    @Test func gitHubTokens() {
        let classic = "ghp_" + String(repeating: "aB3", count: 12)
        let fine = "github_pat_" + String(repeating: "A1_b2", count: 8)
        let server = "ghs_" + String(repeating: "x9", count: 14)
        let text = redactor.redact("classic \(classic) fine \(fine) server \(server) end")
        #expect(text == "classic \(Redactor.mask) fine \(Redactor.mask) server \(Redactor.mask) end")
        #expect(Redactor.looksLikeSecret(classic))
    }

    @Test func stripeAndOtherProviderKeys() {
        let keys = ["sk_live_" + String(repeating: "4eC3", count: 6), "rk_test_" + String(repeating: "a1", count: 8),
                    "whsec_" + String(repeating: "Zz9", count: 8), "xoxb-" + String(repeating: "12ab", count: 6), "AKIAIOSFODNN7EXAMPLE"]
        for key in keys {
            let text = redactor.redact("value=\(key);")
            #expect(!text.contains(key), "\(key)")
            #expect(text.contains(Redactor.mask))
        }
    }

    @Test func jwtShapedText() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(redactor.redact("session \(jwt) ok") == "session \(Redactor.mask) ok")
    }

    @Test func bearerHeaders() {
        #expect(redactor.redact("Authorization: Bearer abc123def456ghi789") == "Authorization: Bearer \(Redactor.mask)")
        #expect(redactor.redact("authorization: bearer ABC.def-ghi_jkl~mno+p/q=") == "authorization: bearer \(Redactor.mask)")
    }

    @Test func urlCredentials() {
        #expect(redactor.redact("https://bob:hunter2@example.com/path") == "https://\(Redactor.mask)@example.com/path")
        #expect(redactor.redact("postgres://app:s3cr3t-pw@db.internal:5432/app") == "postgres://\(Redactor.mask)@db.internal:5432/app")
        #expect(redactor.redact("https://example.com:8443/path?x=1") == "https://example.com:8443/path?x=1")
    }

    @Test func privateKeyBlocks() {
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\nAAAAB3NzaC1yc2E\n-----END OPENSSH PRIVATE KEY-----"
        let text = redactor.redact("before\n\(key)\nafter")
        #expect(text == "before\n\(Redactor.mask)\nafter")
        let rsa = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----"
        #expect(!redactor.redact(rsa).contains("MIIEow"))
    }

    @Test func assignmentsOfPasswordsAndKeys() {
        #expect(redactor.redact("password=correct-horse-battery") == "password=\(Redactor.mask)")
        #expect(redactor.redact("API_KEY: abcdef123456") == "API_KEY: \(Redactor.mask)")
        #expect(redactor.redact("?token=abcdef123456&page=2") == "?token=\(Redactor.mask)&page=2")
    }

    @Test func knownValuesAreMaskedLongestFirst() {
        let custom = Redactor(knownValues: ["hunter2", "hunter2-extended", "abc"])
        #expect(custom.redact("a hunter2-extended b hunter2 c abc") == "a \(Redactor.mask) b \(Redactor.mask) c abc")
        // Values shorter than four characters would mask ordinary text and are ignored.
        #expect(custom.knownValues == ["hunter2-extended", "hunter2"])
        #expect(Redactor(knownValues: [SecretWorld.devMarker]).redact("x=\(SecretWorld.devMarker)!") == "x=\(Redactor.mask)!")
    }

    @Test func ordinaryTextIsUntouched() {
        for text in ["main · 3 uncommitted", "Deploy to Production succeeded at 3f9a2c1", "profile=dev program=npm variables=API_TOKEN,STRIPE_SECRET",
                     "https://github.com/acme/widget/pull/42", "git@github.com:acme/widget.git", "The token expired yesterday.",
                     "reason=blocked:API_TOKEN", "eyJ is how a JWT starts", "sk_live_ is a Stripe prefix", "Bearer of bad news",
                     "\(shaA)", "user@example.com", ""] {
            #expect(redactor.redact(text) == text, "\(text)")
            #expect(!Redactor.looksLikeSecret(text), "\(text)")
        }
    }

    @Test func maskingContacts() {
        #expect(Masking.email("jane.doe@example.com") == "j***@e***.com")
        #expect(Masking.email("a@b") == "a***@b***")
        #expect(Masking.email("not-an-email") == Masking.generic("not-an-email"))
        #expect(Masking.generic("+1 555 0100") == "+" + String(repeating: "•", count: 8))
        #expect(Masking.generic("ab") == "a•••")
        #expect(Masking.generic("") == "")
    }
}

@Suite struct SecretStoreTests {
    @Test func memoryStoreRoundTrip() throws {
        let store = MemorySecretStore(["a": "1"])
        #expect(try store.read("a") == "1")
        #expect(store.exists("a") && !store.exists("b"))
        try store.write("2", locator: "a")
        #expect(try store.read("a") == "2")
        try store.delete("a")
        #expect(throws: SecretError.notFound) { _ = try store.read("a") }
    }

    /// The one test that touches the real Keychain. It uses its own service name and removes what it wrote.
    @Test func keychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.forgedeck.tests.\(UUID().uuidString)")
        let locator = "round-trip-\(UUID().uuidString)"
        defer { try? store.delete(locator) }
        #expect(!store.exists(locator))
        #expect(throws: SecretError.notFound) { _ = try store.read(locator) }

        try store.write("first value ✓", locator: locator)
        #expect(store.exists(locator))
        #expect(try store.read(locator) == "first value ✓")
        try store.write("second value", locator: locator)
        #expect(try store.read(locator) == "second value")

        // Another service does not see the item.
        #expect(!KeychainSecretStore(service: "com.forgedeck.tests.\(UUID().uuidString)").exists(locator))

        try store.delete(locator)
        #expect(!store.exists(locator))
        #expect(throws: SecretError.notFound) { _ = try store.read(locator) }
        // Deleting something that is not there is not an error.
        try store.delete(locator)
    }

    @Test func credentialResolverReadsFromTheReferencedOrigin() async throws {
        let runner = FakeRunner(result: ProcessResult(exitCode: 1))
        let resolver = CredentialResolver(keychain: MemorySecretStore(["item": "from-keychain"]), runner: runner, environment: ["MY_TOKEN": "from-env", "EMPTY": ""])
        var keychain = CredentialReference()
        keychain.locator = "item"
        #expect(try await resolver.value(for: keychain) == "from-keychain")
        #expect(resolver.isAvailable(keychain))

        var environment = CredentialReference()
        environment.origin = .environmentReference
        environment.locator = "MY_TOKEN"
        #expect(try await resolver.value(for: environment) == "from-env")
        environment.locator = "EMPTY"
        #expect(!resolver.isAvailable(environment))
        await #expect(throws: SecretError.self) { _ = try await resolver.value(for: environment) }

        var agent = CredentialReference()
        agent.origin = .sshAgent
        await #expect(throws: SecretError.self) { _ = try await resolver.value(for: agent) }

        var missing = CredentialReference()
        missing.locator = "nope"
        await #expect(throws: SecretError.notFound) { _ = try await resolver.value(for: missing) }
        #expect(!resolver.isAvailable(missing))
        #expect(runner.requests.isEmpty)
    }

    @Test func fixedAuthorizerAnswersAsConfigured() async {
        #expect(await FixedAuthorizer(true).confirm(reason: "x"))
        #expect(await FixedAuthorizer(false).confirm(reason: "x") == false)
    }
}
