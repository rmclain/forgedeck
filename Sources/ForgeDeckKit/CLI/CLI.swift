import Foundation

// The `forgedeck` command line. The app binary runs this when it is started as
// `forgedeck` (a symlink) or with a CLI command as its first argument, so the CLI
// has the app's code signature and reads the same Keychain items without a second
// trust decision.
//
// Read commands read portfolio.json and cache.json. Nothing here writes them: the app
// is the only writer. The CLI appends audit events and nothing else.
//
// JSON output is stable: keys are only ever added. No command prints a secret value.

public struct CLIOutput: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.out = out
        self.err = err
    }

    public static let standard = CLIOutput(
        out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
}

public final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var outLines: [String] = []
    private var errLines: [String] = []
    public init() {}
    public var output: CLIOutput {
        CLIOutput(out: { line in self.lock.withLock { self.outLines.append(line) } },
                  err: { line in self.lock.withLock { self.errLines.append(line) } })
    }
    public var stdout: String { lock.withLock { outLines.joined(separator: "\n") } }
    public var stderr: String { lock.withLock { errLines.joined(separator: "\n") } }
}

public enum CLIExit {
    public static let ok: Int32 = 0
    public static let failure: Int32 = 1
    public static let usage: Int32 = 64
    public static let denied: Int32 = 77
}

public struct CLI: Sendable {
    public static let version = "0.7"
    public static let commands = ["list", "status", "open", "doctor", "env", "actions", "exec", "context", "pack", "agent", "links", "link", "ci", "usage", "help", "version"]

    public var store: PortfolioStore
    public var io: CLIOutput
    public var exec: ExecService
    public var launcher: TerminalLauncher
    public var doctor: ConnectionDoctor
    /// Starts the child for `exec`. Replaceable in tests.
    public var spawn: @Sendable (ExecPlan, Bool) async -> Int32

    public init(store: PortfolioStore = PortfolioStore(), io: CLIOutput = .standard, exec: ExecService? = nil,
                launcher: TerminalLauncher? = nil, doctor: ConnectionDoctor = ConnectionDoctor(),
                spawn: (@Sendable (ExecPlan, Bool) async -> Int32)? = nil) {
        self.store = store
        self.io = io
        self.exec = exec ?? ExecService(audit: AuditLog(location: store.location))
        self.launcher = launcher ?? TerminalLauncher(launchDirectory: store.location.launchDirectory)
        self.doctor = doctor
        self.spawn = spawn ?? { plan, redact in await ChildProcess.run(plan, redactOutput: redact) }
    }

    /// True when the process arguments ask for the CLI instead of the window.
    public static func isInvocation(arguments: [String]) -> Bool {
        let name = arguments.first.map { ($0 as NSString).lastPathComponent } ?? ""
        if name == Brand.cliName { return true }
        guard arguments.count > 1 else { return false }
        return commands.contains(arguments[1]) || ["--help", "-h", "--version"].contains(arguments[1])
    }

    public static let help = """
    \(Brand.cliName) — read your \(Brand.name) portfolio and run approved commands from a terminal.

    USAGE
      \(Brand.cliName) list [--json]
      \(Brand.cliName) status <product> [--json]
      \(Brand.cliName) open <product> [--checkout <name>] [--terminal <name>] [--editor]
      \(Brand.cliName) doctor [--product <product>] [--ssh <host-alias>] [--json]
      \(Brand.cliName) env list <product> --environment <name> [--profile <name>] [--json]
      \(Brand.cliName) actions list <product> [--json]
      \(Brand.cliName) exec --product <product> --environment <name> --profile <name> -- <program> [args...]
      \(Brand.cliName) context <product> [--write]
      \(Brand.cliName) pack <product> [--related] [--checkout <name>]
      \(Brand.cliName) agent <product> [--agent claude|codex|opencode|gemini|agy] [--model <name>] [--print]
      \(Brand.cliName) usage                      (AI tool usage and limits on this Mac)
      \(Brand.cliName) ci <product> [--run <id>] [--brief | --fix [--agent <name>] [--print]]
      \(Brand.cliName) links <product> [--json]
      \(Brand.cliName) link <product> --site <local site> [--checkout <name>] [--remove]
      \(Brand.cliName) help | version

    <product> is a slug from `\(Brand.cliName) list`.

    EXEC
      Starts <program> with the variables its profile grants, and nothing else from the vault.
      The profile lists the programs it may start and the variables it may receive.
      A secret that is not allowed in the chosen environment is denied.
      Production secrets ask for Touch ID or your password at this Mac.
      Values reach the program through its environment, in memory. They are never printed,
      written to a file, or placed on a command line. The program and anything it starts
      can read them: grant only what the program needs.

    AGENT CONTEXT
      `agent` writes CONTEXT.md for the product (a short brief of it and of each related product
      you linked in \(Brand.name)), then starts the agent in the product's checkout. Claude Code
      also gets each related checkout with --add-dir, so it reads the real files when needed.
      `pack` builds a compressed code pack and a ranked repo map with repomix (needs Node).
      Packs and context files stay in \(Brand.name)'s data folder. No repository is changed.
      --print shows the agent command instead of starting it.

    OUTPUT
      --json prints stable, documented JSON. Secret values never appear in any output.

    EXIT CODES
      0 ok · 1 failed · 64 wrong usage · 77 denied
    """

    struct Arguments {
        var positional: [String] = []
        var flags: [String: String] = [:]
        var switches: Set<String> = []
        var rest: [String] = []

        init(_ arguments: [String], valueFlags: Set<String>) {
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" {
                    rest = Array(arguments[(index + 1)...])
                    break
                }
                if argument.hasPrefix("--") {
                    let name = String(argument.dropFirst(2))
                    if valueFlags.contains(name), index + 1 < arguments.count {
                        flags[name] = arguments[index + 1]
                        index += 1
                    } else {
                        switches.insert(name)
                    }
                } else {
                    positional.append(argument)
                }
                index += 1
            }
        }
    }

    private func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONCoding.encoder()
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }

    private func loadPortfolio() -> Portfolio? {
        do { return try store.loadPortfolio() } catch {
            io.err("error: \(error)")
            return nil
        }
    }

    private func product(_ slug: String?, in portfolio: Portfolio) -> Product? {
        guard let slug, !slug.isEmpty else {
            io.err("error: name a product. Run `\(Brand.cliName) list`.")
            return nil
        }
        guard let product = portfolio.product(slug: slug) else {
            io.err("error: no product \"\(slug)\". Run `\(Brand.cliName) list`.")
            return nil
        }
        return product
    }

    /// Runs one command. `arguments` excludes the program name.
    public func run(_ arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            io.out(Self.help)
            return CLIExit.ok
        }
        let args = Arguments(Array(arguments.dropFirst()),
                             valueFlags: ["product", "environment", "profile", "checkout", "terminal", "ssh", "agent", "site", "run", "model"])
        switch command {
        case "help", "--help", "-h":
            io.out(Self.help)
            return CLIExit.ok
        case "version", "--version":
            io.out("\(Brand.cliName) \(Self.version)")
            return CLIExit.ok
        case "list": return list(args)
        case "status": return status(args)
        case "open": return await open(args)
        case "doctor": return await runDoctor(args)
        case "env": return env(args)
        case "actions": return actions(args)
        case "exec": return await execute(args)
        case "context": return context(args)
        case "pack": return await pack(args)
        case "agent": return await agent(args)
        case "links": return links(args)
        case "ci": return await ci(args)
        case "usage": return usage()
        case "link": return link(args)
        default:
            io.err("error: unknown command \"\(command)\". Run `\(Brand.cliName) help`.")
            return CLIExit.usage
        }
    }

    // MARK: list

    public struct ProductRow: Codable, Sendable {
        public var slug: String
        public var name: String
        public var group: String
        public var lifecycle: String
        public var status: String
        public var checkouts: Int
        public var repositories: Int
        public var environments: [String]
        public var demo: Bool
    }

    private func list(_ args: Arguments) -> Int32 {
        guard let portfolio = loadPortfolio() else { return CLIExit.failure }
        let cache = store.loadCache()
        let rows = portfolio.products.map { product in
            ProductRow(slug: product.slug, name: product.name, group: product.group, lifecycle: product.lifecycle.rawValue,
                       status: ProductStatus.badge(product, cache: cache).label, checkouts: product.checkouts.count,
                       repositories: product.repositories.count, environments: product.environments.map(\.name), demo: product.isDemo)
        }
        if args.switches.contains("json") {
            io.out(json(rows))
        } else if rows.isEmpty {
            io.out("No products yet. Add one in \(Brand.name).")
        } else {
            let width = max(4, rows.map(\.slug.count).max() ?? 4)
            for row in rows {
                io.out("\(row.slug.padding(toLength: width, withPad: " ", startingAt: 0))  \(row.status.padding(toLength: 14, withPad: " ", startingAt: 0))  \(row.name)\(row.demo ? "  (demo)" : "")")
            }
        }
        return CLIExit.ok
    }

    // MARK: status

    public struct StageRow: Codable, Sendable {
        public var stage: String
        public var title: String
        public var commit: String?
        public var version: String?
        public var evidence: String
        public var source: String
        public var observedAt: Date?
        public var detail: String
        public var problem: String?
        public var demo: Bool
    }

    public struct CheckoutRow: Codable, Sendable {
        public var name: String
        public var path: String
        public var branch: String?
        public var commit: String?
        public var dirty: Bool
        public var summary: String
    }

    public struct StatusReport: Codable, Sendable {
        public var slug: String
        public var name: String
        public var status: String
        public var demo: Bool
        public var checkouts: [CheckoutRow]
        public var stages: [StageRow]
        public var relations: [String]
        public var openIncidents: [String]
    }

    public func statusReport(_ product: Product, cache: ObservationCache, now: Date = .now) -> StatusReport {
        let stages = DriftAnalyzer.chain(product: product, cache: cache, now: now).map {
            StageRow(stage: $0.stage.rawValue, title: $0.title, commit: $0.sha, version: $0.version, evidence: $0.level.rawValue,
                     source: $0.sourceTitle, observedAt: $0.observedAt, detail: $0.detail, problem: $0.problem?.rawValue, demo: $0.isDemo)
        }
        let checkouts = product.checkouts.map { checkout in
            let git = cache.git[checkout.id]
            return CheckoutRow(name: checkout.name, path: checkout.path, branch: git?.branch, commit: git?.headSHA,
                               dirty: git?.isDirty ?? false, summary: git?.summary ?? "not inspected")
        }
        return StatusReport(slug: product.slug, name: product.name, status: ProductStatus.badge(product, cache: cache, now: now).label,
                            demo: product.isDemo, checkouts: checkouts, stages: stages,
                            relations: DriftAnalyzer.relations(product: product, cache: cache, now: now).map(\.sentence),
                            openIncidents: ProductStatus.openIncidents(product, cache: cache, now: now).map(\.title))
    }

    private func status(_ args: Arguments) -> Int32 {
        guard let portfolio = loadPortfolio(), let product = product(args.positional.first, in: portfolio) else { return CLIExit.failure }
        let report = statusReport(product, cache: store.loadCache())
        if args.switches.contains("json") {
            io.out(json(report))
            return CLIExit.ok
        }
        io.out("\(report.name) — \(report.status)\(report.demo ? " (demo fixture)" : "")")
        for checkout in report.checkouts { io.out("  checkout  \(checkout.name): \(checkout.summary)") }
        for stage in report.stages {
            let what = stage.version ?? shortSHA(stage.commit)
            let when = stage.observedAt.map { ", seen \(RelativeTime.short($0))" } ?? ""
            io.out("  \(stage.stage.uppercased().padding(toLength: 10, withPad: " ", startingAt: 0)) \(what.padding(toLength: 14, withPad: " ", startingAt: 0)) \(stage.evidence) (\(stage.source)\(when))\(stage.problem.flatMap { ObservationProblem(rawValue: $0)?.title }.map { " — \($0)" } ?? "")")
        }
        for relation in report.relations { io.out("  \(relation)") }
        for incident in report.openIncidents { io.out("  ! \(incident)") }
        return CLIExit.ok
    }

    // MARK: open

    private func open(_ args: Arguments) async -> Int32 {
        guard let portfolio = loadPortfolio(), let product = product(args.positional.first, in: portfolio) else { return CLIExit.failure }
        guard !product.isDemo else {
            io.err("error: \(product.name) is a demo product. It has no folder on this Mac.")
            return CLIExit.failure
        }
        var checkout = product.primaryCheckout
        if let name = args.flags["checkout"] {
            checkout = product.checkouts.first { $0.name.lowercased() == name.lowercased() }
            if checkout == nil {
                io.err("error: no checkout \"\(name)\". \(product.name) has: \(product.checkouts.map(\.name).joined(separator: ", "))")
                return CLIExit.failure
            }
        }
        guard let checkout else {
            io.err("error: \(product.name) has no local checkout. Clone it in \(Brand.name) first.")
            return CLIExit.failure
        }
        var bundleID = args.switches.contains("editor") ? portfolio.settings.preferredEditorBundleID : portfolio.settings.preferredTerminalBundleID
        if let name = args.flags["terminal"] {
            guard let match = (KnownApps.terminals + KnownApps.editors).first(where: { $0.name.lowercased().hasPrefix(name.lowercased()) }) else {
                io.err("error: unknown app \"\(name)\". Known: \((KnownApps.terminals + KnownApps.editors).map(\.name).joined(separator: ", "))")
                return CLIExit.usage
            }
            bundleID = match.bundleID
        }
        switch await launcher.openFolder(checkout.path, appBundleID: bundleID) {
        case .opened(let app):
            exec.audit.record(AuditEvent(actor: "cli", action: "open", product: product.slug, detail: "app=\(app) checkout=\(checkout.name)"))
            io.out("Opened \(checkout.name) in \(app).")
            return CLIExit.ok
        case .failed(let reason, let copy):
            io.err("error: \(reason)")
            if let copy { io.err("Run this instead:\n  \(copy)") }
            return CLIExit.failure
        }
    }

    // MARK: doctor

    public struct DoctorRow: Codable, Sendable {
        public var check: String
        public var state: String
        public var detail: String
    }

    private func runDoctor(_ args: Arguments) async -> Int32 {
        var rows: [DoctorRow] = []
        func add(_ step: DoctorStep) { rows.append(DoctorRow(check: step.title, state: step.state.rawValue, detail: step.detail)) }
        var portfolio: Portfolio?
        do {
            let loaded = try store.loadPortfolio()
            portfolio = loaded
            add(DoctorStep("Data", .pass, "\(loaded.products.count) products in \(store.location.directory.path)"))
            let problems = IntegrityChecker.problems(in: loaded)
            add(DoctorStep("Integrity", problems.isEmpty ? .pass : .fail, problems.isEmpty ? "References are sound" : problems.joined(separator: "; ")))
        } catch {
            add(DoctorStep("Data", .fail, String(describing: error)))
        }
        for step in await doctor.toolchain() { add(step) }
        if let portfolio {
            let resolver = exec.credentials
            let references = portfolio.variables.compactMap { variable in variable.credential.map { (variable.key, $0) } }
            let missing = references.filter { !resolver.isAvailable($0.1) }.map(\.0)
            add(DoctorStep("Credentials", missing.isEmpty ? .pass : .fail,
                           missing.isEmpty ? "\(references.count) references, all present" : "Missing from the Keychain: \(missing.joined(separator: ", "))"))
            if let slug = args.flags["product"] {
                guard let product = product(slug, in: portfolio) else { return CLIExit.failure }
                let cache = store.loadCache()
                for checkout in product.checkouts where !product.isDemo {
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: checkout.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    add(DoctorStep("Checkout \(checkout.name)", exists ? .pass : .fail, exists ? checkout.path : "Folder missing: \(checkout.path)"))
                }
                for stage in DriftAnalyzer.chain(product: product, cache: cache) {
                    let state: DoctorStep.State = stage.level >= .reported ? .pass : stage.problem == .notConfigured ? .skipped : .warn
                    add(DoctorStep("Evidence \(stage.stage.rawValue)", state, "\(stage.level.title): \(stage.detail)"))
                }
            }
        }
        if let alias = args.flags["ssh"] {
            // Read-only: resolves the alias, checks known_hosts, and runs `uptime` with strict host key checking.
            for step in await doctor.diagnoseSSH(alias: alias) { add(DoctorStep("SSH \(alias): \(step.title)", step.state, step.detail)) }
        }
        if args.switches.contains("json") {
            io.out(json(rows))
        } else {
            for row in rows {
                let mark = ["pass": "ok  ", "warn": "warn", "fail": "FAIL", "skipped": "skip"][row.state] ?? row.state
                io.out("\(mark)  \(row.check): \(row.detail)")
            }
        }
        return rows.contains { $0.state == "fail" } ? CLIExit.failure : CLIExit.ok
    }

    // MARK: env

    public struct VariableRow: Codable, Sendable {
        public var key: String
        public var state: String
        public var scope: String?
        public var secret: Bool
        public var origin: String?
        public var note: String
    }

    private func env(_ args: Arguments) -> Int32 {
        guard args.positional.first == "list" else {
            io.err("usage: \(Brand.cliName) env list <product> --environment <name> [--profile <name>] [--json]")
            return CLIExit.usage
        }
        guard let portfolio = loadPortfolio(), let product = product(args.positional.dropFirst().first, in: portfolio) else { return CLIExit.failure }
        guard let name = args.flags["environment"] else {
            io.err("error: add --environment <name>. \(product.name) has: \(product.environments.map(\.name).joined(separator: ", "))")
            return CLIExit.usage
        }
        guard let environment = ExecService.environment(named: name, in: product) else {
            io.err("error: \(product.name) has no environment \"\(name)\".")
            return CLIExit.failure
        }
        var profile: TerminalProfile?
        if let profileName = args.flags["profile"] {
            profile = product.profiles.first { $0.name.lowercased() == profileName.lowercased() }
            guard profile != nil else {
                io.err("error: \(product.name) has no profile \"\(profileName)\". Profiles: \(product.profiles.map(\.name).joined(separator: ", "))")
                return CLIExit.failure
            }
        }
        let context = ResolutionContext(product: product, environment: environment, profile: profile,
                                        allowlist: profile.map { Set($0.variableAllowlist) })
        // Names, scopes, and states only. A value is never part of this output, secret or not.
        let rows = VariableResolver.resolve(portfolio.variables, context: context).map {
            VariableRow(key: $0.key, state: $0.state.rawValue, scope: $0.winner?.scope.title, secret: $0.isSecret,
                        origin: $0.winner?.credential?.origin.title, note: $0.note)
        }
        if args.switches.contains("json") {
            io.out(json(rows))
        } else if rows.isEmpty {
            io.out("No variables are defined for \(product.name) in \(environment.name).")
        } else {
            let width = rows.map(\.key.count).max() ?? 8
            for row in rows {
                io.out("\(row.key.padding(toLength: width, withPad: " ", startingAt: 0))  \(row.state.padding(toLength: 11, withPad: " ", startingAt: 0))  \(row.secret ? "secret" : "plain ")  \(row.note)")
            }
        }
        return CLIExit.ok
    }

    // MARK: actions

    public struct ActionRow: Codable, Sendable {
        public var label: String
        public var executor: String
        public var program: String
        public var safety: String
        public var approved: Bool
        public var environment: String?
        public var variables: [String]
    }

    private func actions(_ args: Arguments) -> Int32 {
        guard args.positional.first == "list" else {
            io.err("usage: \(Brand.cliName) actions list <product> [--json]")
            return CLIExit.usage
        }
        guard let portfolio = loadPortfolio(), let product = product(args.positional.dropFirst().first, in: portfolio) else { return CLIExit.failure }
        // The program name only: arguments can hold anything a user typed.
        let rows = product.recipes.map { recipe in
            ActionRow(label: recipe.label, executor: recipe.executor.rawValue,
                      program: recipe.executor == .openURL ? "open link" : (recipe.executable as NSString).lastPathComponent,
                      safety: recipe.safety.rawValue, approved: recipe.isApproved,
                      environment: product.environment(id: recipe.environmentID)?.name, variables: recipe.variableKeys)
        }
        if args.switches.contains("json") {
            io.out(json(rows))
        } else if rows.isEmpty {
            io.out("\(product.name) has no actions.")
        } else {
            for row in rows {
                io.out("\(row.approved ? "approved " : "suggested")  \(row.safety.padding(toLength: 18, withPad: " ", startingAt: 0))  \(row.label)")
            }
        }
        return CLIExit.ok
    }

    // MARK: exec

    private func execute(_ args: Arguments) async -> Int32 {
        guard let slug = args.flags["product"], let environment = args.flags["environment"], let profile = args.flags["profile"], !args.rest.isEmpty else {
            io.err("usage: \(Brand.cliName) exec --product <product> --environment <name> --profile <name> -- <program> [args...]")
            return CLIExit.usage
        }
        guard let portfolio = loadPortfolio() else { return CLIExit.failure }
        let plan: ExecPlan
        do {
            plan = try await exec.plan(ExecRequest(productSlug: slug, environmentName: environment, profileName: profile, command: args.rest),
                                       portfolio: portfolio)
        } catch let denial as ExecDenial {
            io.err("denied: \(denial)")
            return CLIExit.denied
        } catch {
            io.err("error: \(error)")
            return CLIExit.failure
        }
        // Names only, on stderr, so the program's own stdout stays clean.
        if !plan.grantedKeys.isEmpty {
            io.err("\(Brand.cliName): \(plan.executable.lastPathComponent) receives \(plan.grantedKeys.joined(separator: ", ")) (\(plan.environmentName))")
        }
        let code = await spawn(plan, args.switches.contains("redact") || isatty(STDOUT_FILENO) == 0)
        exec.audit.record(AuditEvent(actor: "cli", action: "exec.finished", product: plan.product.slug, environment: plan.environmentName,
                                     detail: "program=\(plan.executable.lastPathComponent) exit=\(code)", outcome: code == 0 ? "ok" : "failed"))
        return code
    }

    // MARK: context

    private var contextLocation: ContextLocation { ContextLocation(store: store.location) }

    /// The newest failed deploy run (else the newest failed run): its failing log, or the fix brief with --brief.
    private func ci(_ args: Arguments) async -> Int32 {
        guard let portfolio = loadPortfolio(), let product = product(args.positional.first, in: portfolio) else { return CLIExit.failure }
        guard let repo = product.repositories.first(where: { $0.provider == "github" && !$0.owner.isEmpty }) else {
            io.err("error: \(CIError.noRepository)")
            return CLIExit.failure
        }
        do {
            let source = GHActionsSource()
            let runs = try await source.runs(repository: repo.fullName)
            let wanted = args.flags["run"].flatMap(Int.init)
            guard let run = wanted.flatMap({ id in runs.first { $0.id == id } }) ?? CILogDigest.pick(runs) else { throw CIError.noFailedRun }
            let report = try await source.report(repository: repo.fullName, run: run)
            let checkout = product.checkouts.first { $0.repositoryID == repo.id } ?? product.primaryCheckout
            if args.switches.contains("fix") {
                guard let checkout, !product.isDemo else {
                    io.err("error: \(product.name) has no local checkout to fix it in.")
                    return CLIExit.failure
                }
                let name = args.flags["agent"] ?? portfolio.settings.aiAgentProgram
                guard AgentPrograms.known.contains(name), let program = ExecutableLocator.find(name, environment: [:]) else {
                    io.err("error: \(name) is not installed.")
                    return CLIExit.failure
                }
                let cache = store.loadCache()
                let brief = try CIFixPrompt.write(report, product: product, checkout: checkout, git: cache.git[checkout.id], location: contextLocation)
                let bundle = try AgentContextBundle.write(for: product, checkout: checkout, portfolio: portfolio, cache: cache, location: contextLocation, mcp: MCPInventory.info(for: product))
                let command = CIFixPrompt.command(program: program, bundle: bundle, brief: brief, run: run, model: args.flags["model"] ?? portfolio.settings.model(for: name))
                if args.switches.contains("print") {
                    io.out(TerminalLauncher.copyCommand(directory: checkout.path, command: command))
                    return CLIExit.ok
                }
                exec.audit.record(AuditEvent(actor: "cli", action: "ci.fix", product: product.slug, detail: "run=\(run.id) agent=\(name)"))
                guard FileManager.default.changeCurrentDirectoryPath(checkout.path) else {
                    io.err("error: cannot enter \(checkout.path)")
                    return CLIExit.failure
                }
                let argv = command.map { strdup($0) } + [nil]
                execv(program.path, argv)
                io.err("error: could not start \(name)")
                return CLIExit.failure
            }
            if args.switches.contains("brief") {
                io.out(CIFixPrompt.brief(report, product: product, checkout: checkout, git: checkout.flatMap { store.loadCache().git[$0.id] }))
            } else {
                io.out("\(run.workflow) · \(run.conclusion) · \(run.branch) \(shortSHA(run.sha)) · \(run.url)")
                for job in report.failedJobs { io.out("failed: \(job.name)\(job.failedSteps.isEmpty ? "" : " › \(job.failedSteps.joined(separator: ", "))")") }
                io.out("")
                io.out(report.excerpt)
            }
            return CLIExit.ok
        } catch {
            io.err("error: \(error)")
            return CLIExit.failure
        }
    }

    /// AI tool usage from the logs those tools keep on this Mac. Numbers only.
    private func usage() -> Int32 {
        let tools = AIUsageReader.all()
        guard !tools.isEmpty else {
            io.out("No Claude Code, Codex, or OpenCode data was found on this Mac.")
            return CLIExit.ok
        }
        for tool in tools {
            io.out("\(tool.tool)\(tool.plan.map { " (\($0))" } ?? "") · \(tool.source == .reportedByTool ? "limits reported by the tool" : "counted from local logs")")
            for window in tool.windows {
                if window.hasReset() {
                    io.out("  \(window.name): reset \(RelativeTime.short(window.resetsAt)) (was \(Int(window.usedPercent))% used when last seen \(RelativeTime.short(window.observedAt)))")
                } else {
                    io.out("  \(window.name): \(Int(window.usedPercent))% used, \(Int(100 - window.usedPercent))% left, resets \(RelativeTime.short(window.resetsAt))")
                }
            }
            if let block = tool.block, let end = tool.blockEnd {
                io.out("  This 5-hour block: \(TokenFormat.short(block.fresh)) tokens\(tool.largestBlock.map { " (\(Int(Double(block.fresh) / Double(max(1, $0)) * 100))% of your largest block)" } ?? ""), ends \(RelativeTime.short(end))")
            }
            io.out("  Today: \(TokenFormat.short(tool.today.fresh)) tokens + \(TokenFormat.short(tool.today.cacheRead)) cache reads\(tool.costToday.map { String(format: ", $%.2f est.", $0) } ?? "")")
            for model in tool.byModel.prefix(3) { io.out("    \(model.model): \(TokenFormat.short(model.tokens.fresh))") }
            io.out("  Last 7 days: " + tool.daily.map { $0.map(TokenFormat.short) ?? "—" }.joined(separator: " "))
            if let last = tool.lastActivity { io.out("  Last activity: \(RelativeTime.short(last))") }
        }
        return CLIExit.ok
    }

    public struct LinkRow: Codable, Sendable {
        public var site: String
        public var path: String
        public var checkout: String
        public var state: String
        public var tracked: Bool
    }

    private func links(_ args: Arguments) -> Int32 {
        guard let portfolio = loadPortfolio(), let product = product(args.positional.first, in: portfolio) else { return CLIExit.failure }
        let sites = InstallLinks.findWordPressSites(roots: InstallLinks.defaultSearchRoots(extra: portfolio.settings.projectRoots))
        var rows: [LinkRow] = []
        for link in product.installLinks {
            guard let checkout = product.checkout(id: link.checkoutID) else { continue }
            rows.append(LinkRow(site: link.siteName, path: link.linkPath, checkout: checkout.name, state: InstallLinks.state(of: link, checkout: checkout).title, tracked: true))
        }
        for checkout in product.checkouts {
            for found in InstallLinks.existingLinks(into: checkout, sites: sites) where !rows.contains(where: { $0.path == found.linkPath }) {
                rows.append(LinkRow(site: found.siteName, path: found.linkPath, checkout: checkout.name, state: "Linked by hand", tracked: false))
            }
            for suggestion in InstallLinks.suggestions(for: checkout, existing: product.installLinks, sites: sites) where !rows.contains(where: { $0.path == suggestion.link.linkPath }) {
                rows.append(LinkRow(site: suggestion.site.name, path: suggestion.link.linkPath, checkout: checkout.name,
                                    state: suggestion.hasCopy ? "Has its own copy\(suggestion.copyVersion.map { " (\($0))" } ?? "")" : "Not linked", tracked: false))
            }
        }
        if args.switches.contains("json") {
            io.out(json(rows))
        } else if rows.isEmpty {
            io.out("No install links, and no local WordPress site to suggest.")
        } else {
            for row in rows { io.out("\(row.state.padding(toLength: 22, withPad: " ", startingAt: 0))  \(row.site) · \(row.path)") }
        }
        return CLIExit.ok
    }

    /// Links a WordPress plugin or theme checkout into a local site, or removes that link. Never overwrites.
    private func link(_ args: Arguments) -> Int32 {
        guard let portfolio = loadPortfolio(), let product = product(args.positional.first, in: portfolio) else { return CLIExit.failure }
        guard let siteName = args.flags["site"] else {
            io.err("usage: \(Brand.cliName) link <product> --site <local site> [--checkout <name>] [--remove]")
            return CLIExit.usage
        }
        let sites = InstallLinks.findWordPressSites(roots: InstallLinks.defaultSearchRoots(extra: portfolio.settings.projectRoots))
        guard let site = sites.first(where: { $0.name.lowercased() == siteName.lowercased() }) else {
            io.err("error: no local WordPress site \"\(siteName)\". Found: \(sites.map(\.name).joined(separator: ", "))")
            return CLIExit.failure
        }
        let checkout = args.flags["checkout"].flatMap { name in product.checkouts.first { $0.name.lowercased() == name.lowercased() } } ?? product.primaryCheckout
        guard let checkout, !product.isDemo else {
            io.err("error: \(product.name) has no local checkout.")
            return CLIExit.failure
        }
        guard let package = InstallLinks.package(at: checkout.path) else {
            io.err("error: \(checkout.name) has no WordPress plugin or theme header. Use the app's Link into Folder for other folders.")
            return CLIExit.failure
        }
        var link = InstallLink()
        link.checkoutID = checkout.id
        link.kind = package.kind
        link.destinationFolder = package.kind == .wordpressTheme ? site.themesFolder : site.pluginsFolder
        link.linkName = (checkout.path as NSString).lastPathComponent
        link.siteName = site.name
        do {
            if args.switches.contains("remove") {
                try InstallLinks.remove(link, checkout: checkout)
                io.out("Removed \(link.linkPath). \(checkout.name) was not touched.")
            } else {
                try InstallLinks.create(link, checkout: checkout)
                io.out("Linked \(link.linkPath) → \(checkout.path)")
                io.err("Track it in \(Brand.name) from the product's Install links card.")
            }
            exec.audit.record(AuditEvent(actor: "cli", action: args.switches.contains("remove") ? "link.remove" : "link.create", product: product.slug, detail: "site=\(site.name)"))
            return CLIExit.ok
        } catch {
            io.err("error: \(error)")
            return CLIExit.failure
        }
    }

    private func context(_ args: Arguments) -> Int32 {
        guard let portfolio = loadPortfolio(), let product = product(args.positional.first, in: portfolio) else { return CLIExit.failure }
        if args.switches.contains("write") {
            do {
                let bundle = try AgentContextBundle.write(for: product, portfolio: portfolio, cache: store.loadCache(), location: contextLocation, mcp: MCPInventory.info(for: product))
                io.out(bundle.contextFile.path)
                io.err("about \(bundle.approxTokens) tokens\(bundle.relatedNames.isEmpty ? "" : ", related: \(bundle.relatedNames.joined(separator: ", "))")")
            } catch {
                io.err("error: \(error)")
                return CLIExit.failure
            }
            return CLIExit.ok
        }
        io.out(AgentPrograms.contextFile(for: product, cache: store.loadCache()))
        return CLIExit.ok
    }

    private func pack(_ args: Arguments) async -> Int32 {
        guard let portfolio = loadPortfolio(), let product = product(args.positional.first, in: portfolio) else { return CLIExit.failure }
        var targets: [(Product, LocalCheckout)] = []
        if args.switches.contains("related") {
            for link in product.contextLinks {
                if let related = portfolio.product(id: link.productID), !related.isDemo {
                    targets += related.checkouts.map { (related, $0) }
                }
            }
        } else if let name = args.flags["checkout"] {
            guard let checkout = product.checkouts.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                io.err("error: no checkout \"\(name)\".")
                return CLIExit.failure
            }
            targets = [(product, checkout)]
        } else {
            targets = product.checkouts.map { (product, $0) }
        }
        guard !product.isDemo, !targets.isEmpty else {
            io.err("error: nothing to pack. \(product.isDemo ? "\(product.name) is a demo product." : "Link a checkout first.")")
            return CLIExit.failure
        }
        let builder = PackBuilder(location: contextLocation)
        let cache = store.loadCache()
        let git = GitService()
        var failed = false
        for (owner, checkout) in targets {
            io.err("packing \(owner.name) · \(checkout.name)…")
            do {
                let snapshot = cache.git[checkout.id]?.headSHA == nil ? await git.snapshot(path: checkout.path) : cache.git[checkout.id]
                let info = try await builder.build(checkout, git: snapshot)
                io.out(info.packKept ? "\(builder.location.pack(checkout).path)  ~\(info.approxTokens) tokens, map ~\(RepoMap.defaultBudgetTokens)"
                                     : "\(builder.location.map(checkout).path)  map only: the pack was \(info.bytes / 1_000_000) MB")
            } catch {
                io.err("error: \(owner.name) · \(checkout.name): \(error)")
                failed = true
            }
        }
        return failed ? CLIExit.failure : CLIExit.ok
    }

    private func agent(_ args: Arguments) async -> Int32 {
        guard let portfolio = loadPortfolio(), let product = product(args.positional.first, in: portfolio) else { return CLIExit.failure }
        guard !product.isDemo else {
            io.err("error: \(product.name) is a demo product. It has no folder on this Mac.")
            return CLIExit.failure
        }
        let name = args.flags["agent"] ?? portfolio.settings.aiAgentProgram
        guard AgentPrograms.known.contains(name) else {
            io.err("error: unknown agent \"\(name)\". Known: \(AgentPrograms.known.joined(separator: ", "))")
            return CLIExit.usage
        }
        guard let program = ExecutableLocator.find(name, environment: [:]) else {
            io.err("error: \(name) is not installed.")
            return CLIExit.failure
        }
        let bundle: AgentContextBundle
        do {
            bundle = try AgentContextBundle.write(for: product, portfolio: portfolio, cache: store.loadCache(), location: contextLocation, mcp: MCPInventory.info(for: product))
        } catch {
            io.err("error: \(error)")
            return CLIExit.failure
        }
        let command = bundle.command(program: program, model: args.flags["model"] ?? portfolio.settings.model(for: name))
        if args.switches.contains("print") {
            io.out(TerminalLauncher.copyCommand(directory: bundle.workingDirectory, command: command))
            return CLIExit.ok
        }
        exec.audit.record(AuditEvent(actor: "cli", action: "agent.start", product: product.slug,
                                     detail: "agent=\(name) related=\(bundle.relatedNames.joined(separator: ","))"))
        io.err("\(name) in \(bundle.workingDirectory)\(bundle.relatedNames.isEmpty ? "" : " with context for \(bundle.relatedNames.joined(separator: ", "))")")
        // Replace this process with the agent, so it owns the terminal.
        guard FileManager.default.changeCurrentDirectoryPath(bundle.workingDirectory) else {
            io.err("error: cannot enter \(bundle.workingDirectory)")
            return CLIExit.failure
        }
        let argv = command.map { strdup($0) } + [nil]
        execv(program.path, argv)
        io.err("error: could not start \(name): \(String(cString: strerror(errno)))")
        return CLIExit.failure
    }
}

/// Starts the granted program and waits for it.
public enum ChildProcess {
    /// With `redactOutput` the program's output passes through the redactor, which removes
    /// the exact values that were granted. Without it the program owns the terminal.
    public static func run(_ plan: ExecPlan, redactOutput: Bool) async -> Int32 {
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardInput = FileHandle.standardInput
        let redactor = Redactor(knownValues: plan.secretValues)
        var streams: [(pipe: Pipe, target: FileHandle, buffer: LineBuffer)] = []
        if redactOutput {
            for (target, isError) in [(FileHandle.standardOutput, false), (FileHandle.standardError, true)] {
                let pipe = Pipe()
                let buffer = LineBuffer()
                streams.append((pipe, target, buffer))
                if isError { process.standardError = pipe } else { process.standardOutput = pipe }
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    // Empty data means end of file. Without this the handler would spin.
                    guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                    for line in buffer.feed(data) { target.write(Data((redactor.redact(line) + "\n").utf8)) }
                }
            }
        }
        // Ctrl-C reaches the child through the terminal's process group. The parent waits for it.
        signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, SIG_DFL) }
        let status: Int32? = await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                FileHandle.standardError.write(Data("error: could not start \(plan.executable.lastPathComponent): \(error.localizedDescription)\n".utf8))
                continuation.resume(returning: nil)
            }
        }
        for stream in streams {
            let handle = stream.pipe.fileHandleForReading
            handle.readabilityHandler = nil
            // What is still in the pipe, read without blocking, then the last unfinished line.
            for line in stream.buffer.feed(SystemProcessRunner.drain(handle)) { stream.target.write(Data((redactor.redact(line) + "\n").utf8)) }
            let rest = stream.buffer.flush()
            if !rest.isEmpty { stream.target.write(Data(redactor.redact(rest).utf8)) }
        }
        return status ?? CLIExit.failure
    }
}

/// Splits a byte stream into lines, so a secret split across two reads is still matched.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func feed(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }

    /// The text after the last newline.
    func flush() -> String {
        lock.withLock {
            defer { pending = Data() }
            return String(decoding: pending, as: UTF8.self)
        }
    }
}
