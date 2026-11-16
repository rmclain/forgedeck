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
            check("the palette never lists a secret", !model.paletteCommands {}.contains { $0.label.contains("selftest-value") })
            model.removeDemo()
            check("removing the demo leaves real products", !model.hasDemo && model.products.count == 3)

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
    private static func terminalChecks(model: AppModel) async {
        func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
            for _ in 0..<Int(seconds * 10) {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }
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
        second.send("sleep 20\r")
        check("the indicator names the running program", await wait(5) { second.refreshForeground(); return second.foreground == "sleep" }, second.foreground ?? "nil")
        check("a busy session counts as running", second.isBusy && model.terminals.running.contains { $0.id == second.id })
        model.terminals.close(second)
        check("closing a session ends its processes", await wait(5) { !second.isRunning }, "\(second.state)")
        model.terminals.close(first)
        check("closing the last session hides the dock", !model.terminals.isVisible && model.terminals.sessions.isEmpty)
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
