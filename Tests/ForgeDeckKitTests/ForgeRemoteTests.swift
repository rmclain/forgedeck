import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ForgeRemoteTests {
    private func product(_ name: String, slug: String, path: String?, demo: Bool = false, lifecycle: Lifecycle = .active) -> Product {
        var product = Product(name: name)
        product.slug = slug
        product.isDemo = demo
        product.lifecycle = lifecycle
        if let path {
            var checkout = LocalCheckout()
            checkout.name = name
            checkout.path = path
            product.checkouts = [checkout]
        }
        return product
    }

    private var portfolio: Portfolio {
        var portfolio = Portfolio()
        portfolio.products = [
            product("Zeta Site", slug: "zeta", path: "/tmp/fd-remote/zeta"),
            product("Alpha API", slug: "alpha", path: "/tmp/fd-remote/alpha"),
            product("Demo Thing", slug: "demo-thing", path: "/tmp/fd-remote/demo", demo: true),
            product("Old Thing", slug: "old", path: "/tmp/fd-remote/old", lifecycle: .archived),
            product("Cloud Only", slug: "cloud", path: nil),
        ]
        return portfolio
    }

    @Test func onlyRealActiveProductsWithAFolderAreReachable() {
        #expect(ForgeRemote.products(in: portfolio).map(\.slug) == ["alpha", "zeta"])
    }

    @Test func theCommandIsAServerThatAsksBeforeChangesByDefault() {
        let argv = ForgeRemote.command(program: URL(fileURLWithPath: "/usr/local/bin/claude"), settings: ForgeRemoteSettings())
        #expect(argv == ["/usr/local/bin/claude", "remote-control", "--no-create-session-in-dir", "--remote-control-session-name-prefix", "Forge Session",
                         "--permission-mode", "default", "--spawn", "same-dir"])
        #expect(!argv.contains("bypassPermissions"))
    }

    @Test func anUnknownModeFallsBackToAskingAndANameIsTrimmed() {
        var settings = ForgeRemoteSettings()
        settings.permissionMode = "bypassPermissions"
        settings.name = "  \n  "
        #expect(settings.mode == .ask)
        #expect(ForgeRemote.sessionName(settings) == "Forge Session")
        settings.name = "Mac Studio\nForge"
        #expect(ForgeRemote.sessionName(settings) == "Mac StudioForge")
        #expect(!ForgeRemoteSettings.Mode.allCases.map(\.rawValue).contains("bypassPermissions"))
    }

    @Test func theBriefingIsShortAndSendsTheAgentToTheSkill() {
        let context = ContextLocation(root: URL(fileURLWithPath: "/tmp/fd-remote/context"))
        let text = ForgeRemoteWorkspace.briefing(portfolio: portfolio, context: context, cli: "/Users/me/.local/bin/forgedeck", machine: "Studio")
        #expect(text.contains("`forgedeck` skill"))
        #expect(text.contains("(2 on this Mac)"))
        #expect(text.contains("One product per session"))
        #expect(!text.contains("/tmp/fd-remote/alpha"))
        #expect(text.count < 1_000)
    }

    @Test func theSkillRoutesByTaskThroughTheCLIAndNeverReplacesAForeignSkill() throws {
        let text = ForgeDeckSkill.text(cli: "/Users/me/.local/bin/forgedeck")
        #expect(text.hasPrefix("---\nname: forgedeck\ndescription: "))
        #expect(text.contains("`/Users/me/.local/bin/forgedeck context <slug> --write`"))
        #expect(text.contains("status <slug> --json"))
        #expect(text.contains("ci <slug> --brief"))
        #expect(ForgeDeckSkill.text(cli: "/Apps/My Forge/forgedeck").contains("`\"/Apps/My Forge/forgedeck\" find"))

        let skills = FileManager.default.temporaryDirectory.appending(path: "fd-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: skills) }
        #expect(try ForgeDeckSkill.install(in: skills, cli: "forgedeck"))
        #expect(try !ForgeDeckSkill.install(in: skills, cli: "forgedeck"))
        #expect(ForgeDeckSkill.isInstalled(in: skills))
        for command in ForgeDeckSkill.commandNames {
            #expect(FileManager.default.fileExists(atPath: skills.appending(path: "\(command)/SKILL.md").path), "\(command)")
        }
        try ForgeDeckSkill.remove(from: skills)
        #expect(!ForgeDeckSkill.isInstalled(in: skills))
        #expect(!FileManager.default.fileExists(atPath: skills.appending(path: "product").path))

        // Someone's own /product skill is left alone; the rest still installs.
        let theirs = skills.appending(path: "product")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try "---\nname: product\n---\ntheirs".write(to: theirs.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(try ForgeDeckSkill.install(in: skills, cli: "forgedeck"))
        try ForgeDeckSkill.remove(from: skills)
        #expect(try String(contentsOf: theirs.appending(path: "SKILL.md"), encoding: .utf8).hasSuffix("theirs"))
        try FileManager.default.removeItem(at: theirs)

        let foreign = skills.appending(path: "forgedeck")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try "---\nname: forgedeck\n---\nmine".write(to: foreign.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try ForgeDeckSkill.install(in: skills, cli: "forgedeck") }
        try ForgeDeckSkill.remove(from: skills)
        #expect(FileManager.default.fileExists(atPath: foreign.appending(path: "SKILL.md").path))
    }

    @Test func theSlashCommandsAreTypedByThePersonAndResolveThroughFind() {
        let list = ForgeDeckSkill.listCommand(cli: "forgedeck")
        #expect(list.hasPrefix("---\nname: products\n") && list.contains("disable-model-invocation: true") && list.contains("`forgedeck find`"))
        let pick = ForgeDeckSkill.pickCommand(cli: "/Apps/My Forge/forgedeck")
        #expect(pick.hasPrefix("---\nname: product\n") && pick.contains("disable-model-invocation: true") && pick.contains("$ARGUMENTS"))
        #expect(pick.contains("`\"/Apps/My Forge/forgedeck\" find <what they typed>`") && pick.contains("Exit 2: several fit"))
        #expect(pick.contains("context <slug> --write") && pick.contains("ask before switching"))
        let briefing = ForgeRemoteWorkspace.briefing(portfolio: Portfolio(), context: ContextLocation(root: URL(fileURLWithPath: "/tmp/c")),
                                                     cli: "forgedeck", machine: "Studio")
        #expect(briefing.contains("`/products`") && briefing.contains("`forgedeck find <their words>`"))
    }

    @Test func folderAccessCoversEveryProductFolderAndTheContextFolder() throws {
        let context = ContextLocation(root: URL(fileURLWithPath: "/tmp/fd-remote/context"))
        let data = try ForgeRemoteWorkspace.settings(portfolio: portfolio, context: context)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let folders = (object["permissions"] as? [String: Any])?["additionalDirectories"] as? [String]
        #expect(folders == ["/tmp/fd-remote/alpha", "/tmp/fd-remote/zeta", "/tmp/fd-remote/context"])
    }

    @Test func aServerLeftInTheWorkspaceIsFoundByItsFolderAndArguments() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fd-leftover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["37"]
        process.currentDirectoryURL = folder
        try process.run()
        defer { process.terminate() }
        let pid = process.processIdentifier
        #expect(ProcessInspector.workingDirectory(of: pid).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == folder.resolvingSymlinksInPath().path)
        #expect(ProcessInspector.arguments(of: pid) == ["/bin/sleep", "37"])
        #expect(ProcessInspector.processes(running: ["sleep", "37"], in: folder.path) == [pid])
        #expect(ProcessInspector.processes(running: ["sleep", "38"], in: folder.path).isEmpty)
        #expect(ProcessInspector.processes(running: ["sleep", "37"], in: FileManager.default.temporaryDirectory.path).isEmpty)
        #expect(ForgeRemote.leftoverServers(in: ForgeRemoteWorkspace(folder: folder)).isEmpty)
        #expect(ProcessInspector.contains(["/Users/me/.local/bin/claude", "remote-control", "--spawn", "same-dir"], ["claude", "remote-control"]))
        #expect(!ProcessInspector.contains(["/usr/bin/claude"], ["claude", "remote-control"]))
    }

    @Test func readOnlyLookupsRunWithoutAskingAndExecStillAsks() throws {
        let context = ContextLocation(root: URL(fileURLWithPath: "/tmp/fd-remote/context"))
        let data = try ForgeRemoteWorkspace.settings(portfolio: portfolio, context: context, cli: "/Users/me/.local/bin/forgedeck")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allow = try #require((object["permissions"] as? [String: Any])?["allow"] as? [String])
        let tool = "/Users/me/.local/bin/forgedeck"
        for rule in ["Bash(\(tool) context *)", "Bash(\(tool) find *)", "Bash(\(tool) find)", "Bash(\(tool) status *)", "Bash(\(tool) ci * --brief)"] {
            #expect(allow.contains(rule), "\(rule)")
        }
        #expect(!allow.contains { $0.contains(" exec") || $0.contains(" agent") || $0.contains(" open") || $0.contains(" link ") || $0.contains("ci *)") })

        let pick = ForgeDeckSkill.pickCommand(cli: tool)
        #expect(pick.contains("allowed-tools: ") && pick.contains("\"Bash(\(tool) context *)\""))
        #expect(ForgeDeckSkill.text(cli: tool).contains("allowed-tools: "))
        #expect(ForgeDeckSkill.allowRules(cli: "/Apps/My Forge/forgedeck").contains("Bash(\"/Apps/My Forge/forgedeck\" find *)"))
    }

    @Test func writingTwiceReportsNoChangeAndOldSettingsStillLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fd-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = ForgeRemoteWorkspace(folder: folder)
        let context = ContextLocation(root: folder.appending(path: "context"))
        #expect(try workspace.write(portfolio: portfolio, context: context, cli: nil, machine: "Studio"))
        #expect(try !workspace.write(portfolio: portfolio, context: context, cli: nil, machine: "Studio"))
        #expect(FileManager.default.fileExists(atPath: workspace.settingsFile.path))
        #expect(ForgeDeckSkill.isInstalled(in: workspace.skillsFolder))

        let old = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings()))
        #expect(old.remote == nil)
        let partial = try JSONDecoder().decode(ForgeRemoteSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(partial.enabled && partial.keepAwake && partial.mode == .ask && partial.name == "Forge Session")
    }
}

@Suite struct PipeReadTests {
    /// A process that floods its pipe and exits at once used to crash the app: a queued read hit a pipe that had just
    /// been made non-blocking, and `availableData` raised an exception.
    @Test func manyFastProcessesWithLotsOfOutputNeverCrashAndLoseNothing() async throws {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "300000", "/dev/zero"], timeout: 20)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<40 { group.addTask { try await SystemProcessRunner().run(request).stdout.utf8.count } }
            for try await count in group { #expect(count == 300_000) }
        }
    }
}

@Suite struct EnvironmentProposalTests {
    private func product() -> Product {
        var product = Product(name: "Acme")
        product.slug = "acme"
        var production = ProductEnvironment(name: "Production", tier: .production)
        production.domains = ["acme.example"]
        product.environments = [ProductEnvironment(name: "Local", tier: .development), production]
        return product
    }

    @Test func theFileIsParsedAndBadFilesSayWhy() {
        let good = EnvironmentProposals.parse(Data(#"{"environments":[{"tier":"production","domains":["acme.example"]}]}"#.utf8))
        #expect(good.error == nil && good.entries.count == 1)
        #expect(EnvironmentProposals.parse(Data("[]".utf8)).error != nil)
        let many = "{\"environments\":[" + Array(repeating: #"{"tier":"custom"}"#, count: 11).joined(separator: ",") + "]}"
        #expect(EnvironmentProposals.parse(Data(many.utf8)).error != nil)
    }

    @Test func anExistingProductionGainsOnlyWhatIsMissing() {
        var product = product()
        let entry = ProposedEnvironment(tier: "prod", domains: ["ACME.example", "www.acme.example"], versionURL: "https://acme.example/forgedeck-release.json")
        let proposal = EnvironmentProposals.check(entry, in: product)
        #expect(proposal.tier == .production)
        #expect(proposal.existingID == product.environments[1].id)
        #expect(proposal.changes == ["Domain www.acme.example", "Version URL https://acme.example/forgedeck-release.json"])
        EnvironmentProposals.apply(proposal, to: &product)
        #expect(product.environments.count == 2)
        #expect(product.environments[1].domains == ["acme.example", "www.acme.example"])
        #expect(product.environments[1].probes.map(\.kind) == [.release])
        // Applying the same file again changes nothing.
        #expect(EnvironmentProposals.check(entry, in: product).changes.isEmpty)
    }

    @Test func aNewEnvironmentIsAddedWithItsChecks() {
        var product = product()
        let proposal = EnvironmentProposals.check(ProposedEnvironment(name: "Preview", tier: "preview", healthURL: "https://preview.acme.example/health"), in: product)
        #expect(proposal.existingID == nil && proposal.isAddable)
        EnvironmentProposals.apply(proposal, to: &product)
        #expect(product.environments.last?.name == "Preview")
        #expect(product.environments.last?.probes.first?.kind == .health)
    }

    @Test func badValuesAreProblemsAndCannotBeAdded() {
        var product = product()
        let entry = ProposedEnvironment(tier: "live", domains: ["https://acme.example/"], versionURL: "http://acme.example/v", healthURL: "https://user:pw@acme.example/",
                                        github: "prod")
        let proposal = EnvironmentProposals.check(entry, in: product)
        #expect(!proposal.isAddable)
        #expect(proposal.problems.count == 5)
        let before = product.environments
        EnvironmentProposals.apply(proposal, to: &product)
        #expect(product.environments == before)
    }

    @Test func theFileIsReadFromTheCheckout() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fd-envs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(EnvironmentProposals.read(folder: folder.path) == nil)
        try FileManager.default.createDirectory(at: folder.appending(path: ".forgedeck"), withIntermediateDirectories: true)
        try #"{"environments":[{"tier":"staging","domains":["staging.acme.example"]}]}"#.write(to: folder.appending(path: EnvironmentProposals.relativePath), atomically: true, encoding: .utf8)
        var product = product()
        var checkout = LocalCheckout()
        checkout.path = folder.path
        product.checkouts = [checkout]
        let files = EnvironmentProposals.read(product)
        let plan = EnvironmentProposals.plan(product, files: files)
        #expect(plan.map(\.name) == ["Staging"])
        #expect(plan.first?.changes.first == "New Staging environment \"Staging\"")
    }

    @Test func aServedWordPressReadmeNamesTheRelease() {
        let readme = "=== Acme Tools ===\nContributors: acme\nTags: tools\nStable tag: 2.4.1\nLicense: GPLv2\n\n== Description ==\nVersion: 9.9 in prose\n"
        #expect(ReleaseMarker.read(body: Data(readme.utf8), headers: [:]).version == "2.4.1")
        #expect(ReleaseMarker.read(body: Data("Name: Acme\nVersion: 1.3.0\n".utf8), headers: [:]).version == "1.3.0")
        #expect(ReleaseMarker.read(body: Data("Stable tag: trunk\n".utf8), headers: [:]).version == nil)
        #expect(ReleaseMarker.read(body: Data("<html><body>Version: 1.0</body></html>".utf8), headers: [:]).version == nil)
    }

    @Test func theSkillAndContextExplainHowToProposeProduction() {
        #expect(ForgeDeckSkill.text(cli: "forgedeck").contains("forgedeck env check <slug>"))
        #expect(ForgeDeckSkill.text(cli: "forgedeck").contains(".forgedeck/environments.json"))
    }
}

@Suite struct RunSetupTests {
    private func setup() throws -> (product: Product, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fd-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "web"), withIntermediateDirectories: true)
        var product = Product(name: "Acme")
        product.slug = "acme"
        var checkout = LocalCheckout()
        checkout.name = "acme"
        checkout.path = folder.path
        product.checkouts = [checkout]
        product.environments = [ProductEnvironment(name: "Local", tier: .development)]
        return (product, folder)
    }

    private func check(_ entry: ProposedRun, _ product: Product, _ folder: URL) -> RunProposal {
        RunSetup.check(entry, in: product, checkoutID: product.checkouts[0].id, checkoutPath: folder.path)
    }

    @Test func aWebCommandBecomesAnApprovedPlayRecipeThatPlayRunsFirst() throws {
        var (product, folder) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }
        let proposal = check(ProposedRun(label: "Start Dev Server", kind: "web", steps: [["git", "status"], ["git", "log"]], directory: "web",
                                         url: "http://localhost:5173", variables: ["DATABASE_URL"]), product, folder)
        #expect(proposal.problems.isEmpty && proposal.isAddable)
        #expect(proposal.recipe.isApproved && proposal.recipe.opensInTerminal && proposal.recipe.play == .web)
        #expect(proposal.recipe.steps == [["git", "status"], ["git", "log"]])
        #expect(proposal.recipe.workingSubdirectory == "web" && proposal.recipe.variableKeys == ["DATABASE_URL"])
        #expect(proposal.recipe.environmentID == product.environments[0].id)
        RunSetup.apply(proposal, to: &product)
        let options = PlayPlanner.options(for: product, localSites: [])
        #expect(options.first?.title == "Start Dev Server")
        #expect(options.first?.url == "http://localhost:5173")
        // Proposing the same thing again changes nothing; a changed command replaces the saved one.
        #expect(!check(proposal.entry, product, folder).changes)
        var changed = proposal.entry
        changed.steps = [["git", "diff"]]
        let again = check(changed, product, folder)
        #expect(again.existingID == product.recipes[0].id && again.isAddable)
        RunSetup.apply(again, to: &product)
        #expect(product.recipes.count == 1 && product.recipes[0].steps == [["git", "diff"]])
    }

    @Test func testsAreActionsAndASiteOnlyOpensItsPage() throws {
        var (product, folder) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tests = check(ProposedRun(label: "Run Tests", steps: [["git", "status"]]), product, folder)
        #expect(tests.recipe.play == nil && !tests.recipe.opensInTerminal && tests.isAddable)
        let site = check(ProposedRun(label: "Open Site", kind: "site", url: "http://acme.local/"), product, folder)
        #expect(site.isAddable && site.recipe.executor == .openURL)
        RunSetup.apply(tests, to: &product)
        RunSetup.apply(site, to: &product)
        let options = PlayPlanner.options(for: product, localSites: [])
        #expect(options.map(\.title) == ["Open Site"])
        #expect(options.first?.url == nil && options.first?.recipeID == product.recipes[1].id)
    }

    @Test func shellStringsRemoteCommandsAndEscapesAreRefused() throws {
        let (product, folder) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cases: [ProposedRun] = [
            ProposedRun(label: "Dev", kind: "web", steps: [["bash", "-c", "npm i && npm run dev"]]),
            ProposedRun(label: "Ship", steps: [["npx", "vercel", "deploy"]]),
            ProposedRun(label: "Push", steps: [["git", "push"]]),
            ProposedRun(label: "Up", steps: [["/usr/bin/env", "true"]]),
            ProposedRun(label: "Out", steps: [["git", "status"]], directory: "../other"),
            ProposedRun(label: "Missing", steps: [["git", "status"]], directory: "nope"),
            ProposedRun(label: "Remote page", kind: "web", steps: [["git", "status"]], url: "https://acme.example"),
            ProposedRun(label: "Nothing", kind: "web"),
            ProposedRun(label: "Bad kind", kind: "server", steps: [["git", "status"]]),
            ProposedRun(label: "Secret", steps: [["git", "status"]], variables: ["sk-live=abc"]),
            ProposedRun(label: "", steps: [["git", "status"]]),
        ]
        for entry in cases {
            let proposal = check(entry, product, folder)
            #expect(!proposal.isAddable, "\(entry.label) should be refused")
        }
        #expect(RunSetup.parse(Data(#"{"commands":[{"label":"x"}]}"#.utf8)).error == nil)
        #expect(RunSetup.parse(Data(#"{"environments":[]}"#.utf8)).error != nil)
    }

    @Test func theFileIsReadAndThePromptCarriesWhatForgeDeckKnows() throws {
        let (product, folder) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: ".forgedeck"), withIntermediateDirectories: true)
        try #"{"commands":[{"label":"Run Tests","steps":[["git","status"]]}]}"#.write(to: folder.appending(path: RunSetup.relativePath), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let plan = RunSetup.plan(product, files: RunSetup.read(product))
        #expect(plan.map(\.recipe.label) == ["Run Tests"])
        let prompt = RunSetup.prompt(for: product, checkout: product.checkouts[0], cli: "/Users/me/.local/bin/forgedeck", localSite: nil)
        #expect(prompt.contains(folder.path))
        #expect(prompt.contains("package.json"))
        #expect(prompt.contains("/Users/me/.local/bin/forgedeck run check acme"))
        #expect(prompt.contains(RunSetup.relativePath))
        #expect(ForgeDeckSkill.text(cli: "forgedeck").contains("forgedeck run check <slug>"))
    }

    @Test func oldRecipesStillLoad() throws {
        let data = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"x","executor":"local","executable":"git","arguments":[],"workingSubdirectory":"","variableKeys":[],"safety":"readOnly","timeoutSeconds":600,"isApproved":false,"isSuggested":false,"opensInTerminal":false}"#.utf8)
        let recipe = try JSONDecoder().decode(ActionRecipe.self, from: data)
        #expect(recipe.play == nil)
    }
}

@Suite struct LeadsSetupTests {
    @Test func tokensAreRandomAndOnlyTheirHashLeaves() {
        let a = LeadsSetup.generateToken(), b = LeadsSetup.generateToken()
        #expect(a != b && a.hasPrefix("fdk_") && a.count == 47)
        #expect(LeadsSetup.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(LeadsSetup.tokenVariable(for: .production) == "FORGEDECK_TOKEN_PRODUCTION")
    }

    @Test func thePromptLooksAndAsksBeforeItBuildsAndNeverHoldsTheToken() {
        var product = Product(name: "Acme")
        product.slug = "acme"
        var checkout = LocalCheckout()
        checkout.path = "/tmp/fd-leads/acme"
        product.checkouts = [checkout]
        var production = ProductEnvironment(name: "Production", tier: .production)
        production.domains = ["acme.example"]
        product.environments = [production]
        let token = LeadsSetup.generateToken()
        let prompt = LeadsSetup.prompt(for: product, environment: production, checkout: checkout, tokenVariable: "FORGEDECK_TOKEN_PRODUCTION",
                                       tokenHash: LeadsSetup.hash(token), cli: "forgedeck", localSite: nil)
        #expect(!prompt.contains(token))
        #expect(prompt.contains(LeadsSetup.hash(token)))
        #expect(prompt.contains("Stop and wait for my answer"))
        #expect(prompt.contains("WooCommerce") && prompt.contains("Gravity Forms") && prompt.contains("Stripe"))
        #expect(prompt.contains("forgedeck leads acme") && prompt.contains("forgedeck env check acme"))
        let again = LeadsSetup.prompt(for: product, environment: production, checkout: checkout, tokenVariable: "FORGEDECK_TOKEN_PRODUCTION",
                                      tokenHash: nil, cli: "forgedeck", localSite: nil)
        #expect(again.contains("already has a token"))
        #expect(ForgeDeckSkill.text(cli: "forgedeck").contains("forgedeck leads <slug>"))
    }

    @Test func anEnvironmentProposalAddsAMetricsSourceOnce() {
        var product = Product(name: "Acme")
        product.environments = [ProductEnvironment(name: "Production", tier: .production)]
        let entry = ProposedEnvironment(tier: "production", metricsURL: "https://acme.example/_forgedeck/v1/", metricsToken: "FORGEDECK_TOKEN_PRODUCTION")
        let proposal = EnvironmentProposals.check(entry, in: product)
        #expect(proposal.isAddable)
        #expect(proposal.changes == ["Leads and metrics from https://acme.example with FORGEDECK_TOKEN_PRODUCTION"])
        EnvironmentProposals.apply(proposal, to: &product)
        let source = product.environments[0].metricSources.first
        #expect(source?.bearerVariableKey == "FORGEDECK_TOKEN_PRODUCTION" && source?.leadsEnabled == true && source?.eventsEnabled == false)
        #expect(EnvironmentProposals.check(ProposedEnvironment(tier: "production", metricsURL: "https://ACME.example"), in: product).changes.isEmpty)
        let bad = EnvironmentProposals.check(ProposedEnvironment(tier: "production", metricsURL: "http://acme.example", metricsToken: "fdk_abc-123"), in: product)
        #expect(bad.problems.count == 2)
    }

    @Test func theReportSaysWhatArrived() {
        var product = Product(name: "Acme")
        var production = ProductEnvironment(name: "Production", tier: .production)
        var source = MetricSource()
        source.baseURL = "https://acme.example"
        production.metricSources = [source]
        product.environments = [production]
        var cache = ObservationCache()
        let now = Date.now
        var state = SyncState()
        state.lastAttempt = now.addingTimeInterval(-60)
        state.lastSuccess = state.lastAttempt
        cache.sync["metrics:\(source.id.uuidString)"] = state
        cache.sync["leads:\(source.id.uuidString)"] = state
        for (index, age) in ([600.0, 259_200.0, 1_728_000.0] as [Double]).enumerated() {
            var lead = LeadEvent()
            lead.id = "\(source.id):\(index)"
            lead.sourceID = source.id
            lead.occurredAt = now.addingTimeInterval(-age)
            cache.leads.append(lead)
        }
        var sample = MetricSample()
        sample.sourceID = source.id
        sample.key = "leads"
        sample.value = 4
        cache.metrics = [sample]
        let report = LeadsSetup.report(for: product, cache: cache, now: now)
        #expect(report.count == 1)
        #expect(report[0].leads24h == 1 && report[0].leads7d == 2 && report[0].problem == nil)
        #expect(report[0].counters == ["leads": 4])
        #expect(report[0].newestLead == now.addingTimeInterval(-600))
    }
}
