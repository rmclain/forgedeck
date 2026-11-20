import AppKit
import ForgeDeckKit

/// Self-test for agents: runs the app's real functions on a temporary data folder,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1 (tools/selftest.sh).
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard StoreLocation.isOverridden() else {
            print("SELFTEST refused: set FORGEDECK_HOME to a temporary folder")
            finish(code: 1)
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            check("first launch has no products", model.products.isEmpty)
            model.addDemo(count: 3)
            check("Add 3 Demo Products adds three", model.products.count == 3)
            check("every demo product is marked Demo", model.products.allSatisfy(\.isDemo))
            check("demo evidence comes from fixtures", model.cache.deployments.allSatisfy { $0.provenance.isDemo && $0.provenance.source == .fixture })
            model.addDemo(count: 3)
            check("adding the demo twice does not duplicate", model.products.count == 3)
            model.saveNow()
            let reloaded = try? model.store.loadPortfolio()
            check("products survive a restart", reloaded?.products.count == 3)

            // A real repository in a folder with spaces and an apostrophe.
            let root = model.store.location.directory.appending(path: "it's a repo dir", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let git = URL(fileURLWithPath: "/usr/bin/git")
            let runner = SystemProcessRunner()
            for arguments in [["init", "-q", "-b", "main"], ["-c", "user.email=t@example.com", "-c", "user.name=T", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "first"]] {
                _ = try? await runner.run(ProcessRequest(executable: git, arguments: arguments, workingDirectory: root))
            }
            try? "{\"scripts\":{\"test\":\"true\"}}".write(to: root.appending(path: "package.json"), atomically: true, encoding: .utf8)
            if let project = ProjectDiscovery().inspect(root) {
                let proposals = ImportPlanner.plan([project], portfolio: model.portfolio)
                let ids = model.applyImport(proposals, group: "Test")
                check("a local folder imports as one product", ids.count == 1 && model.products.count == 4)
                await model.refreshLocal()
                let product = model.product(ids.first)
                let state = product?.primaryCheckout.flatMap { model.cache.git[$0.id] }
                check("the branch is read from the checkout", state?.branch == "main", state?.branch ?? "nil")
                check("an untracked file shows as uncommitted work", state?.isDirty == true)
                check("a detected test command becomes an unapproved suggestion", product?.recipes.contains { !$0.isApproved && $0.isSuggested } == true)
                let again = ImportPlanner.plan([project], portfolio: model.portfolio)
                if case .refresh = again.first?.action { check("scanning again refreshes instead of duplicating", true) } else { check("scanning again refreshes instead of duplicating", false) }
                if let product, let checkout = product.primaryCheckout {
                    let script = TerminalLauncher.script(directory: checkout.path, command: ["/bin/pwd"])
                    check("the launch script quotes the apostrophe", script.contains("'\\''"))
                }
            } else {
                check("a local folder imports as one product", false, "inspect returned nil")
            }

            let github = model.addRepository(RepositoryURL.parse("https://github.com/example/widget")!, original: "https://github.com/example/widget", group: "Test")
            check("a GitHub URL adds a product with no checkout", github.hasRemote && !github.hasLocal)
            let server = model.addServer(alias: "test-host", name: "Box", group: "Test", tier: .production)
            check("an SSH host adds a product with a production environment", server.environment(tier: .production)?.sshHosts.first?.alias == "test-host")

            // Scoped secrets.
            if let product = model.products.first(where: { !$0.isDemo && $0.hasLocal }) {
                model.update(product.id) { $0.environments.append(ProductEnvironment(name: "Production", tier: .production)) }
                let current = model.product(product.id)!
                var dev = VariableDraft()
                dev.key = "API_TOKEN"
                dev.value = "dev-selftest-value"
                dev.scope = .environment(product: current.id, environment: current.environment(tier: .development)!.id)
                dev.allowedTiers = [.development]
                var prod = dev
                prod.id = UUID()
                prod.value = "prod-selftest-value"
                prod.scope = .environment(product: current.id, environment: current.environment(tier: .production)!.id)
                prod.allowedTiers = [.production]
                check("a development secret saves", model.saveVariable(dev) == nil)
                check("a production secret saves", model.saveVariable(prod) == nil)
                model.saveNow()
                let files = [model.store.location.portfolioURL, model.store.location.cacheURL].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
                check("no secret value is in the saved files", !files.contains("selftest-value"))
                let resolved = model.resolved(for: model.product(product.id)!, tier: .development)
                check("development resolves its own token", resolved.first { $0.key == "API_TOKEN" }?.state == .direct)
                let export = (try? PortfolioExporter.export(model.portfolio)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                check("the export holds no secret value", !export.contains("selftest-value") && export.contains("API_TOKEN"))
                if Runtime.usesRealKeychain { await keychainPass(model: model, productID: product.id) }
            }
            await terminalChecks(model: model)
            skillChecks(model: model)
            await mcpChecks(model: model)
            await cloneChecks(model: model)
            check("the palette never lists a secret", !model.paletteCommands {}.contains { $0.label.contains("selftest-value") })
            model.removeDemo()
            check("removing the demo leaves real products", !model.hasDemo && model.products.count == 3)
            await genesisChecks(model: model)
            await issueReportChecks(model: model)
            await memoryChecks(model: model)
            await planChecks(model: model)

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    /// Walkthrough 7 with the real Keychain and the real CLI: this binary, started as
    /// `forgedeck exec`, gives a child process the development token and refuses the production one.
    private static func keychainPass(model: AppModel, productID: UUID) async {
        guard let binary = Bundle.main.executableURL, let product = model.product(productID),
              let development = product.environment(tier: .development) else { return }
        var profile = TerminalProfile()
        profile.name = "tests"
        profile.environmentID = development.id
        profile.checkoutID = product.primaryCheckout?.id
        profile.allowedExecutables = ["awk"]
        profile.variableAllowlist = ["API_TOKEN"]
        var greedy = profile
        greedy.id = UUID()
        greedy.name = "greedy"
        greedy.variableAllowlist = ["API_TOKEN", "PROD_ONLY"]
        model.update(productID) { $0.profiles = [profile, greedy] }
        var prodOnly = VariableDraft()
        prodOnly.key = "PROD_ONLY"
        prodOnly.value = "prodonly-selftest-value"
        prodOnly.scope = .product(productID)
        prodOnly.allowedTiers = [.production]
        check("a production-only secret saves to the Keychain", model.saveVariable(prodOnly) == nil)
        model.saveNow()
        let stored = model.portfolio.variables.compactMap(\.credential).allSatisfy { model.keychain.exists($0.locator) }
        check("each secret is a Keychain item", stored)

        let slug = product.slug
        let home = model.store.location.directory.path
        func cli(_ arguments: [String]) async -> ProcessResult? {
            var environment = ProcessInfo.processInfo.environment
            environment["FORGEDECK_HOME"] = home
            return try? await SystemProcessRunner().run(ProcessRequest(executable: binary, arguments: arguments, environment: environment, timeout: 30))
        }
        // awk prints the length of what it received: proof of delivery without printing the value.
        let program = ["awk", "BEGIN { print length(ENVIRON[\"API_TOKEN\"]) \":\" length(ENVIRON[\"PROD_ONLY\"]) }"]
        let granted = await cli(["exec", "--product", slug, "--environment", "development", "--profile", "tests", "--"] + program)
        check("forgedeck exec gives the child the development token", granted?.stdout.contains("\("dev-selftest-value".count):0") == true,
              "exit \(granted?.exitCode ?? -1) out=\(granted?.stdout ?? "") err=\(granted?.stderr ?? "")")
        check("exec names what it granted, not the value", granted?.stderr.contains("API_TOKEN") == true && granted?.stderr.contains("selftest-value") == false)
        let forged = await cli(["exec", "--product", slug, "--environment", "production", "--profile", "tests", "--"] + program)
        check("a development profile cannot be pointed at production", forged?.exitCode == CLIExit.denied, "exit \(forged?.exitCode ?? -1)")
        let blocked = await cli(["exec", "--product", slug, "--environment", "development", "--profile", "greedy", "--"] + program)
        check("a production secret is denied in development", blocked?.exitCode == CLIExit.denied && blocked?.stderr.contains("PROD_ONLY") == true,
              "exit \(blocked?.exitCode ?? -1) err=\(blocked?.stderr ?? "")")
        let shell = await cli(["exec", "--product", slug, "--environment", "development", "--profile", "tests", "--", "sh", "-c", "env"])
        check("a program the profile does not list is denied", shell?.exitCode == CLIExit.denied)
        let printed = await cli(["env", "list", slug, "--environment", "development", "--json"])
        check("env list shows names without values", printed?.stdout.contains("API_TOKEN") == true && printed?.stdout.contains("selftest-value") == false)
        let audit = (try? String(contentsOf: model.store.location.auditURL, encoding: .utf8)) ?? ""
        check("the audit log records the grant and the denials", audit.contains("exec.granted") && audit.contains("exec.denied"))
        check("the audit log holds no secret value", !audit.contains("selftest-value"))
        let saved = [model.store.location.portfolioURL, model.store.location.cacheURL].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        check("the saved files hold no secret value", !saved.contains("selftest-value"))

        // Rotation replaces the Keychain item in place, and the next run sees the new value.
        if let variable = model.portfolio.variables.first(where: { $0.key == "API_TOKEN" && $0.allowedTiers == [.development] }) {
            var rotate = VariableDraft()
            rotate.existingID = variable.id
            rotate.key = variable.key
            rotate.scope = variable.scope
            rotate.allowedTiers = [.development]
            rotate.value = "rotated-selftest-value-longer"
            check("rotating a secret saves", model.saveVariable(rotate) == nil)
            model.saveNow()
            let after = await cli(["exec", "--product", slug, "--environment", "development", "--profile", "tests", "--"] + program)
            check("the next run receives the rotated value", after?.stdout.contains("\("rotated-selftest-value-longer".count):0") == true, after?.stdout ?? "")
        }
        for variable in model.portfolio.variables { model.deleteVariable(variable) }
        let leftovers = model.portfolio.variables.isEmpty
        check("deleting the variables removes their Keychain items", leftovers)
    }

    /// The in-app terminal: a real PTY, the folder with an apostrophe, the running indicator, the exit code.
    /// Adding skills from a fetched repository, into a temporary home folder (never the real ~/.claude).
    private static func skillChecks(model: AppModel) {
        let fm = FileManager.default
        let base = model.store.location.directory.appending(path: "skills-test")
        let home = base.appending(path: "home"), clone = fm.temporaryDirectory.appending(path: "ForgeDeck-skills-selftest-\(UUID().uuidString)/repo")
        do {
            for (path, name) in [(".claude/skills/demo-skill", "demo-skill"), ("skills/demo-skill", "demo-skill"), ("skills/other", "other")] {
                let folder = clone.appending(path: path)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try "---\nname: \(name)\ndescription: Self-test skill \(path).\n---\n".write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            }
            try fm.createDirectory(at: home.appending(path: ".claude/skills/other"), withIntermediateDirectories: true)
            try "mine".write(to: home.appending(path: ".claude/skills/other/SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            return check("a skill repository can be laid out", false, error.localizedDescription)
        }
        model.agentHome = home
        let found = AgentSkills.discover(in: clone)
        check("skills are found in a repository, one entry per skill", found.map(\.name) == ["demo-skill", "other"], found.map(\.name).joined(separator: ","))
        model.installSkills(SkillPlan(repository: "example/skills", commit: "0123456789abcdef", folder: clone, skills: found), names: ["demo-skill", "other"], targets: [.claude])
        let added = home.appending(path: ".claude/skills/demo-skill/SKILL.md")
        check("an added skill is copied from the Claude Code copy", (try? String(contentsOf: added, encoding: .utf8))?.contains(".claude/skills/demo-skill") == true)
        check("a skill added some other way is kept", (try? String(contentsOf: home.appending(path: ".claude/skills/other/SKILL.md"), encoding: .utf8)) == "mine")
        check("the toast says what happened", model.toast?.text.contains("Kept your own other") == true, model.toast?.text ?? "")
        check("the clone is deleted after adding", !fm.fileExists(atPath: clone.path))
        check("the Toolbox lists the added skill", AgentSkills.installed(home: home).map(\.name) == ["demo-skill"])
        model.agentHome = nil
        try? fm.removeItem(at: base)
    }

    /// Add Product › GitHub Repository with "Clone to this Mac": the repository becomes a product and its clone that
    /// product's local folder. git rewrites the GitHub URL to a local bare repository, so nothing reaches the network.
    private static func cloneChecks(model: AppModel) async {
        let fm = FileManager.default
        let base = model.store.location.directory.appending(path: "clone-test")
        let origin = base.appending(path: "origin/selftest-clone.git"), work = base.appending(path: "work"), parent = base.appending(path: "Projects")
        guard let git = ExecutableLocator.find("git") else { return check("git is installed for the clone check", false) }
        let runner = SystemProcessRunner()
        func run(_ arguments: [String], in folder: URL) async -> Bool {
            (try? await runner.run(ProcessRequest(executable: git, arguments: arguments, workingDirectory: folder, timeout: 30)))?.ok == true
        }
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true); try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { return check("a repository to clone can be made", false, error.localizedDescription) }
        try? "# Self-test\n".write(to: work.appending(path: "README.md"), atomically: true, encoding: .utf8)
        var made = true
        for (arguments, folder) in [(["init", "-q"], work), (["add", "README.md"], work),
                                    (["-c", "user.name=Self Test", "-c", "user.email=selftest@example.invalid", "commit", "-q", "-m", "First"], work),
                                    (["clone", "-q", "--bare", work.path, origin.path], base)] where made {
            made = await run(arguments, in: folder)
        }
        guard made else { try? fm.removeItem(at: base); return check("a repository to clone can be made", false) }
        // git reads config from the environment; the clone's own process inherits it.
        let keys = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "url.\(base.appending(path: "origin").path)/.insteadOf",
                    "GIT_CONFIG_VALUE_0": "git@github.com:selftest/"]
        for (key, value) in keys { setenv(key, value, 1) }
        defer { for key in keys.keys { unsetenv(key) } }

        guard let url = RepositoryURL.parse("git@github.com:selftest/selftest-clone.git") else { return check("the repository URL parses", false) }
        let product = model.addRepository(url, original: "git@github.com:selftest/selftest-clone.git", group: "Self-test")
        guard let repository = model.product(product.id)?.repositories.first else { return check("the repository is added as a product", false) }
        await model.cloneRepository(repository, into: parent, for: product.id)
        let destination = parent.appending(path: "selftest-clone")
        check("Add and Clone clones into the chosen folder", fm.fileExists(atPath: destination.appending(path: "README.md").path), model.toast?.text ?? "")
        let checkout = model.product(product.id)?.checkouts.first
        check("the clone becomes the product's local folder",
              checkout.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path } == true, checkout?.path ?? "none")
        await model.cloneRepository(repository, into: parent, for: product.id)
        check("a second clone never overwrites the folder", model.toast?.isError == true && model.product(product.id)?.checkouts.count == 1, model.toast?.text ?? "")
        if let current = model.product(product.id) { model.portfolio.products.removeAll { $0.id == current.id }; model.save() }
        try? fm.removeItem(at: base)
    }

    /// MCP servers from a temporary home folder and checkout: configs matched to a product, tools read from its code.
    private static func mcpChecks(model: AppModel) async {
        let fm = FileManager.default
        let base = model.store.location.directory.appending(path: "mcp-test")
        let home = base.appending(path: "home"), checkout = base.appending(path: "code/acme-cme")
        do {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try fm.createDirectory(at: checkout.appending(path: "includes/Mcp"), withIntermediateDirectories: true)
            let config = #"{"mcpServers":{"acme-cme-prod":{"type":"http","url":"https://acme.example/wp-json/acme-cme/mcp","headers":{"Authorization":"Basic c2VjcmV0"}}},"projects":{"\#(checkout.path)":{"mcpServers":{"acme-cme":{"type":"http","url":"http://localhost:10003/wp-json/acme-cme/mcp"}}}}}"#
            try config.write(to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
            try "<?php\nreturn array(\n 'get-thing' => array(\n  'label' => 'Get a thing',\n  'description' => 'Reads one thing.',\n  'readonly' => true,\n  'run' => 'x',\n ),\n 'save-thing' => array(\n  'label' => 'Save a thing',\n  'description' => 'Saves it.',\n  'run' => 'y',\n ),\n);\n"
                .write(to: checkout.appending(path: "includes/Mcp/Abilities.php"), atomically: true, encoding: .utf8)
        } catch {
            return check("an MCP setup can be laid out", false, error.localizedDescription)
        }
        var product = Product()
        product.slug = "acme-cme"
        product.name = "Acme CME"
        var local = LocalCheckout()
        local.path = checkout.path
        product.checkouts = [local]
        model.agentHome = home
        let before = model.mcpVersion
        model.refreshMCP(only: product)
        for _ in 0..<50 where model.mcpVersion == before { try? await Task.sleep(for: .milliseconds(100)) }
        let info = model.mcpInfo(product)
        check("MCP servers are matched to the product from its configs", Set(info.serverNames) == ["acme-cme", "acme-cme-prod"], info.serverNames.joined(separator: ","))
        check("a production MCP server is flagged", info.reachesProduction)
        check("MCP tools are read from the code, with reads and writes told apart", info.primaryCode?.readOnlyCount == 1 && info.primaryCode?.writeCount == 1)
        check("no MCP credential or URL path reaches the context file",
              MCPInventory.contextSection(info).map { !$0.contains("c2VjcmV0") && !$0.contains("wp-json") && $0.contains("acme-cme-prod") } == true)
        model.agentHome = nil
        model.mcpEntries = []
        model.mcpCode = [:]
        model.mcpCache.removeAll()
        try? fm.removeItem(at: base)
    }

    private static func terminalChecks(model: AppModel) async {
        let folder = model.store.location.directory.appending(path: "it's a repo dir").path
        guard let echo = TerminalLaunch.command(["/bin/echo", "forgedeck-pty-ok"], kind: .command, title: "echo", in: folder) else {
            return check("a command runs in the in-app terminal", false, "launch could not be built")
        }
        let first = model.terminals.open(echo, productID: nil, checkoutID: nil)
        check("a command runs in the in-app terminal and its output is on screen", await wait(5) { first.text.contains("forgedeck-pty-ok") }, first.text)
        check("the session records the exit code", await wait(5) { first.state == .exited(0) }, "\(first.state)")

        // A plain shell without the user's startup files, so the check does not depend on them.
        var shell = TerminalLaunch.shell(in: folder, title: "shell")
        shell.executable = "/bin/zsh"
        shell.arguments = ["-f"]
        shell.execName = nil
        let second = model.terminals.open(shell, productID: nil, checkoutID: nil)
        try? await Task.sleep(for: .milliseconds(400))
        second.send("pwd\r")
        check("a shell opens in a folder whose name has an apostrophe", await wait(5) { second.text.contains("it's a repo dir") }, second.text)
        check("an idle shell shows no foreground program", second.foreground == nil && !second.isBusy)

        // A file dropped on the terminal types its escaped path; the shell reads it as one word.
        let board = NSPasteboard(name: NSPasteboard.Name("ForgeDeck.selftest.drop"))
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: folder) as NSURL])
        let dropped = DropTerminalView.text(from: board, saving: true) ?? ""
        board.releaseGlobally()
        second.send("ls -d ")
        second.view.pasteText(dropped)
        _ = await wait(5) { second.text.contains("repo\\ dir") }
        second.send("&& echo drop-$((40+2))-ok\r")
        check("a dropped folder types a path the shell reads", await wait(5) { second.text.contains("drop-42-ok") }, dropped + "\n" + second.text)
        second.send("sleep 20\r")
        check("the indicator names the running program", await wait(5) { second.refreshForeground(); return second.foreground == "sleep" }, second.foreground ?? "nil")
        check("a busy session counts as running", second.isBusy && model.terminals.running.contains { $0.id == second.id })
        model.terminals.close(second)
        check("closing a session ends its processes", await wait(5) { !second.isRunning }, "\(second.state)")
        // The dock follows the product the window shows.
        let productA = UUID(), productB = UUID()
        let host = model.terminals
        host.scope = nil
        let otherShell = host.open(echo, productID: productB, checkoutID: nil)
        host.scope = productA
        check("on a product page another product's terminal is hidden", !host.visible.contains { $0.id == otherShell.id } && host.hiddenCount == 1)
        check("a shell with no product shows on every page", host.visible.contains { $0.id == first.id })
        let ownShell = host.open(echo, productID: productA, checkoutID: nil)
        check("the dock shows this product's terminal", host.selected?.id == ownShell.id)
        host.showAll = true
        host.select(otherShell)
        check("All Terminals shows every product's sessions", host.visible.count == host.sessions.count)
        host.scope = productB
        check("changing page goes back to following the product", host.isScoped && host.selected?.id == otherShell.id)
        host.scope = productA
        check("coming back to a product shows its own terminal", host.selected?.id == ownShell.id)
        host.close(otherShell)
        host.close(ownShell)
        host.scope = nil

        model.terminals.close(first)
        check("closing the last session hides the dock", !model.terminals.isVisible && model.terminals.sessions.isEmpty)
    }

    /// New Project in a temporary folder: the folder, Git, and product; refusals; a real generator in a terminal;
    /// and a blueprint approved without starting an agent.
    /// A plan: the agent's file becomes a checklist, executing sends the ticked steps, left-out steps become issues,
    /// and reported steps finish the plan and the issue it came from.
    private static func planChecks(model: AppModel) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "forgedeck-plans-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "selftest-plans")
        let request = GenesisRequest(name: "Selftest Plans", idea: "", parent: root.path, folder: "selftest-plans", starter: GenesisStarter.find("empty"))
        guard await model.createProject(request) == nil,
              let product = model.products.first(where: { $0.checkouts.first?.path == folder.path }) else {
            return check("a product for the plan checks", false)
        }
        model.addIssue("dark mode", to: product)
        guard let issue = model.product(product.id)?.issues?.first,
              let plan = model.beginPlan("dark mode", issue: issue, in: model.product(product.id) ?? product) else {
            return check("a plan can be requested", false)
        }
        check("a requested plan waits for the agent", model.plan(plan.id, in: product.id)?.phase == .planning)
        let planFile = folder.appending(path: FeaturePlans.relativePath)
        try? FileManager.default.createDirectory(at: planFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{\"plan\": \"\(plan.id.uuidString)\", \"steps\": []}".utf8).write(to: planFile)
        await model.reloadAgentFiles(model.product(product.id) ?? product)
        let waiting = model.plan(plan.id, in: product.id)
        check("a plan file with a problem is not shown as ready, and says why", waiting?.phase == .planning
              && FeaturePlans.problems(model.planFiles[product.id] ?? [], for: waiting!) == ["It has no steps."])
        let json = """
        {"plan": "\(plan.id.uuidString)", "title": "Dark mode", "summary": "Variables first.",
         "steps": [{"id": "1", "title": "Variables"}, {"id": "2", "title": "Palette"}, {"id": "3", "title": "Switcher", "optional": true}]}
        """
        try? Data(json.utf8).write(to: planFile)
        await model.reloadAgentFiles(model.product(product.id) ?? product)
        check("the agent's plan becomes a checklist to review", model.plan(plan.id, in: product.id)?.phase == .ready
              && model.plan(plan.id, in: product.id)?.steps.count == 3 && model.toast?.text.contains("is ready: 3 steps") == true, model.toast?.text ?? "")

        let current = model.product(product.id) ?? product
        let executed = model.recordExecution(plan.id, in: current, skipped: ["3"], notes: ["1": "keep aliases"])
        let after = model.product(product.id)
        check("executing keeps the choices and turns the left-out step into an issue", executed?.phase == .executing
              && executed?.steps.first?.note == "keep aliases" && after?.issues?.contains { $0.title == "Switcher" && !$0.isDone } == true)
        check("nothing is executed with every step left out",
              model.recordExecution(plan.id, in: after ?? product, skipped: ["1", "2", "3"], notes: [:]) == nil)

        try? await Task.sleep(for: .milliseconds(20))
        let report = folder.appending(path: IssueReports.relativePath)
        let id = plan.id.uuidString
        try? Data("{\"steps\": [{\"plan\": \"\(id)\", \"step\": \"1\", \"summary\": \"Variables in.\"}]}".utf8).write(to: report)
        await model.reloadAgentFiles(model.product(product.id) ?? product)
        check("a reported step ticks off", model.plan(plan.id, in: product.id).map { $0.progress == (1, 2) } == true)
        try? Data("{\"steps\": [{\"plan\": \"\(id)\", \"step\": \"1\"}, {\"plan\": \"\(id)\", \"step\": \"2\"}]}".utf8).write(to: report)
        await model.reloadAgentFiles(model.product(product.id) ?? product)
        let done = model.product(product.id)
        check("the last step finishes the plan and the issue it came from", model.plan(plan.id, in: product.id)?.phase == .done
              && done?.issues?.first { $0.id == issue.id }?.isDone == true, model.toast?.text ?? "")
        if let finished = model.plan(plan.id, in: product.id) { model.deletePlan(finished, from: done ?? product) }
        check("a plan can be deleted", model.product(product.id)?.plans?.isEmpty == true)
    }

    /// The agent's done report moves an item it was started on to Done, and a reopened item stays open.
    private static func issueReportChecks(model: AppModel) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "forgedeck-issues-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = GenesisRequest(name: "Selftest Issues", idea: "", parent: root.path, folder: "selftest-issues", starter: GenesisStarter.find("empty"))
        guard await model.createProject(request) == nil,
              let product = model.products.first(where: { $0.checkouts.first?.path == root.appending(path: "selftest-issues").path }) else {
            return check("a product for the issue checks", false)
        }
        model.addIssue("fix the export", to: product)
        model.addIssue("left alone", to: product)
        guard let issues = model.product(product.id)?.issues, let target = issues.first(where: { $0.title == "fix the export" }),
              let other = issues.first(where: { $0.title == "left alone" }) else { return check("issues are added", false) }
        model.updateIssue(target.id, in: product) { $0.startedAt = .now.addingTimeInterval(-60); $0.startedWith = "claude" }
        let file = root.appending(path: "selftest-issues").appending(path: IssueReports.relativePath)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let report = "{\"done\": [{\"id\": \"\(target.id.uuidString)\", \"summary\": \"Export keeps the last row.\"}, {\"id\": \"\(other.id.uuidString)\"}]}"
        try? Data(report.utf8).write(to: file)
        await model.reloadAgentFiles(model.product(product.id) ?? product)
        let after = model.product(product.id)?.issues ?? []
        let closed = after.first { $0.id == target.id }
        check("the agent's done report moves the item to Done", closed?.isDone == true && closed?.doneBy == "claude"
              && closed?.doneSummary == "Export keeps the last row.")
        check("a toast says the agent finished it", model.toast?.text.contains("finished \u{201C}fix the export\u{201D}") == true, model.toast?.text ?? "")
        check("an item no agent was started on stays open", after.first { $0.id == other.id }?.isDone == false)
        if let closed { model.setIssueDone(closed, false, in: product) }
        await model.reloadAgentFiles(model.product(product.id) ?? product)
        check("an item reopened after the report stays open", model.product(product.id)?.issues?.first { $0.id == target.id }?.isDone == false)
    }

    /// Memory: the person's items and the agent's file both land in the list, every session's prompt carries them, and delete works.
    private static func memoryChecks(model: AppModel) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "forgedeck-memory-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = GenesisRequest(name: "Selftest Memory", idea: "", parent: root.path, folder: "selftest-memory", starter: GenesisStarter.find("empty"))
        let folder = root.appending(path: "selftest-memory")
        guard await model.createProject(request) == nil, let product = model.products.first(where: { $0.checkouts.first?.path == folder.path }) else {
            return check("a product for the memory checks", false)
        }
        let added = model.addMemory("Run the tests with make test.", kind: .rule, to: product)
        let again = model.addMemory("run the tests with make test", kind: .note, to: product)
        check("a typed rule is saved once", added && !again && model.product(product.id)?.memory?.count == 1)
        let file = folder.appending(path: ProductMemory.relativePath)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{\"add\": [{\"kind\": \"note\", \"text\": \"Webhooks retry, so the handler must be idempotent.\"}]}".utf8).write(to: file)
        await model.reloadAgentFiles(model.product(product.id) ?? product)
        let notes = model.product(product.id)?.memory ?? []
        let learned = notes.first { $0.kind == .note }
        check("the agent's file adds to the memory", notes.count == 2 && learned?.addedBy == model.portfolio.settings.aiAgentProgram,
              notes.map(\.text).joined(separator: " | "))
        check("the agent's file is emptied once read", ProductMemory.read(folder: folder.path)?.entries == [])
        check("a toast names what the agent added", model.toast?.text.contains("memory") == true, model.toast?.text ?? "")
        let current = model.product(product.id) ?? product
        let bundle = try? AgentContextBundle.write(for: current, portfolio: model.portfolio, cache: model.cache, location: model.contextLocation)
        let context = bundle.flatMap { try? String(contentsOf: $0.contextFile, encoding: .utf8) } ?? ""
        check("every session's prompt and context file carry the memory", bundle?.pointer.contains("- Rule: Run the tests with make test.") == true
              && bundle?.pointer.contains(ProductMemory.relativePath) == true && context.contains("- Note: Webhooks retry"))
        if let learned { model.deleteMemory(learned, from: current) }
        check("an item can be deleted", model.product(product.id)?.memory?.map(\.text) == ["Run the tests with make test."])
    }

    private static func genesisChecks(model: AppModel) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "forgedeck-genesis-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = model.products.count

        var request = GenesisRequest(name: "Selftest Notes", idea: "A note app for the self-test.\nSecond line.", parent: root.path,
                                     folder: "selftest-notes", starter: GenesisStarter.find("empty"))
        let error = await model.createProject(request)
        let folder = root.appending(path: "selftest-notes")
        let product = model.products.first { $0.checkouts.first?.path == folder.path }
        check("New Project makes the folder, README, .gitignore, and Git", error == nil
              && ["README.md", ".gitignore", ".git"].allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }, error ?? "")
        check("the new project is a product with its brief", product?.genesis?.idea.hasPrefix("A note app") == true && product?.tagline == "A note app for the self-test."
              && product?.primaryCheckout?.isGitRepository == true && product?.environment(tier: .development) != nil)
        let again = await model.createProject(request)
        check("creating into the same folder again is refused", again != nil && model.products.count == before + 1, again ?? "nil")
        request.folder = "a/b"
        check("a folder name with a slash is refused", await model.createProject(request) != nil)
        let busy = root.appending(path: "busy")
        try? FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try? Data("keep".utf8).write(to: busy.appending(path: "notes.txt"))
        request.folder = "busy"
        check("a folder with files is refused unless chosen", await model.createProject(request) != nil && model.products.count == before + 1)
        request.useExistingFolder = true
        request.name = "Selftest Busy"
        check("setting up in an existing folder keeps its files", await model.createProject(request) == nil
              && (try? String(contentsOf: busy.appending(path: "notes.txt"), encoding: .utf8)) == "keep")

        // A real generator, from a fixed argument list, in a built-in terminal.
        if ExecutableLocator.find("swift") != nil {
            let swiftRequest = GenesisRequest(name: "Selftest Tool", idea: "", parent: root.path, folder: "selftest-tool", starter: GenesisStarter.find("swift"))
            let made = await model.createProject(swiftRequest)
            let tool = model.products.first { $0.checkouts.first?.path == root.appending(path: "selftest-tool").path }
            let finished = await wait(90) { tool.flatMap { model.product($0.id)?.genesis?.scaffoldExit } != nil }
            check("a starter's generator runs in a terminal and its commands are proposed", made == nil && finished
                  && model.product(tool!.id)?.genesis?.scaffoldExit == 0
                  && FileManager.default.fileExists(atPath: root.appending(path: "selftest-tool/Package.swift").path)
                  && FileManager.default.fileExists(atPath: root.appending(path: "selftest-tool/\(RunSetup.relativePath)").path),
                  "\(made ?? "") exit=\(tool.flatMap { model.product($0.id)?.genesis?.scaffoldExit }.map(String.init) ?? "nil")")
            for session in model.terminals.sessions where session.productID == tool?.id { model.terminals.close(session) }
        }

        // The agent's plan, approved here, without starting an agent.
        if var planned = product {
            model.update(planned.id) { $0.genesis?.usesAgent = true; $0.genesis?.starter = nil; $0.genesis?.phase = .planning }
            planned = model.product(planned.id)!
            let blueprint = Blueprint(summary: "Notes app.", stack: .init(name: "SwiftUI", why: "Native", parts: ["Swift", "SwiftUI"]),
                                      steps: [.init(title: "Generate", status: "pending")],
                                      production: .init(host: "App Store"),
                                      variables: [.init(name: "SYNC_TOKEN", why: "sync server", secret: true, environments: ["production"])])
            let encoder = JSONEncoder()
            try? FileManager.default.createDirectory(at: folder.appending(path: ".forgedeck"), withIntermediateDirectories: true)
            try? encoder.encode(blueprint).write(to: folder.appending(path: BlueprintCheck.relativePath))
            await model.reloadAgentFiles(planned)
            check("a written blueprint waits for review", model.genesisChecklist(planned).rows.first { $0.item == .plan }?.state == .needsYou)
            model.approveBlueprint(planned, stack: blueprint.stack, note: nil, addProduction: true, addVariables: true, startAgent: false)
            let approved = model.product(planned.id)!
            let variable = model.portfolio.variables.first { $0.key == "SYNC_TOKEN" && $0.scope.productID == planned.id }
            check("approving keeps the choice and adds Production with no checks",
                  approved.genesis?.approvedStack == "SwiftUI" && approved.environment(tier: .production)?.probes.isEmpty == true
                  && model.genesisChecklist(approved).rows.first { $0.item == .plan }?.state == .done)
            check("planned variables are names without values", variable != nil && variable?.credential == nil && variable?.plainValue == nil
                  && variable?.allowedTiers == [.production])
            let brief = RepoBrief.make(approved, cache: model.cache, packs: nil, includePack: false, isPrimary: true)
            check("the agent's context carries the project brief", brief.contains("A note app for the self-test.") && brief.contains("Stack chosen: SwiftUI"))
            model.finishGenesis(approved)
            check("closing the checklist keeps the brief", model.product(planned.id)?.genesis?.phase == .finished)
        }

        for product in model.products where product.checkouts.contains(where: { $0.path.hasPrefix(root.path) }) { model.remove(product) }
        check("the self-test projects are removed", model.products.count == before)
    }

    private static func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 10) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    static func finish(code: Int32) {
        exitCode = code
        NSApp.terminate(nil)
    }
}
