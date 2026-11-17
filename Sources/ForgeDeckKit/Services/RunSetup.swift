import Foundation

// Run setup: an agent works out how a product runs on this Mac and proposes the commands in
// `.forgedeck/run.json`. ForgeDeck checks every command and shows them; the person's review is the approval.
// Commands are argument arrays, run on this Mac only. Nothing that deploys, publishes, or pushes is accepted.

/// One command the agent proposes.
public struct ProposedRun: Codable, Hashable, Sendable {
    /// What the menu shows: "Start Dev Server", "Run Tests", "Start with Docker".
    public var label: String
    /// web, desktop, mobile, or site: Play offers it. Omitted or "action": only in Actions (tests, builds, seeding).
    public var kind: String?
    /// Each step is a program and its arguments. Run in order; the first failure stops the rest.
    public var steps: [[String]]?
    /// Folder to run in, relative to the checkout. Empty is the checkout itself.
    public var directory: String?
    /// A page on this Mac to open once it answers, like http://localhost:5173. A site with no steps just opens it.
    public var url: String?
    /// Variable names the command needs, given through ForgeDeck. Never values.
    public var variables: [String]?
    /// Keeps running in a terminal (servers, watchers, apps). Defaults to true for web, desktop, and mobile.
    public var terminal: Bool?
    /// Why: the files that told the agent this is how it runs.
    public var note: String?

    public init(label: String, kind: String? = nil, steps: [[String]]? = nil, directory: String? = nil, url: String? = nil,
                variables: [String]? = nil, terminal: Bool? = nil, note: String? = nil) {
        self.label = label
        self.kind = kind
        self.steps = steps
        self.directory = directory
        self.url = url
        self.variables = variables
        self.terminal = terminal
        self.note = note
    }
}

public struct RunProposalFile: Sendable, Hashable {
    public var checkoutID: UUID
    public var checkoutName: String
    public var checkoutPath: String
    public var entries: [ProposedRun]
    public var error: String?

    public init(checkoutID: UUID, checkoutName: String, checkoutPath: String, entries: [ProposedRun], error: String? = nil) {
        self.checkoutID = checkoutID
        self.checkoutName = checkoutName
        self.checkoutPath = checkoutPath
        self.entries = entries
        self.error = error
    }
}

/// One proposed command, checked against the product as it is now.
public struct RunProposal: Sendable, Hashable, Identifiable {
    public var id: String
    public var checkoutName: String
    public var entry: ProposedRun
    /// The recipe adding it saves. Approved: the review is the approval.
    public var recipe: ActionRecipe
    /// Blocks adding it.
    public var problems: [String]
    /// Shown, does not block.
    public var warnings: [String]
    /// The recipe it replaces, when one has the same name.
    public var existingID: UUID?
    /// False when an identical recipe is already saved.
    public var changes: Bool

    public var isAddable: Bool { problems.isEmpty && changes }
    public var play: PlayOption.Kind? { recipe.play }
}

public enum RunSetup {
    public static let relativePath = ".forgedeck/run.json"
    static let maxBytes = 64 * 1024
    static let maxEntries = 12
    static let maxSteps = 8
    /// Words that mean a command reaches past this Mac. Run setup is for running and testing locally.
    static let remoteWords: Set<String> = ["deploy", "publish", "push", "release", "rsync", "scp", "ssh", "sftp", "upload"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh"]

    // MARK: Reading

    public static func read(_ product: Product) -> [RunProposalFile] {
        product.checkouts.compactMap { checkout in
            read(folder: checkout.path).map {
                RunProposalFile(checkoutID: checkout.id, checkoutName: checkout.name, checkoutPath: checkout.path, entries: $0.entries, error: $0.error)
            }
        }
    }

    public static func read(folder: String) -> (entries: [ProposedRun], error: String?)? {
        let url = URL(fileURLWithPath: folder).appending(path: relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { return ([], "\(relativePath) is not a regular file.") }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxBytes else { return ([], "\(relativePath) is larger than 64 KB.") }
        guard let data = try? Data(contentsOf: url) else { return ([], "\(relativePath) could not be read.") }
        return parse(data)
    }

    public static func parse(_ data: Data) -> (entries: [ProposedRun], error: String?) {
        struct File: Decodable { var commands: [ProposedRun] }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.commands.count <= maxEntries else { return ([], "The file proposes more than \(maxEntries) commands.") }
            return (file.commands, nil)
        } catch {
            return ([], "\(relativePath) is not valid: it needs {\"commands\": [{\"label\": \"Start Dev Server\", \"kind\": \"web\", \"steps\": [[\"npm\", \"run\", \"dev\"]]}]}.")
        }
    }

    // MARK: Checking

    public static func kind(_ text: String?) -> (kind: PlayOption.Kind?, valid: Bool) {
        let value = (text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty || value == "action" || value == "test" || value == "build" { return (nil, true) }
        if let kind = PlayOption.Kind(rawValue: value) { return (kind, true) }
        return (nil, false)
    }

    static func isValidVariable(_ name: String) -> Bool {
        guard let first = name.first, (1...64).contains(name.count), first == "_" || (first.isASCII && first.isLetter) else { return false }
        return name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    public static func plan(_ product: Product, files: [RunProposalFile]) -> [RunProposal] {
        var seen = Set<String>()
        var result: [RunProposal] = []
        for file in files {
            for (index, entry) in file.entries.enumerated() {
                let proposal = check(entry, in: product, checkoutID: file.checkoutID, checkoutPath: file.checkoutPath,
                                     id: "\(file.checkoutID.uuidString)-\(index)", checkoutName: file.checkoutName)
                guard seen.insert("\(file.checkoutID)-\(proposal.recipe.label.lowercased())").inserted else { continue }
                result.append(proposal)
            }
        }
        return result
    }

    public static func check(_ entry: ProposedRun, in product: Product, checkoutID: UUID, checkoutPath: String,
                             id: String = UUID().uuidString, checkoutName: String = "") -> RunProposal {
        var problems: [String] = []
        var warnings: [String] = []
        let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty || label.count > 60 || label.contains(where: \.isNewline) { problems.append("Give a label of 1 to 60 characters on one line.") }

        let (kind, kindValid) = kind(entry.kind)
        if !kindValid { problems.append("Unknown kind \"\(entry.kind ?? "")\". Use web, desktop, mobile, site, or action.") }

        let steps = (entry.steps ?? []).map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
        if steps.count > maxSteps { problems.append("At most \(maxSteps) steps.") }
        for step in steps {
            guard let program = step.first, !program.isEmpty else { problems.append("A step is empty. Each step is [\"program\", \"argument\", …]."); continue }
            if step.contains(where: { $0.contains("\0") || $0.contains("\n") }) { problems.append("\"\(program)\" has an argument with a line break.") }
            if program.contains("/") && !program.hasPrefix("./") {
                problems.append("\"\(program)\": give the program by name (npm, docker, php) or as ./script in the folder.")
            } else if shells.contains(program), step.dropFirst().contains(where: { $0 == "-c" || $0 == "-lc" }) {
                problems.append("\(program) -c runs a shell string. Give the program and its arguments as a list, one step per command.")
            } else if !program.hasPrefix("./"), ExecutableLocator.find(program) == nil {
                warnings.append("\(program) is not installed on this Mac.")
            }
            let words = Set(step.map { $0.lowercased() })
            if let word = words.intersection(remoteWords).sorted().first {
                problems.append("\"\(step.joined(separator: " "))\" looks like it reaches past this Mac (\(word)). Run setup only runs and tests locally.")
            }
        }

        let directory = (entry.directory ?? "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if directory.hasPrefix("~") || entry.directory?.hasPrefix("/") == true || directory.split(separator: "/").contains("..") {
            problems.append("directory must be a folder inside the checkout, like \"web\" or \"apps/api\".")
        } else if !directory.isEmpty {
            var isFolder: ObjCBool = false
            if !FileManager.default.fileExists(atPath: (checkoutPath as NSString).appendingPathComponent(directory), isDirectory: &isFolder) || !isFolder.boolValue {
                problems.append("The folder \"\(directory)\" does not exist in \(checkoutName.isEmpty ? "the checkout" : checkoutName).")
            }
        }
        for step in steps {
            if let program = step.first, program.hasPrefix("./"),
               !FileManager.default.isExecutableFile(atPath: ((checkoutPath as NSString).appendingPathComponent(directory) as NSString).appendingPathComponent(String(program.dropFirst(2)))) {
                problems.append("\(program) is not an executable file in the folder. Use [\"zsh\", \"\(program)\"] or make it executable.")
            }
        }

        let url = entry.url?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let url, PlayPlanner.localURL(url) == nil {
            problems.append("url must be a page on this Mac (localhost, 127.0.0.1, or a .local or .test host).")
        }
        if steps.isEmpty {
            if url == nil { problems.append("Give steps to run, or a url for a site that is already running.") }
            else if kind != .site { problems.append("A command with no steps only opens its url: give it kind \"site\".") }
        }
        let variables = (entry.variables ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
        for name in variables where !isValidVariable(name) { problems.append("\"\(name)\" is not a variable name. Give names only, like DATABASE_URL.") }

        var recipe = ActionRecipe()
        recipe.label = String(label.prefix(60))
        recipe.checkoutID = checkoutID
        recipe.environmentID = product.environment(tier: .development)?.id
        recipe.safety = .localWrite
        recipe.isApproved = true
        recipe.play = kind
        recipe.variableKeys = variables
        recipe.workingSubdirectory = directory
        recipe.url = url
        if steps.isEmpty {
            recipe.executor = .openURL
        } else {
            recipe.setSteps(steps)
            recipe.opensInTerminal = entry.terminal ?? (kind == .web || kind == .desktop || kind == .mobile)
        }

        let existing = product.recipes.first { $0.label.lowercased() == recipe.label.lowercased() && ($0.checkoutID ?? product.primaryCheckout?.id) == checkoutID }
        if let existing { recipe.id = existing.id }
        let changes = existing.map { !same($0, recipe) } ?? true
        return RunProposal(id: id, checkoutName: checkoutName, entry: entry, recipe: recipe, problems: problems, warnings: warnings,
                           existingID: existing?.id, changes: changes)
    }

    static func same(_ a: ActionRecipe, _ b: ActionRecipe) -> Bool {
        a.executor == b.executor && a.steps == b.steps && a.workingSubdirectory == b.workingSubdirectory && a.url == b.url
            && a.variableKeys == b.variableKeys && a.play == b.play && a.opensInTerminal == b.opensInTerminal && a.isApproved
    }

    /// Saves the command: a new recipe, or the one with the same name replaced. Nothing else changes.
    public static func apply(_ proposal: RunProposal, to product: inout Product) {
        guard proposal.isAddable else { return }
        if let id = proposal.existingID, let index = product.recipes.firstIndex(where: { $0.id == id }) {
            product.recipes[index] = proposal.recipe
        } else {
            product.recipes.append(proposal.recipe)
        }
    }

    // MARK: The prompt

    /// What ForgeDeck can see without running anything, for the agent to start from.
    public static func hints(for checkout: LocalCheckout) -> [String] {
        let fm = FileManager.default
        let names = Set((try? fm.contentsOfDirectory(atPath: checkout.path)) ?? [])
        let known = ["package.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "docker-compose.yml", "docker-compose.yaml", "compose.yaml",
                     "compose.yml", "Dockerfile", "Makefile", "Procfile", "justfile", "Taskfile.yml", "pyproject.toml", "requirements.txt",
                     "manage.py", "Gemfile", "composer.json", "artisan", "go.mod", "Cargo.toml", "Package.swift", "build.sh", "pubspec.yaml",
                     "capacitor.config.ts", "capacitor.config.json", "app.json", "vite.config.ts", "next.config.js", "next.config.mjs",
                     "astro.config.mjs", "wp-config.php", "style.css", ".env.example", ".nvmrc", ".tool-versions", "mise.toml", "README.md"]
        var out = known.filter(names.contains)
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { out.append("an Xcode project") }
        if checkout.path.contains("/wp-content/plugins/") { out.append("a WordPress plugin folder") }
        if checkout.path.contains("/wp-content/themes/") { out.append("a WordPress theme folder") }
        return out
    }

    public static func prompt(for product: Product, checkout: LocalCheckout, cli: String, localSite: LocalSite?) -> String {
        let tool = cli.contains(" ") ? "\"\(cli)\"" : cli
        var facts: [String] = ["- Product: \(product.name) (`\(product.slug)`)\(product.tagline.isEmpty ? "" : ": \(product.tagline)")"]
        facts.append("- Folder: \(checkout.path)")
        if product.checkouts.count > 1 {
            facts.append("- Other checkouts: " + product.checkouts.filter { $0.id != checkout.id }.map { "\($0.name) (\($0.path))" }.joined(separator: ", "))
        }
        if !product.stack.isEmpty { facts.append("- Stack: " + product.stack.joined(separator: ", ")) }
        let hints = hints(for: checkout)
        if !hints.isEmpty { facts.append("- Files at the top: " + hints.joined(separator: ", ")) }
        if let localSite { facts.append("- Runs inside the Local site \(localSite.name) at \(localSite.url(admin: false))") }
        if let development = product.environment(tier: .development), !development.domains.isEmpty {
            facts.append("- Local addresses: " + development.domains.joined(separator: ", "))
        }
        let saved = product.recipes.filter { $0.executor != .ssh }.prefix(12)
        if !saved.isEmpty {
            facts.append("- Commands already saved:")
            for recipe in saved {
                let what = recipe.executor == .openURL ? (recipe.url ?? "") : recipe.steps.map { $0.joined(separator: " ") }.joined(separator: " → ")
                facts.append("  - \(recipe.label)\(recipe.play.map { " [\($0.rawValue)]" } ?? ""): \(what)\(recipe.isApproved ? "" : " (not approved)")")
            }
        }
        return """
        Set up how \(product.name) runs on this Mac, so the Play button in \(Brand.name) launches it and Actions can test it.

        What \(Brand.name) knows:
        \(facts.joined(separator: "\n"))

        1. Work out what this product is and how people use it: a web app, an API, a desktop or mobile app, a CLI, a WordPress plugin, \
        a library. Read the README, package scripts, Docker and compose files, Makefile, Procfile, and the framework config. \
        Prefer what the project already documents over anything you invent.
        2. Work out what it needs first: runtime versions, installing dependencies, a database or services (Docker), \
        a .env file (copy .env.example; ask me for values, never invent secrets), migrations or seed data.
        3. Try it. Run the install and start commands, check the page or app answers, run the tests, then stop anything you started. \
        If something fails, fix the setup, not the product's code, and tell me what you changed. Ask before changing project files.
        4. Write `\(relativePath)` in the folder with every command, best first:
           {"commands": [
             {"label": "Start Dev Server", "kind": "web", "steps": [["npm", "install"], ["npm", "run", "dev"]], "url": "http://localhost:5173", "note": "package.json dev script, Vite"},
             {"label": "Start with Docker", "kind": "web", "steps": [["docker", "compose", "up", "--build"]], "url": "http://localhost:8080"},
             {"label": "Run Tests", "steps": [["npm", "test"]]}
           ]}
           - kind: web, desktop, mobile, or site for what Play launches; leave it out for tests, builds, and seeding.
           - steps: each step is a program and its arguments, no shell strings (no `-c` scripts, no `&&`, no pipes). A script in the folder is ["zsh", "./script.sh"].
           - url: the page to open once it answers, on this Mac only. A site that already runs elsewhere (Local, MAMP, Valet) is \
        {"label": "Open Site", "kind": "site", "url": "http://example.local"} with no steps.
           - directory: a subfolder to run in. variables: names the command needs (values stay in \(Brand.name)). \
        terminal: false for a command that finishes and should show its output in a log.
           - Nothing that deploys, publishes, pushes, or touches a remote or production system.
        5. Run `\(tool) run check \(product.slug)` and fix every problem it prints.
        6. Tell me in a few lines how it runs, then tell me to press Review… on Run setup in \(Brand.name). Nothing is saved before that.
        """
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
