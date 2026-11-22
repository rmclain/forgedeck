import Foundation
import Testing
@testable import ForgeDeckKit

/// Records what `exec` would have started, instead of starting it.
private final class SpawnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ExecPlan] = []
    var plans: [ExecPlan] { lock.withLock { stored } }
    func record(_ plan: ExecPlan) { lock.withLock { stored.append(plan) } }
}

/// A CLI over a temp store, a memory secret store, a fake opener, and no real child process.
private struct CLIHarness {
    let directory: URL
    let world: SecretWorld
    let captured: CapturedOutput
    let spawned: SpawnLog
    let opener: FakeOpener
    let cli: CLI
    let auditLog: AuditLog

    init(world: SecretWorld? = nil, authorizer: any Authorizing = FixedAuthorizer(false), exitCode: Int32 = 0,
         opener: FakeOpener = FakeOpener(), savePortfolio: Bool = true) throws {
        let directory = try makeTempDir("cli")
        self.directory = directory
        let captured = CapturedOutput()
        let spawned = SpawnLog()
        self.captured = captured
        self.spawned = spawned
        let world = world ?? SecretWorld(checkoutPath: directory.path)
        self.world = world
        self.opener = opener
        let store = PortfolioStore(location: StoreLocation(directory: directory.appending(path: "data", directoryHint: .isDirectory)))
        if savePortfolio {
            try store.save(world.portfolio)
            var cache = ObservationCache()
            var git = GitSnapshot()
            git.branch = "main"
            git.headSHA = shaA
            git.untracked = 2
            git.observedAt = fixedNow
            cache.git[world.product.checkouts[0].id] = git
            var observation = DeploymentObservation()
            observation.productID = world.product.id
            observation.environmentID = world.production.id
            observation.sha = shaB
            observation.version = "v3.2.1"
            observation.health = .healthy
            observation.provenance = Provenance(observedAt: .now, source: .runtimeProbe, level: .verified, ttl: 900)
            cache.deployments = [observation]
            var incident = Incident()
            incident.rule = .pipelineBroken
            incident.productID = world.product.id
            incident.title = "CI is failing on main"
            cache.incidents = [incident]
            try store.save(cache)
        }
        let auditLog = AuditLog(url: store.location.auditURL)
        self.auditLog = auditLog
        let runner = FakeRunner(result: ProcessResult(exitCode: 1))
        cli = CLI(store: store, io: captured.output, exec: world.exec(authorizer: authorizer, audit: auditLog),
                  launcher: TerminalLauncher(opener: opener, launchDirectory: store.location.launchDirectory),
                  doctor: ConnectionDoctor(http: MockHTTPClient(), ssh: SSHInspector(runner: runner), runner: runner),
                  spawn: { plan, _ in
                      spawned.record(plan)
                      return exitCode
                  })
    }

    func cleanUp() { removeTemp(directory) }
    var slug: String { world.product.slug }
    var everything: String { captured.stdout + "\n" + captured.stderr }
}

@Suite struct CLIBasicsTests {
    @Test func helpListsEveryCommand() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["help"]) == CLIExit.ok)
        for command in CLI.commands {
            #expect(harness.captured.stdout.contains("forgedeck \(command)") || harness.captured.stdout.contains(" \(command)"), "\(command)")
        }
        // Every command has its own usage line, except the two that share one.
        for command in CLI.commands where !["help", "version"].contains(command) {
            #expect(CLI.help.contains("  forgedeck \(command) "), "no usage line for \(command)")
        }
        #expect(CLI.help.contains("forgedeck help | version"))
        #expect(harness.captured.stdout.contains("EXIT CODES"))
        #expect(harness.captured.stderr.isEmpty)
    }

    @Test func helpFlagsAndNoArgumentsPrintHelp() async throws {
        for arguments in [["--help"], ["-h"], []] {
            let harness = try CLIHarness()
            defer { harness.cleanUp() }
            #expect(await harness.cli.run(arguments) == CLIExit.ok)
            #expect(harness.captured.stdout == CLI.help)
        }
    }

    @Test func version() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["version"]) == CLIExit.ok)
        #expect(await harness.cli.run(["--version"]) == CLIExit.ok)
        #expect(harness.captured.stdout == "forgedeck \(CLI.version)\nforgedeck \(CLI.version)")
    }

    @Test func anUnknownCommandIsAUsageError() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["frobnicate", "--json"]) == 64)
        #expect(harness.captured.stderr.contains("unknown command \"frobnicate\""))
        #expect(harness.captured.stderr.contains("forgedeck help"))
        #expect(harness.captured.stdout.isEmpty)
        #expect(CLIExit.usage == 64 && CLIExit.denied == 77 && CLIExit.failure == 1 && CLIExit.ok == 0)
    }

    @Test func invocationDetection() {
        #expect(CLI.isInvocation(arguments: ["forgedeck"]))
        #expect(CLI.isInvocation(arguments: ["/usr/local/bin/forgedeck"]))
        #expect(CLI.isInvocation(arguments: ["/usr/local/bin/ForgeDeck", "list"]))
        #expect(CLI.isInvocation(arguments: ["/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck", "exec", "--product", "x"]))
        #expect(CLI.isInvocation(arguments: ["/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck", "--help"]))
        #expect(CLI.isInvocation(arguments: ["/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck", "--version"]))
        for command in CLI.commands {
            #expect(CLI.isInvocation(arguments: ["/x/App", command]), "\(command)")
        }
        // A normal app launch is not a CLI call.
        #expect(!CLI.isInvocation(arguments: ["/x/App"]))
        #expect(!CLI.isInvocation(arguments: ["/x/App", "--snapshot"]))
        #expect(!CLI.isInvocation(arguments: ["/x/App", "-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(!CLI.isInvocation(arguments: []))
    }

    /// BUG (CLI.swift, CLI.isInvocation): the program name is lowercased before it is compared with
    /// "forgedeck", and the app's own executable is named "ForgeDeck" (Package.swift). So a plain launch of
    /// ForgeDeck.app/Contents/MacOS/ForgeDeck, with no arguments or with AppKit's own launch arguments, is
    /// taken for a CLI call and the window never opens. Fix: compare the name exactly (`name == Brand.cliName`,
    /// no `.lowercased()`), so only the lowercase `forgedeck` symlink selects the CLI.
    @Test func launchingTheAppBinaryIsNotACLICall() {
        #expect(!CLI.isInvocation(arguments: ["/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck"]))
        #expect(!CLI.isInvocation(arguments: ["/Applications/ForgeDeck.app/Contents/MacOS/ForgeDeck", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    @Test func aCorruptPortfolioIsReportedNotReplaced() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        try write("[\"not\", \"a\", \"portfolio\"]", to: harness.cli.store.location.portfolioURL)
        #expect(await harness.cli.run(["list"]) == CLIExit.failure)
        #expect(harness.captured.stderr.hasPrefix("error:"))
        #expect(try String(contentsOf: harness.cli.store.location.portfolioURL, encoding: .utf8) == "[\"not\", \"a\", \"portfolio\"]")
    }
}

@Suite struct CLIReadCommandTests {
    @Test func listPrintsOneLinePerProduct() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["list"]) == CLIExit.ok)
        let lines = harness.captured.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("acme-api"))
        #expect(lines[0].contains("Acme API"))
        #expect(lines[0].contains("Build failed"))
        #expect(lines[2].contains("Archived"))
    }

    @Test func findNumbersProductsWithAFolderAndResolvesWords() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["find"]) == CLIExit.ok)
        #expect(harness.captured.stdout.contains("  1  Acme API  ·  "))
        #expect(!harness.captured.stdout.contains("Archived"))

        let one = try CLIHarness()
        defer { one.cleanUp() }
        #expect(await one.cli.run(["find", "acme"]) == CLIExit.ok)
        #expect(one.captured.stdout.hasPrefix("Acme API  (\(one.slug))") && one.captured.stdout.contains("context \(one.slug) --write"))

        let json = try CLIHarness()
        defer { json.cleanUp() }
        #expect(await json.cli.run(["find", "1", "--json"]) == CLIExit.ok)
        let rows = try JSONDecoder().decode([CLI.FoundRow].self, from: Data(json.captured.stdout.utf8))
        #expect(rows.count == 1 && rows[0].number == 1 && rows[0].name == "Acme API" && !rows[0].folder.isEmpty)

        let none = try CLIHarness()
        defer { none.cleanUp() }
        #expect(await none.cli.run(["find", "zzz-nothing"]) == CLIExit.failure)
        #expect(none.captured.stdout.contains("No product fits"))
    }

    @Test func listJSONDecodesIntoProductRows() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["list", "--json"]) == CLIExit.ok)
        let rows = try JSONCoding.decoder().decode([CLI.ProductRow].self, from: Data(harness.captured.stdout.utf8))
        #expect(rows.map(\.slug) == ["acme-api", "other-thing", "old-thing"])
        #expect(rows[0].name == "Acme API")
        #expect(rows[0].group == "Products")
        #expect(rows[0].lifecycle == "active")
        #expect(rows[0].status == "Build failed")
        #expect(rows[0].checkouts == 1 && rows[0].repositories == 0)
        #expect(rows[0].environments == ["Local", "Production"])
        #expect(!rows[0].demo)
        #expect(rows[2].lifecycle == "archived")
    }

    @Test func anEmptyPortfolioSaysSo() async throws {
        let harness = try CLIHarness(savePortfolio: false)
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["list"]) == CLIExit.ok)
        #expect(harness.captured.stdout == "No products yet. Add one in ForgeDeck.")
        #expect(await harness.cli.run(["list", "--json"]) == CLIExit.ok)
        #expect(harness.captured.stdout.hasSuffix("[\n\n]") || harness.captured.stdout.hasSuffix("[]"))
    }

    @Test func demoProductsAreLabelled() async throws {
        var world = SecretWorld()
        world.portfolio.products += DemoFixtures.products(count: 1)
        let harness = try CLIHarness(world: world)
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["list"]) == CLIExit.ok)
        #expect(harness.captured.stdout.split(separator: "\n").last?.hasSuffix("(demo)") == true)
        #expect(await harness.cli.run(["open", "lumen"]) == CLIExit.failure)
        #expect(harness.captured.stderr.contains("demo product"))
        #expect(harness.opener.opened.isEmpty)
    }

    @Test func statusJSONDecodesIntoAStatusReport() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["status", harness.slug, "--json"]) == CLIExit.ok)
        let report = try JSONCoding.decoder().decode(CLI.StatusReport.self, from: Data(harness.captured.stdout.utf8))
        #expect(report.slug == "acme-api")
        #expect(report.name == "Acme API")
        #expect(report.status == "Build failed")
        #expect(!report.demo)
        #expect(report.checkouts.count == 1)
        #expect(report.checkouts[0].name == "api")
        #expect(report.checkouts[0].branch == "main")
        #expect(report.checkouts[0].commit == shaA)
        #expect(report.checkouts[0].dirty)
        #expect(report.checkouts[0].summary == "main · 2 uncommitted")
        #expect(report.stages.map(\.stage) == ["local", "github", "staging", "production"])
        let production = try #require(report.stages.last)
        #expect(production.commit == shaB)
        #expect(production.version == "v3.2.1")
        #expect(production.evidence == "verified")
        #expect(production.source == "Runtime status endpoint")
        #expect(production.observedAt != nil)
        #expect(production.problem == nil)
        #expect(report.stages[1].problem == "notConfigured")
        #expect(report.stages[2].evidence == "unknown")
        #expect(report.relations.count == 3)
        #expect(report.openIncidents == ["CI is failing on main"])
    }

    @Test func statusPlainTextShowsEachStageWithItsEvidence() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["status", "ACME-API"]) == CLIExit.ok)
        let text = harness.captured.stdout
        #expect(text.hasPrefix("Acme API — Build failed"))
        #expect(text.contains("checkout  api: main · 2 uncommitted"))
        #expect(text.contains("PRODUCTION"))
        #expect(text.contains("v3.2.1"))
        #expect(text.contains("verified (Runtime status endpoint"))
        #expect(text.contains("! CI is failing on main"))
    }

    @Test func anUnknownProductFailsWithAHelpfulMessage() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        for arguments in [["status", "no-such-product-zz"], ["status", "no-such-product-zz", "--json"], ["context", "no-such-product-zz"],
                          ["actions", "list", "no-such-product-zz"], ["env", "list", "no-such-product-zz", "--environment", "local"],
                          ["open", "no-such-product-zz"]] {
            #expect(await harness.cli.run(arguments) == 1, "\(arguments)")
        }
        #expect(harness.captured.stdout.isEmpty)
        let lines = harness.captured.stderr.split(separator: "\n")
        #expect(lines.count == 6)
        #expect(lines.allSatisfy { $0 == "error: no product \"no-such-product-zz\". Run `forgedeck list`." })
    }

    @Test func aMissingProductArgumentAsksForOne() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["status"]) == CLIExit.failure)
        #expect(await harness.cli.run(["status", "--json"]) == CLIExit.failure)
        #expect(harness.captured.stderr.contains("name a product"))
        #expect(harness.captured.stdout.isEmpty)
    }

    @Test func envListShowsStatesAndNeverValues() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["env", "list", harness.slug, "--environment", "local", "--profile", "dev", "--json"]) == CLIExit.ok)
        let rows = try JSONCoding.decoder().decode([CLI.VariableRow].self, from: Data(harness.captured.stdout.utf8))
        #expect(rows.map(\.key) == ["API_TOKEN", "FEATURE_FLAG", "PROD_ONLY_KEY"])
        #expect(rows.map(\.state) == ["inherited", "inherited", "blocked"])
        #expect(rows.map(\.secret) == [true, false, true])
        #expect(rows[0].scope == "Product")
        #expect(rows[0].origin == "Keychain")
        #expect(rows[2].scope == nil)
        expectNoMarkers(harness.everything, "env list --json")
        #expect(!harness.everything.contains(SecretWorld.plainMarker))
        // The secret store was never asked for anything.
        #expect(harness.world.secrets.reads == 0)
    }

    @Test func envListInProductionShowsTheProductionDefinition() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["env", "list", harness.slug, "--environment", "production"]) == CLIExit.ok)
        let lines = harness.captured.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("API_TOKEN") && lines[0].contains("direct") && lines[0].contains("secret"))
        #expect(lines[1].hasPrefix("FEATURE_FLAG") && lines[1].contains("blocked") && lines[1].contains("plain"))
        #expect(lines[2].hasPrefix("PROD_ONLY_KEY") && lines[2].contains("inherited"))
        #expect(!harness.everything.contains(SecretWorld.plainMarker))
    }

    @Test func envUsageAndLookupErrors() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["env"]) == CLIExit.usage)
        #expect(await harness.cli.run(["env", "show", harness.slug]) == CLIExit.usage)
        #expect(await harness.cli.run(["env", "list", harness.slug]) == CLIExit.usage)
        #expect(harness.captured.stderr.contains("add --environment <name>. Acme API has: Local, Production"))
        #expect(await harness.cli.run(["env", "list", harness.slug, "--environment", "staging"]) == CLIExit.failure)
        #expect(await harness.cli.run(["env", "list", harness.slug, "--environment", "local", "--profile", "ghost"]) == CLIExit.failure)
        #expect(harness.captured.stderr.contains("Profiles: dev, prod, leaky"))
        #expect(harness.captured.stdout.isEmpty)
    }

    @Test func actionsListShowsProgramNamesNotArguments() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["actions", "list", harness.slug, "--json"]) == CLIExit.ok)
        let rows = try JSONCoding.decoder().decode([CLI.ActionRow].self, from: Data(harness.captured.stdout.utf8))
        #expect(rows.count == 1)
        #expect(rows[0].label == "Run Tests")
        #expect(rows[0].executor == "local")
        #expect(rows[0].program == "npm")
        #expect(rows[0].safety == "readOnly")
        #expect(rows[0].approved)
        #expect(rows[0].environment == "Local")
        #expect(rows[0].variables == ["API_TOKEN"])
        #expect(!harness.everything.contains(SecretWorld.argumentMarker))

        #expect(await harness.cli.run(["actions", "list", harness.slug]) == CLIExit.ok)
        #expect(harness.captured.stdout.hasSuffix("Run Tests"))
        #expect(await harness.cli.run(["actions", "list", "other-thing"]) == CLIExit.ok)
        #expect(harness.captured.stdout.hasSuffix("Other Thing has no actions."))
        #expect(await harness.cli.run(["actions"]) == CLIExit.usage)
        #expect(!harness.everything.contains(SecretWorld.argumentMarker))
    }

    @Test func contextDescribesTheProductWithoutValues() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["context", harness.slug]) == CLIExit.ok)
        let text = harness.captured.stdout
        #expect(text.hasPrefix("# Acme API"))
        #expect(text.contains("## Checkouts"))
        #expect(text.contains("main · 2 uncommitted"))
        #expect(text.contains("- Production (production)"))
        #expect(text.contains("forgedeck exec"))
        expectNoMarkers(text, "context")
        #expect(!text.contains(SecretWorld.plainMarker) && !text.contains(SecretWorld.argumentMarker))
    }

    @Test func noReadCommandPrintsASecretValue() async throws {
        let commands: [[String]] = [
            ["help"], ["version"], ["list"], ["list", "--json"],
            ["status", "acme-api"], ["status", "acme-api", "--json"],
            ["env", "list", "acme-api", "--environment", "local"], ["env", "list", "acme-api", "--environment", "local", "--json"],
            ["env", "list", "acme-api", "--environment", "production"], ["env", "list", "acme-api", "--environment", "production", "--json"],
            ["env", "list", "acme-api", "--environment", "local", "--profile", "dev"],
            ["env", "list", "acme-api", "--environment", "production", "--profile", "prod", "--json"],
            ["env", "list", "acme-api", "--environment", "local", "--profile", "leaky", "--json"],
            ["actions", "list", "acme-api"], ["actions", "list", "acme-api", "--json"],
            ["context", "acme-api"],
        ]
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        for command in commands {
            #expect(await harness.cli.run(command) == CLIExit.ok, "\(command)")
        }
        #expect(!harness.captured.stdout.isEmpty)
        expectNoMarkers(harness.captured.stdout, "stdout")
        expectNoMarkers(harness.captured.stderr, "stderr")
        #expect(harness.world.secrets.reads == 0)
        // Nothing in the read commands wrote to the store.
        #expect(!FileManager.default.fileExists(atPath: harness.cli.store.location.auditURL.path))
    }
}

@Suite struct CLIExecTests {
    @Test func aGrantedExecStartsTheProgramAndReturnsItsExitCode() async throws {
        let harness = try CLIHarness(exitCode: 3)
        defer { harness.cleanUp() }
        let code = await harness.cli.run(["exec", "--product", harness.slug, "--environment", "local", "--profile", "dev", "--", "env", "-i", "--flag"])
        #expect(code == 3)
        let plan = try #require(harness.spawned.plans.first)
        #expect(harness.spawned.plans.count == 1)
        #expect(plan.executable.path == "/usr/bin/env")
        #expect(plan.arguments == ["-i", "--flag"])
        #expect(plan.environment["API_TOKEN"] == SecretWorld.devMarker)
        #expect(!plan.environment.values.contains(SecretWorld.prodMarker))
        // Names on stderr, values nowhere.
        #expect(harness.captured.stderr == "forgedeck: env receives API_TOKEN, FEATURE_FLAG (Local)")
        #expect(harness.captured.stdout.isEmpty)
        expectNoMarkers(harness.everything, "exec output")
        #expect(!harness.everything.contains(SecretWorld.plainMarker))

        let events = harness.auditLog.read()
        #expect(events.map(\.action) == ["exec.finished", "exec.granted"])
        #expect(events[0].outcome == "failed")
        #expect(events[0].detail == "program=env exit=3")
        let audit = try String(contentsOf: harness.auditLog.url, encoding: .utf8)
        expectNoMarkers(audit, "audit.jsonl")
        #expect(!audit.contains(SecretWorld.plainMarker))
    }

    @Test func aDevelopmentProfileForgedOntoProductionIsDenied() async throws {
        let harness = try CLIHarness(authorizer: FixedAuthorizer(true))
        defer { harness.cleanUp() }
        let code = await harness.cli.run(["exec", "--product", harness.slug, "--environment", "production", "--profile", "dev", "--", "env"])
        #expect(code == 77)
        #expect(harness.spawned.plans.isEmpty)
        #expect(harness.world.secrets.reads == 0)
        #expect(harness.captured.stderr.hasPrefix("denied: Profile \"dev\" belongs to another environment"))
        #expect(harness.auditLog.read().map(\.action) == ["exec.denied"])
    }

    @Test func aProfileOfAnotherProductIsDenied() async throws {
        let harness = try CLIHarness(authorizer: FixedAuthorizer(true))
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["exec", "--product", harness.slug, "--environment", "local", "--profile", "otherprof", "--", "env"]) == 77)
        // And the other way round: the other product has no profile called "dev".
        #expect(await harness.cli.run(["exec", "--product", "other-thing", "--environment", "local", "--profile", "dev", "--", "env"]) == 77)
        #expect(harness.spawned.plans.isEmpty)
        #expect(harness.world.secrets.reads == 0)
        #expect(harness.auditLog.read().count == 2)
    }

    @Test(arguments: [
        ["--product", "acme-api", "--environment", "production", "--profile", "dev", "--", "env"],
        ["--product", "acme-api", "--environment", "production", "--profile", "prod", "--", "env"],        // no Touch ID answer
        ["--product", "acme-api", "--environment", "local", "--profile", "leaky", "--", "env"],
        ["--product", "acme-api", "--environment", "local", "--profile", "dev", "--", "/bin/sh", "-c", "env"],
        ["--product", "acme-api", "--environment", "local", "--profile", "dev", "--", "env; id"],
        ["--product", "acme-api", "--environment", "local", "--profile", "dev", "--profile", "ghost", "--", "env"],
        ["--product", "acme-api", "--environment", "local", "--environment", "production", "--profile", "dev", "--", "env"],
        ["--product", "acme-api", "--environment", "staging", "--profile", "dev", "--", "env"],
        ["--product", "old-thing", "--environment", "local", "--profile", "dev", "--", "env"],
        ["--product", "nope-zz", "--environment", "local", "--profile", "dev", "--", "env"],
        ["--product", "acme-api", "--environment", "local", "--profile", "prod", "--", "env"],
    ])
    func forgedFlagsNeverEscalate(arguments: [String]) async throws {
        let harness = try CLIHarness(authorizer: FixedAuthorizer(false))
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["exec"] + arguments) == 77)
        #expect(harness.spawned.plans.isEmpty)
        #expect(harness.world.secrets.reads == 0)
        #expect(harness.captured.stderr.hasPrefix("denied: "))
        #expect(harness.captured.stdout.isEmpty)
        expectNoMarkers(harness.everything, "denial output")
        let events = harness.auditLog.read()
        #expect(events.count == 1)
        #expect(events.first?.action == "exec.denied")
        #expect(events.first?.actor == "cli")
    }

    @Test(arguments: [
        [],
        ["--product", "acme-api"],
        ["--product", "acme-api", "--environment", "local", "--profile", "dev"],
        ["--product", "acme-api", "--environment", "local", "--profile", "dev", "--"],
        ["--environment", "local", "--profile", "dev", "--", "env"],
        ["--product", "acme-api", "--profile", "dev", "--", "env"],
        ["--product", "acme-api", "--environment", "local", "--", "env"],
        ["acme-api", "local", "dev", "env"],
    ])
    func incompleteExecIsAUsageErrorAndStartsNothing(arguments: [String]) async throws {
        let harness = try CLIHarness(authorizer: FixedAuthorizer(true))
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["exec"] + arguments) == 64)
        #expect(harness.spawned.plans.isEmpty)
        #expect(harness.world.secrets.reads == 0)
        #expect(harness.captured.stderr.hasPrefix("usage: forgedeck exec"))
    }

    @Test func flagsAfterTheSeparatorBelongToTheProgram() async throws {
        let harness = try CLIHarness(authorizer: FixedAuthorizer(true))
        defer { harness.cleanUp() }
        let code = await harness.cli.run(["exec", "--product", harness.slug, "--environment", "local", "--profile", "dev", "--",
                                          "env", "--environment", "production", "--profile", "prod"])
        #expect(code == 0)
        let plan = try #require(harness.spawned.plans.first)
        #expect(plan.arguments == ["--environment", "production", "--profile", "prod"])
        #expect(plan.environmentName == "Local")
        #expect(!plan.isProduction)
        #expect(plan.environment["API_TOKEN"] == SecretWorld.devMarker)
    }

    @Test func productionExecWithAuthenticationIsGranted() async throws {
        let harness = try CLIHarness(authorizer: FixedAuthorizer(true))
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["exec", "--product", harness.slug, "--environment", "production", "--profile", "prod", "--", "env"]) == 0)
        let plan = try #require(harness.spawned.plans.first)
        #expect(plan.isProduction)
        #expect(plan.environment["API_TOKEN"] == SecretWorld.prodMarker)
        #expect(harness.captured.stderr == "forgedeck: env receives API_TOKEN (Production)")
        expectNoMarkers(harness.everything, "exec output")
        #expect(harness.auditLog.read().first?.outcome == "ok")
    }
}

@Suite struct CLIOpenTests {
    @Test func openHandsTheCheckoutFolderToTheTerminal() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["open", harness.slug]) == CLIExit.ok)
        #expect(harness.captured.stdout == "Opened api in Terminal.")
        #expect(harness.opener.opened.first?.items.map(\.path) == [harness.directory.path])
        #expect(harness.opener.opened.first?.app.lastPathComponent == "com.apple.Terminal.app")
        #expect(harness.auditLog.read().map(\.action) == ["open"])
    }

    @Test func openWithEditorAndNamedTerminal() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["open", harness.slug, "--editor"]) == CLIExit.ok)
        #expect(await harness.cli.run(["open", harness.slug, "--terminal", "ghost", "--checkout", "API"]) == CLIExit.ok)
        #expect(harness.opener.opened.map(\.app.lastPathComponent) == ["com.microsoft.VSCode.app", "com.mitchellh.ghostty.app"])
        #expect(await harness.cli.run(["open", harness.slug, "--terminal", "nonesuch"]) == CLIExit.usage)
        #expect(await harness.cli.run(["open", harness.slug, "--checkout", "nonesuch"]) == CLIExit.failure)
        #expect(harness.captured.stderr.contains("no checkout \"nonesuch\". Acme API has: api"))
        #expect(await harness.cli.run(["open", "other-thing"]) == CLIExit.failure)
        #expect(harness.captured.stderr.contains("has no local checkout"))
        #expect(harness.opener.opened.count == 2)
    }

    @Test func aFailedOpenPrintsTheCommandToRunInstead() async throws {
        let harness = try CLIHarness(opener: FakeOpener(installed: []))
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["open", harness.slug]) == CLIExit.failure)
        #expect(harness.captured.stderr.contains("Terminal is not installed."))
        #expect(harness.captured.stderr.contains("cd -- \(ShellQuote.quote(harness.directory.path))"))
        #expect(harness.captured.stdout.isEmpty)
        #expect(harness.auditLog.read().isEmpty)
    }
}

@Suite struct CLIIssueTests {
    @Test func issueAddQueuesTheItemForTheAppAndChangesNoPortfolioFile() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        let location = StoreLocation(directory: harness.directory.appending(path: "data", directoryHint: .isDirectory))
        let before = try Data(contentsOf: location.portfolioURL)
        #expect(await harness.cli.run(["issue", "add", harness.slug, "Export", "drops", "the", "last", "row", "--notes", "Seen on Safari."]) == CLIExit.ok)
        #expect(harness.captured.stdout.contains("Added \u{201C}Export drops the last row\u{201D}"))
        #expect(try Data(contentsOf: location.portfolioURL) == before)

        let pending = IssueInbox.pending(location).items
        #expect(pending.count == 1)
        #expect(pending.first?.entry.productID == harness.world.product.id)
        #expect(pending.first?.entry.issue.title == "Export drops the last row" && pending.first?.entry.issue.notes == "Seen on Safari.")
        #expect(harness.auditLog.read().contains { $0.actor == "cli" && $0.action == "issue.add" && $0.product == harness.slug })

        // The same open title again is refused; the list shows the queued item.
        #expect(await harness.cli.run(["issue", "add", harness.slug, "export drops the last row"]) == CLIExit.failure)
        #expect(IssueInbox.pending(location).items.count == 1)
        #expect(await harness.cli.run(["issue", "list", harness.slug]) == CLIExit.ok)
        #expect(harness.captured.stdout.contains("queued  Export drops the last row"))
    }

    @Test func issueAddNeedsTextAndARealProduct() async throws {
        let harness = try CLIHarness()
        defer { harness.cleanUp() }
        #expect(await harness.cli.run(["issue", "add", harness.slug]) == CLIExit.usage)
        #expect(await harness.cli.run(["issue", "add", "no-such-product", "Fix it"]) == CLIExit.failure)
        #expect(harness.captured.stderr.contains("no product"))
    }

    @Test func theAppAddsQueuedItemsOnceAndDropsThoseForMissingProducts() throws {
        let directory = try makeTempDir("inbox")
        defer { removeTemp(directory) }
        let location = StoreLocation(directory: directory)
        var portfolio = Portfolio()
        var product = Product(name: "Lumen")
        product.slug = "lumen"
        product.issues = [ProductIssue(title: "Older", createdAt: Date(timeIntervalSince1970: 1))]
        var demo = Product(name: "Demo")
        demo.slug = "demo"
        demo.isDemo = true
        portfolio.products = [product, demo]

        let first = try #require(ProductIssues.make(from: "First", now: Date(timeIntervalSince1970: 10)))
        let second = try #require(ProductIssues.make(from: "Second\nwith notes", now: Date(timeIntervalSince1970: 20)))
        try IssueInbox.add(second, to: product, location: location)
        try IssueInbox.add(first, to: product, location: location)
        try IssueInbox.add(try #require(ProductIssues.make(from: "For the demo")), to: demo, location: location)
        try Data("not json".utf8).write(to: IssueInbox.directory(location).appending(path: "broken.json"))

        let (pending, unreadable) = IssueInbox.pending(location)
        #expect(pending.map(\.entry.issue.title) == ["First", "Second", "For the demo"] && unreadable.count == 1)
        let outcome = IssueInbox.apply(pending, to: &portfolio)
        #expect(outcome.count == 2 && outcome.dropped.map(\.productSlug) == ["demo"])
        #expect(portfolio.products[0].issues?.map(\.title) == ["Second", "First", "Older"])
        #expect(portfolio.products[0].issues?.first?.notes == "with notes" && portfolio.products[0].issues?.first?.id == second.id)
        #expect(portfolio.products[1].issues == nil)

        // Applied again (the app quit before deleting the files): nothing is added twice.
        #expect(IssueInbox.apply(pending, to: &portfolio).count == 0)
        IssueInbox.remove(pending.map(\.url) + unreadable)
        #expect(IssueInbox.pending(location).items.isEmpty && IssueInbox.pending(location).unreadable.isEmpty)
    }
}
