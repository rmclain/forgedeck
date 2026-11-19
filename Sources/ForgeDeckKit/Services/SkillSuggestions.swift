import Foundation

// Skills for one product: the agent looks at the product and suggests skills in .forgedeck/skills.json. A suggestion
// is a skill from a GitHub skills repository (added with ForgeDeck's own shallow clone, nothing runs) or a Claude Code
// plugin (installed with `claude plugin install` after the person confirms). The product keeps the ones chosen; the
// active ones are named in the agent's prompt each time it starts there.

/// A skill or plugin chosen for one product.
public struct AgentSkill: Codable, Hashable, Sendable, Identifiable {
    /// The skill's name, or the plugin's.
    public var id: String
    /// GitHub owner/repo of a skills repository. nil for a plugin.
    public var repo: String?
    /// The plugin marketplace: a configured name or a GitHub owner/repo. nil for a skill.
    public var marketplace: String?
    public var why: String
    /// Named in the agent's prompt when it starts in this product.
    public var isActive: Bool
    /// A suggestion the person turned down. Kept so it is not offered again.
    public var isDismissed: Bool

    public var isPlugin: Bool { marketplace != nil }

    public init(id: String, repo: String? = nil, marketplace: String? = nil, why: String = "", isActive: Bool = true, isDismissed: Bool = false) {
        self.id = id
        self.repo = repo
        self.marketplace = marketplace
        self.why = why
        self.isActive = isActive
        self.isDismissed = isDismissed
    }
}

/// One entry of `.forgedeck/skills.json`, as the agent wrote it. Either `repo` (a skill) or `plugin` and `marketplace`.
public struct ProposedSkill: Codable, Hashable, Sendable {
    public var name: String
    public var repo: String?
    public var plugin: String?
    public var marketplace: String?
    public var why: String?
    /// For a plugin, what it adds: skills, commands, agents, hooks, mcp. Hooks and MCP servers run as the person.
    public var includes: [String]?

    public init(name: String, repo: String? = nil, plugin: String? = nil, marketplace: String? = nil, why: String? = nil, includes: [String]? = nil) {
        self.name = name
        self.repo = repo
        self.plugin = plugin
        self.marketplace = marketplace
        self.why = why
        self.includes = includes
    }

    public var isPlugin: Bool { marketplace != nil || plugin != nil }
    /// Where it comes from, for a person to read.
    public var origin: String { isPlugin ? "\(plugin ?? name) from \(marketplace ?? "?")" : repo ?? "" }
    public var link: String? {
        if let repo { return "https://github.com/\(repo)" }
        if let marketplace, marketplace.contains("/") { return "https://github.com/\(marketplace)" }
        return nil
    }

    public var skill: AgentSkill {
        AgentSkill(id: name, repo: isPlugin ? nil : repo, marketplace: isPlugin ? marketplace : nil, why: why ?? "")
    }
}

/// What a product's checkouts suggest, as last read.
public struct SkillFile: Sendable, Hashable {
    public var entries: [ProposedSkill]
    public var errors: [String]
    public init(entries: [ProposedSkill], errors: [String]) {
        self.entries = entries
        self.errors = errors
    }
}

/// A suggestion checked.
public struct SkillSuggestion: Hashable, Sendable, Identifiable {
    public var id: String { entry.name }
    public var entry: ProposedSkill
    public var problems: [String]
    public var isValid: Bool { problems.isEmpty }
    /// A plugin with hooks or an MCP server: code that runs in every Claude Code session.
    public var runsCode: Bool { entry.includes?.contains { ["hooks", "mcp"].contains($0.lowercased()) } == true }
}

public enum SkillSuggestions {
    public static let relativePath = ".forgedeck/skills.json"
    static let maxBytes = 32_768
    static let maxEntries = 12
    public static let officialMarketplace = "claude-plugins-official"

    // MARK: Reading

    public static func read(folder: String) -> (entries: [ProposedSkill], error: String?)? {
        let url = URL(fileURLWithPath: folder).appending(path: relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { return ([], "\(relativePath) is not a regular file.") }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxBytes else { return ([], "\(relativePath) is larger than 32 KB.") }
        guard let data = try? Data(contentsOf: url) else { return ([], "\(relativePath) could not be read.") }
        return parse(data)
    }

    /// Every checkout's file, first checkout first. A name given twice keeps its first entry.
    public static func read(_ product: Product) -> SkillFile {
        var entries: [ProposedSkill] = []
        var errors: [String] = []
        for checkout in product.checkouts {
            guard let file = read(folder: checkout.path) else { continue }
            if let error = file.error { errors.append("\(checkout.name): \(error)") }
            for entry in file.entries where !entries.contains(where: { $0.name == entry.name }) { entries.append(entry) }
        }
        return SkillFile(entries: entries, errors: errors)
    }

    public static func parse(_ data: Data) -> (entries: [ProposedSkill], error: String?) {
        struct File: Decodable { var skills: [ProposedSkill] }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.skills.count <= maxEntries else { return ([], "The file suggests more than \(maxEntries) skills.") }
            return (file.skills, nil)
        } catch {
            return ([], "\(relativePath) is not valid: it needs {\"skills\": [{\"name\": \"skill-name\", \"repo\": \"owner/repo\", \"why\": \"…\"}]}.")
        }
    }

    // MARK: Checking

    static func isName(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// A configured marketplace name (`claude-plugins-official`) or a GitHub owner/repo.
    static func isMarketplace(_ text: String) -> Bool {
        isName(text) || UpdateChecker.isValidRepository(text)
    }

    public static func check(_ entry: ProposedSkill) -> SkillSuggestion {
        var problems: [String] = []
        if !isName(entry.name) { problems.append("\"\(entry.name)\" is not a usable name: letters, numbers, dots, dashes.") }
        if entry.isPlugin {
            if entry.repo != nil { problems.append("Give repo for a skill, or plugin and marketplace for a plugin, not both.") }
            if let plugin = entry.plugin, !isName(plugin) { problems.append("\"\(plugin)\" is not a plugin name.") }
            if !isMarketplace(entry.marketplace ?? "") {
                problems.append("\"\(entry.marketplace ?? "")\" is not a marketplace: a name like \(officialMarketplace) or a GitHub owner/repo.")
            }
        } else if !UpdateChecker.isValidRepository(entry.repo ?? "") {
            problems.append("\"\(entry.repo ?? "")\" is not a GitHub owner/repo. A skill needs repo; a plugin needs plugin and marketplace.")
        }
        if (entry.why ?? "").count > 400 { problems.append("\"why\" is longer than 400 characters.") }
        return SkillSuggestion(entry: entry, problems: problems)
    }

    /// Suggestions not chosen or turned down yet.
    public static func suggestions(for product: Product, entries: [ProposedSkill]) -> [SkillSuggestion] {
        let known = Set((product.agentSkills ?? []).map(\.id))
        return entries.filter { !known.contains($0.name) }.map(check)
    }

    /// Skill folder names (holding a SKILL.md) in Claude Code's and the shared agents' skills folders.
    public static func installedSkills(home: URL) -> Set<String> {
        var names = Set<String>()
        for target in SkillTarget.allCases {
            let folder = target.directory(home: home)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
                if FileManager.default.fileExists(atPath: folder.appending(path: "\(name)/SKILL.md").path) { names.insert(name) }
            }
        }
        return names
    }

    // MARK: Plugins

    public static let listArguments = ["plugin", "list", "--json"]

    /// Plugin names `claude plugin list --json` reports as installed and enabled.
    public static func installedPlugins(fromListJSON data: Data) -> Set<String> {
        struct Row: Decodable { var id: String; var enabled: Bool? }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return [] }
        return Set(rows.filter { $0.enabled != false }.compactMap { $0.id.split(separator: "@").first.map(String.init) })
    }

    /// `claude plugin install`, user scope. A configured marketplace goes by name, a GitHub one with --marketplace.
    /// No -y: a plugin that runs a command to install is left for a terminal, where the person sees the command.
    public static func installArguments(plugin: String, marketplace: String) -> [String] {
        marketplace.contains("/")
            ? ["plugin", "install", plugin, "--marketplace", marketplace, "--scope", "user"]
            : ["plugin", "install", "\(plugin)@\(marketplace)", "--scope", "user"]
    }

    // MARK: The prompt

    public static func activeNames(_ product: Product) -> [String] { active(product).map(\.id) }

    static func active(_ product: Product) -> [AgentSkill] { (product.agentSkills ?? []).filter { $0.isActive && !$0.isDismissed } }

    /// One line for the agent's prompt naming the active skills, or nil when there are none.
    public static func promptLine(for product: Product) -> String? {
        let active = active(product)
        guard !active.isEmpty else { return nil }
        let names = active.map { $0.why.isEmpty ? $0.id : "\($0.id) (\($0.why))" }
        return "Skills chosen for \(product.name): \(names.joined(separator: "; ")). Use them when the work fits."
    }

    /// What is installed and already decided, as bullet lines for a prompt.
    static func knownLines(_ product: Product, installedSkills: [String], installedPlugins: Set<String>) -> [String] {
        var facts = ["- Skills installed on this Mac: " + (installedSkills.isEmpty ? "none" : installedSkills.sorted().joined(separator: ", ")),
                     "- Claude Code plugins installed: " + (installedPlugins.isEmpty ? "none" : installedPlugins.sorted().joined(separator: ", "))]
        let chosen = (product.agentSkills ?? []).filter { !$0.isDismissed }.map(\.id)
        if !chosen.isEmpty { facts.append("- Already chosen for this product: " + chosen.joined(separator: ", ")) }
        let dismissed = (product.agentSkills ?? []).filter(\.isDismissed).map(\.id)
        if !dismissed.isEmpty { facts.append("- Turned down, do not suggest again: " + dismissed.joined(separator: ", ")) }
        return facts
    }

    /// Where to look, how to choose, and the file format. Shared by the Suggest prompt and the new-project plan.
    static func findAndWrite(indent: String) -> String {
        """
        \(indent)Look at skills.sh and GitHub skills repositories (folders with a SKILL.md), \
        `claude plugin list --available --json` (plugins from the marketplaces already added; installCount shows use), and \
        claudemarketplaces.com. Prefer well-maintained ones with real use. An installed skill that fits is a good suggestion: \
        it only has to be chosen. Skip what overlaps another suggestion or what this product does not need. \
        Open each one's repository and read it. Prefer a plain skill (a SKILL.md folder) over a plugin when both exist. \
        For a plugin, note what it adds; hooks and MCP servers run code in every session.
        \(indent)Write `\(relativePath)` in the folder. A skill from a GitHub repository:
        \(indent)  `{"name": "skill-folder-name", "repo": "owner/repo", "why": "one short line on what it does for this product"}`
        \(indent)A Claude Code plugin:
        \(indent)  `{"name": "plugin-name", "plugin": "plugin-name", "marketplace": "owner/repo or \(officialMarketplace)", \
        "why": "…", "includes": ["skills", "hooks"]}`
        \(indent)The whole file: `{"skills": [ … ]}`. Take names from the repository itself (the skill's folder, or the \
        marketplace's `.claude-plugin/marketplace.json`); never guess them.
        """
    }

    /// The skills step of a new project's plan: suggested alongside the blueprint, so they can be chosen before the build.
    public static func planStep(_ product: Product, cli: String, installedSkills: [String], installedPlugins: Set<String>) -> String {
        let tool = cli.contains(" ") ? "\"\(cli)\"" : cli
        return """
        Suggest 3 to 8 agent skills for building and working on this project with the stack you recommend: \
        the framework, its tests, design, deployment, and anything the idea needs. Suggest only; install nothing.
        \(knownLines(product, installedSkills: installedSkills, installedPlugins: installedPlugins).map { "   " + $0 }.joined(separator: "\n"))
        \(findAndWrite(indent: "   "))
           Then run `\(tool) skills check \(product.slug)` and fix every problem it prints.
        """
    }

    /// The prompt that asks the agent for suggestions.
    public static func prompt(for product: Product, checkout: LocalCheckout, cli: String, installedSkills: [String], installedPlugins: Set<String>) -> String {
        let tool = cli.contains(" ") ? "\"\(cli)\"" : cli
        var facts = ["- Product: \(product.name) (`\(product.slug)`)\(product.tagline.isEmpty ? "" : ": \(product.tagline)")",
                     "- Folder: \(checkout.path)"]
        if !product.stack.isEmpty { facts.append("- Stack: " + product.stack.joined(separator: ", ")) }
        let hints = RunSetup.hints(for: checkout)
        if !hints.isEmpty { facts.append("- Files at the top: " + hints.joined(separator: ", ")) }
        facts += knownLines(product, installedSkills: installedSkills, installedPlugins: installedPlugins)
        return """
        Suggest agent skills that would help with \(product.name). Suggest only; install nothing.

        What \(Brand.name) knows:
        \(facts.joined(separator: "\n"))

        1. Work out what this product is and what work happens in it: read the README and the top-level files, and run \
        `git log --oneline -30`. Note the kinds of work: UI and design, WordPress, an API, tests, docs, releases, data, mobile.
        2. Find between 3 and 8 skills that fit that work.
        \(findAndWrite(indent: "   "))
        3. Run `\(tool) skills check \(product.slug)` and fix every problem it prints.
        4. Show me a short table (name, why, skill or plugin), then tell me to open \(product.name) › Development › Skills \
        in \(Brand.name) and press Install or Use on the ones I want. Nothing is installed before that.
        """
    }
}
