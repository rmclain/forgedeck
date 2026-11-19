import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ProjectGenesisTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "genesis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func product(at path: String, name: String = "Taken") -> Product {
        var product = Product(name: name)
        var checkout = LocalCheckout()
        checkout.path = path
        product.checkouts = [checkout]
        return product
    }

    // MARK: Names

    @Test func namesBecomeFolderAndModuleNames() {
        #expect(ProjectGenesis.folderName(for: "Subscription Desk!") == "subscription-desk")
        #expect(!ProjectGenesis.folderName(for: "   ").isEmpty)
        #expect(ProjectGenesis.moduleName(for: "subscription desk") == "SubscriptionDesk")
        #expect(ProjectGenesis.moduleName(for: "3d viewer") == "App3dViewer")
    }

    // MARK: Destination

    @Test func aNewFolderInAWritableParentIsAccepted() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let check = ProjectGenesis.check(GenesisRequest(name: "Desk", idea: "", parent: root.path, folder: "desk"), existing: [])
        #expect(check.canCreate)
        #expect(check.state == .new)
        #expect(check.path.hasSuffix("/desk"))
    }

    @Test func badNamesAndFoldersAreRefused() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["a/b", "..", ".hidden", "x:y", ""] {
            #expect(!ProjectGenesis.check(GenesisRequest(name: "Desk", idea: "", parent: root.path, folder: folder), existing: []).canCreate, "\(folder)")
        }
        #expect(!ProjectGenesis.check(GenesisRequest(name: "", idea: "", parent: root.path, folder: "desk"), existing: []).canCreate)
        #expect(!ProjectGenesis.check(GenesisRequest(name: "Desk", idea: "", parent: "relative/path", folder: "desk"), existing: []).canCreate)
        #expect(!ProjectGenesis.check(GenesisRequest(name: "Desk", idea: "", parent: root.appending(path: "missing").path, folder: "desk"), existing: []).canCreate)
        #expect(!ProjectGenesis.check(GenesisRequest(name: "Desk", idea: "", parent: "/usr/local", folder: "desk"), existing: []).canCreate)
    }

    @Test func collisionsAreRefusedAndNothingIsOverwritten() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try Data("x".utf8).write(to: root.appending(path: "file"))
        try fm.createDirectory(at: root.appending(path: "target"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "target"))
        try fm.createDirectory(at: root.appending(path: "busy"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: root.appending(path: "busy/notes.txt"))
        try fm.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "empty/.DS_Store"))

        func check(_ folder: String, existing: Bool = false, starter: GenesisStarter? = nil, products: [Product] = []) -> GenesisDestination {
            ProjectGenesis.check(GenesisRequest(name: "Desk", idea: "", parent: root.path, folder: folder, starter: starter, useExistingFolder: existing), existing: products)
        }
        #expect(!check("file").canCreate)
        #expect(!check("link").canCreate)
        #expect(!check("busy").canCreate)
        #expect(check("busy", existing: true).state == .notEmpty(1))
        #expect(check("busy", existing: true).warnings.contains { $0.contains("Nothing in it is changed") })
        #expect(!check("busy", existing: true, starter: GenesisStarter.find("nextjs")).canCreate, "a generator needs an empty folder")
        #expect(check("empty").state == .emptyFolder, ".DS_Store does not count")
        let owned = check("desk", products: [product(at: root.appending(path: "desk").path)])
        #expect(!owned.canCreate && owned.problems.contains { $0.contains("already belongs to Taken") })
        #expect(check("desk", products: [product(at: root.path, name: "Parent")]).warnings.contains { $0.contains("inside Parent") })
    }

    // MARK: Creating

    @Test func createMakesTheFolderFilesAndRepository() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner(result: ProcessResult(exitCode: 0))
        let request = GenesisRequest(name: "Press Kit", idea: "A plugin.\nMore.", parent: root.path, folder: "press-kit", starter: GenesisStarter.find("wordpress-plugin"))
        let creation = try await ProjectGenesis.create(request, existing: [], runner: runner, git: URL(fileURLWithPath: "/usr/bin/git"))
        #expect(creation.createdFolder && creation.gitInitialized)
        #expect(creation.wroteFiles == [".gitignore", "README.md", "press-kit.php"])
        let plugin = try String(contentsOf: root.appending(path: "press-kit/press-kit.php"), encoding: .utf8)
        #expect(plugin.contains("Plugin Name: Press Kit") && plugin.contains("Description: A plugin.") && plugin.contains("Text Domain: press-kit"))
        let ignore = try String(contentsOf: root.appending(path: "press-kit/.gitignore"), encoding: .utf8)
        #expect(ignore.contains(".env") && ignore.contains("vendor/"))
        #expect(runner.requests.first?.arguments == ["init", "--initial-branch=main"])
        #expect(runner.requests.first?.workingDirectory?.path == creation.path)

        let product = ProjectGenesis.product(for: request, creation: creation, existing: [])
        #expect(product.genesis?.starter == "wordpress-plugin" && product.genesis?.scaffoldExit == 0, "no generator: nothing to wait for")
        #expect(product.tagline == "A plugin." && product.stack == ["WordPress", "PHP"] && product.lifecycle == .idea)
        #expect(product.primaryCheckout?.path == creation.path)
    }

    @Test func createKeepsExistingFilesAndLeavesAGeneratorsFolderEmpty() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "old"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: root.appending(path: "old/README.md"))
        let runner = FakeRunner(result: ProcessResult(exitCode: 0))
        let existing = try await ProjectGenesis.create(GenesisRequest(name: "Old", idea: "", parent: root.path, folder: "old", useExistingFolder: true),
                                                       existing: [], runner: runner, git: URL(fileURLWithPath: "/usr/bin/git"))
        #expect(!existing.createdFolder && existing.wroteFiles == [".gitignore"])
        #expect(try String(contentsOf: root.appending(path: "old/README.md"), encoding: .utf8) == "mine")

        let generated = try await ProjectGenesis.create(GenesisRequest(name: "Web", idea: "", parent: root.path, folder: "web", starter: GenesisStarter.find("nextjs")),
                                                        existing: [], runner: runner, git: URL(fileURLWithPath: "/usr/bin/git"))
        #expect(generated.wroteFiles.isEmpty)
        let product = ProjectGenesis.product(for: GenesisRequest(name: "Web", idea: "", parent: root.path, folder: "web", starter: GenesisStarter.find("nextjs")),
                                             creation: generated, existing: [])
        #expect(product.genesis?.scaffoldExit == nil && product.genesis?.phase == .building)
    }

    @Test func aFailedGitStillCreatesTheProjectWithANote() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner(result: ProcessResult(exitCode: 128, stderr: "fatal: nope"))
        let creation = try await ProjectGenesis.create(GenesisRequest(name: "Desk", idea: "", parent: root.path, folder: "desk"),
                                                       existing: [], runner: runner, git: URL(fileURLWithPath: "/usr/bin/git"))
        #expect(!creation.gitInitialized && creation.notes.first?.contains("fatal: nope") == true)
        let none = try await ProjectGenesis.create(GenesisRequest(name: "Desk2", idea: "", parent: root.path, folder: "desk2"), existing: [], runner: runner, git: nil)
        #expect(none.notes.first?.contains("not installed") == true)
    }

    @Test func createRefusesAnInvalidDestinationWithoutTouchingIt() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let taken = product(at: root.appending(path: "desk").path)
        await #expect(throws: GenesisError.self) {
            _ = try await ProjectGenesis.create(GenesisRequest(name: "Desk", idea: "", parent: root.path, folder: "desk"), existing: [taken],
                                                runner: FakeRunner(result: ProcessResult(exitCode: 0)), git: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "desk").path))
    }

    @Test func removeIfOnlyOursKeepsAFolderWithOtherFiles() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let ours = root.appending(path: "ours"), shared = root.appending(path: "shared")
        for folder in [ours, shared] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appending(path: "README.md"))
        }
        try Data().write(to: shared.appending(path: "theirs.txt"))
        ProjectGenesis.removeIfOnlyOurs(ours, wrote: ["README.md"], fileManager: .default)
        ProjectGenesis.removeIfOnlyOurs(shared, wrote: ["README.md"], fileManager: .default)
        #expect(!FileManager.default.fileExists(atPath: ours.path))
        #expect(FileManager.default.fileExists(atPath: shared.appending(path: "theirs.txt").path))
    }

    // MARK: Starters

    @Test func everyStartersCommandsPassRunSetup() throws {
        var product = Product(name: "Desk")
        var checkout = LocalCheckout()
        checkout.path = "/tmp/desk"
        product.checkouts = [checkout]
        for starter in GenesisStarter.all {
            for command in starter.scaffold { #expect(!command.contains { $0.contains("&&") || $0.contains("|") || $0 == "-c" }, "\(starter.id)") }
            guard let data = ProjectGenesis.runFile(for: starter) else { continue }
            let parsed = RunSetup.parse(data)
            #expect(parsed.error == nil, "\(starter.id)")
            for entry in parsed.entries {
                #expect(RunSetup.check(entry, in: product, checkoutID: checkout.id, checkoutPath: checkout.path).problems.isEmpty, "\(starter.id) \(entry.label)")
            }
        }
        #expect(GenesisStarter.find("swift")!.scaffoldCommands(slug: "desk", module: "Desk") == [["swift", "package", "init", "--type", "executable", "--name", "Desk"]])
    }

    @Test func theRunFileIsNeverOverwritten() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let starter = GenesisStarter.find("go")!
        #expect(ProjectGenesis.writeRunFile(for: starter, in: root.path))
        #expect(!ProjectGenesis.writeRunFile(for: starter, in: root.path))
        #expect(!ProjectGenesis.writeRunFile(for: GenesisStarter.find("empty")!, in: try temporaryFolder().path))
    }

    // MARK: Blueprint

    private var valid: Blueprint {
        Blueprint(summary: "A subscriptions app.", stack: .init(name: "Next.js", why: "fits", parts: ["Next.js", "PostgreSQL"]),
                  alternatives: [.init(name: "Remix")], structure: [.init(path: "app/", purpose: "routes")],
                  steps: [.init(title: "Generate", status: "done"), .init(title: "Test", status: "failed", detail: "2 failing"), .init(title: "Ship")],
                  production: .init(host: "Vercel", domain: "app.example.com", staging: true, healthPath: "/api/health", companion: "node"),
                  variables: [.init(name: "DATABASE_URL", secret: true, environments: ["development", "production"])])
    }

    @Test func aValidBlueprintParses() throws {
        let file = BlueprintCheck.parse(try JSONEncoder().encode(valid))
        #expect(file.isApprovable, "\(file.problems)")
        let counts = try #require(file.blueprint?.stepCounts)
        #expect(counts.done == 1 && counts.failed == 1 && counts.total == 3)
        #expect(file.blueprint?.productionLine == "Vercel, app.example.com, with staging")
        #expect(BlueprintCheck.tiers(valid.variables![0]) == [.development, .production])
        #expect(BlueprintCheck.tiers(.init(name: "X")) == [.development])
    }

    @Test func untrustedBlueprintsAreChecked() throws {
        var blueprint = valid
        blueprint.summary = "Use token=" + "sk_" + "live_" + "abcdefghijklmnop for billing"
        blueprint.structure = [.init(path: "../outside"), .init(path: "/etc")]
        blueprint.steps = [.init(title: "Go", status: "maybe")]
        blueprint.production?.domain = "https://app.example.com"
        blueprint.production?.healthPath = "health"
        blueprint.variables = [.init(name: "BAD-NAME"), .init(name: "OK", environments: ["moon"])]
        let problems = BlueprintCheck.check(blueprint).problems
        #expect(problems.contains { $0.contains("secret value") })
        #expect(problems.filter { $0.contains("relative to the project folder") }.count == 2)
        #expect(problems.contains { $0.contains("status \"maybe\"") })
        #expect(problems.contains { $0.contains("host name") })
        #expect(problems.contains { $0.contains("healthPath") })
        #expect(problems.contains { $0.contains("BAD-NAME") })
        #expect(problems.contains { $0.contains("\"moon\"") })
        #expect(BlueprintCheck.parse(Data("{\"stack\": 1}".utf8)).blueprint == nil)
        #expect(!BlueprintCheck.parse(Data("{\"summary\": \"\", \"stack\": {\"name\": \"\"}}".utf8)).isApprovable)
    }

    @Test func aLargeOrOddBlueprintFileIsRefused() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(BlueprintCheck.read(folder: root.path) == nil)
        try FileManager.default.createDirectory(at: root.appending(path: ".forgedeck"), withIntermediateDirectories: true)
        try Data(repeating: 32, count: 70_000).write(to: root.appending(path: BlueprintCheck.relativePath))
        #expect(BlueprintCheck.read(folder: root.path)?.problems.first?.contains("64 KB") == true)
    }

    // MARK: Checklist

    private func newProduct(usesAgent: Bool, starter: String? = nil) -> Product {
        var product = product(at: "/tmp/desk", name: "Desk")
        product.checkouts[0].isGitRepository = true
        product.genesis = GenesisRecord(idea: "Idea", starter: starter, usesAgent: usesAgent, phase: usesAgent ? .planning : .building)
        return product
    }

    private func state(_ item: GenesisChecklist.Item, _ product: Product, _ inputs: GenesisChecklist.Inputs) -> GenesisChecklist.State? {
        GenesisChecklist.make(product, inputs: inputs).rows.first { $0.item == item }?.state
    }

    @Test func theChecklistFollowsTheAgent() {
        var product = newProduct(usesAgent: true)
        var inputs = GenesisChecklist.Inputs()
        inputs.agentRunning = true
        #expect(state(.plan, product, inputs) == .working)
        inputs.agentRunning = false
        #expect(state(.plan, product, inputs) == .attention, "interrupted: offer to start again")
        inputs.blueprint = BlueprintFile(blueprint: valid)
        #expect(state(.plan, product, inputs) == .needsYou)
        #expect(GenesisChecklist.make(product, inputs: inputs).next?.item == .plan)
        #expect(state(.build, product, inputs) == .pending)
        inputs.blueprint = BlueprintFile(blueprint: valid, problems: ["bad"])
        #expect(state(.plan, product, inputs) == .attention)

        product.genesis?.approvedStack = "Next.js"
        inputs.blueprint = BlueprintFile(blueprint: valid)
        inputs.agentRunning = true
        #expect(state(.plan, product, inputs) == .done)
        #expect(state(.build, product, inputs) == .attention, "a failed step needs attention")
        var allDone = valid
        allDone.steps = [.init(title: "A", status: "done"), .init(title: "B", status: "skipped")]
        inputs.blueprint = BlueprintFile(blueprint: allDone)
        #expect(state(.build, product, inputs) == .done)
    }

    @Test func theChecklistFollowsAStarterAndTheProposals() {
        var product = newProduct(usesAgent: false, starter: "nextjs")
        var inputs = GenesisChecklist.Inputs()
        inputs.scaffoldRunning = true
        #expect(state(.plan, product, inputs) == .done)
        #expect(state(.build, product, inputs) == .working)
        inputs.scaffoldRunning = false
        #expect(state(.build, product, inputs) == .attention, "no exit code: it did not finish")
        product.genesis?.scaffoldExit = 1
        #expect(state(.build, product, inputs) == .attention)
        product.genesis?.scaffoldExit = 0
        #expect(state(.build, product, inputs) == .done)
        #expect(state(.commands, product, inputs) == .pending)
        inputs.runToReview = 2
        #expect(state(.commands, product, inputs) == .needsYou)
        #expect(state(.environments, product, inputs) == .optional)
        product.genesis?.plannedProduction = "Vercel"
        product.environments.append(ProductEnvironment(name: "Production", tier: .production))
        let environments = GenesisChecklist.make(product, inputs: inputs).rows.first { $0.item == .environments }
        #expect(environments?.state == .done && environments?.detail.contains("Not deployed") == true, "planned production is never shown as live")
        #expect(state(.github, product, inputs) == .optional)
        #expect(GenesisChecklist.make(Product(name: "Plain"), inputs: inputs).rows.isEmpty)
    }

    // MARK: Prompts and context

    @Test func thePlanPromptPlansOnlyAndCarriesTheBuildSteps() {
        var product = newProduct(usesAgent: true)
        product.genesis?.preference = "SwiftUI"
        let prompt = GenesisPrompt.plan(product, folder: "/tmp/desk", tools: ["node", "swift"], cli: "forgedeck")
        #expect(prompt.contains("planning only") && prompt.contains("Do not create project files"))
        #expect(prompt.contains("> Idea") && prompt.contains("I would like to use: SwiftUI") && prompt.contains("node, swift"))
        #expect(prompt.contains("forgedeck blueprint check \(product.slug)"))
        #expect(prompt.contains("Never a value") && prompt.contains("Then wait"))
        #expect(prompt.contains("A. Build it one step at a time") && prompt.contains("Don't create a GitHub repository, push, deploy"))
    }

    @Test func thePlanSuggestsSkillsBeforeTheBuild() throws {
        let product = newProduct(usesAgent: true)
        let prompt = GenesisPrompt.plan(product, folder: "/tmp/desk", tools: [], cli: "forgedeck",
                                        installedSkills: ["swift-swiftui"], installedPlugins: ["bama"])
        let skills = try #require(prompt.range(of: "5. Suggest 3 to 8 agent skills"))
        let review = try #require(prompt.range(of: "6. Tell me your recommendation and the skills"))
        #expect(skills.lowerBound < review.lowerBound, "skills are suggested in planning, before the person approves")
        #expect(prompt.contains(SkillSuggestions.relativePath) && prompt.contains("forgedeck skills check \(product.slug)"))
        #expect(prompt.contains("Skills installed on this Mac: swift-swiftui") && prompt.contains("plugins installed: bama"))
        #expect(prompt.contains("Project setup › Skills") && prompt.contains("Suggest only; install nothing"))
        #expect(prompt.contains("E. Use the skills chosen"))
        let message = GenesisPrompt.approvalMessage(stack: "Next.js\nrm -rf", note: "line\rtwo")
        #expect(!message.contains("\n") && !message.contains("\r"), "one line typed into the agent's terminal")
        #expect(!message.contains("Skills chosen"))
        let withSkills = GenesisPrompt.approvalMessage(stack: "Next.js", note: nil, skills: ["nextjs", "playwright"])
        #expect(withSkills.contains("Skills chosen for this project: nextjs, playwright.") && !withSkills.contains("\n"))
        #expect(GenesisPrompt.build(product, stack: "Remix", note: nil, cli: "forgedeck", resuming: true).hasPrefix("Continue building"))
    }

    @Test func theContextBriefCarriesTheIdeaAndThePlan() {
        var product = newProduct(usesAgent: true)
        product.genesis?.approvedStack = "Next.js"
        product.genesis?.plannedProduction = "Vercel, app.example.com"
        let brief = RepoBrief.make(product, cache: ObservationCache(), packs: nil, includePack: false, isPrimary: true)
        #expect(brief.contains("> Idea") && brief.contains("Stack chosen: Next.js") && brief.contains("Planned only"))
        #expect(!RepoBrief.make(product, cache: ObservationCache(), packs: nil, includePack: false, isPrimary: false).contains("Project brief"))
    }

    @Test func gitHubCreationIsPrivateAndPushesNothing() {
        let arguments = GenesisGitHub.createArguments(name: "desk", folder: "/tmp/desk")
        #expect(arguments == ["repo", "create", "desk", "--private", "--source", "/tmp/desk", "--remote", "origin"])
        #expect(!arguments.contains("--push"))
        #expect(GenesisGitHub.createdURL("✓ Created repository me/desk on GitHub\n  https://github.com/me/desk\n")?.name == "desk")
        #expect(GenesisGitHub.createdURL("nothing") == nil)
    }

    @Test func productsSavedBeforeGenesisStillLoad() throws {
        var product = Product(name: "Old")
        product.genesis = nil
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(product)) as! [String: Any]
        json.removeValue(forKey: "genesis")
        let decoded = try JSONDecoder().decode(Product.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.genesis == nil)
    }
}
