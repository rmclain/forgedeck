import Foundation

// Agent skills are folders with a SKILL.md that Claude Code and other agents load on demand.
// ForgeDeck fetches a GitHub repository with a shallow clone, finds the skills in it, and copies
// the ones you pick into each agent's skills folder. Nothing in the repository is run.

/// A GitHub repository of skills, listed in the Toolbox.
public struct SkillRepository: Sendable, Hashable, Identifiable {
    /// owner/repo
    public var id: String
    public var name: String
    public var summary: String
    /// Skill folder names this repository is known to install, used to notice a copy added some other way.
    public var knownSkills: [String]

    public var url: String { "https://github.com/\(id)" }

    public init(id: String, name: String, summary: String, knownSkills: [String]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.knownSkills = knownSkills
    }
}

/// Where a skill is installed.
public enum SkillTarget: String, CaseIterable, Sendable, Codable, Identifiable {
    case claude
    case agents

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .agents: "Shared agents folder"
        }
    }

    public var detail: String {
        switch self {
        case .claude: "~/.claude/skills"
        case .agents: "~/.agents/skills"
        }
    }

    /// Who reads the folder, for hover help.
    public var readers: String {
        switch self {
        case .claude: "Claude Code loads skills from here."
        case .agents: "Codex and other agents that follow the Agent Skills standard load skills from here."
        }
    }

    public func directory(home: URL) -> URL {
        switch self {
        case .claude: home.appending(path: ".claude/skills", directoryHint: .isDirectory)
        case .agents: home.appending(path: ".agents/skills", directoryHint: .isDirectory)
        }
    }

    /// The folder in a repository written for this agent, preferred when a repository has one copy per agent.
    var preferredPrefixes: [String] {
        switch self {
        case .claude: [".claude/skills/"]
        case .agents: [".agents/skills/", ".codex/skills/"]
        }
    }
}

/// One skill found in a fetched repository. A repository may hold the same skill once per agent.
public struct FoundSkill: Sendable, Hashable, Identifiable {
    public var name: String
    public var summary: String
    /// Folders inside the repository that hold this skill, relative to its root.
    public var sources: [String]
    /// Inside a "skills" folder, so it is meant to be installed (not a test fixture or a template).
    public var recommended: Bool

    public var id: String { name }

    public init(name: String, summary: String, sources: [String], recommended: Bool) {
        self.name = name
        self.summary = summary
        self.sources = sources
        self.recommended = recommended
    }

    /// A name from --skill or a /tree/ link: the skill's own name or the folder it is in.
    public func answers(to requested: String) -> Bool {
        name == requested || sources.contains { ($0 as NSString).lastPathComponent == requested }
    }

    /// The best copy for an agent: the one written for it, then a plain skills/ folder, then any other.
    public func source(for target: SkillTarget) -> String {
        func rank(_ path: String) -> Int {
            if target.preferredPrefixes.contains(where: { path.hasPrefix($0) }) { return 0 }
            let first = path.split(separator: "/").first.map(String.init) ?? ""
            if !first.hasPrefix("."), path.split(separator: "/").contains("skills") { return 1 }
            if SkillTarget.allCases.flatMap(\.preferredPrefixes).contains(where: { path.hasPrefix($0) }) { return 2 }
            return 3
        }
        return sources.min { (rank($0), $0.count, $0) < (rank($1), $1.count, $1) } ?? sources[0]
    }
}

/// Written next to SKILL.md in every skill ForgeDeck installs, so it can update or remove only its own.
public struct SkillReceipt: Codable, Sendable, Equatable {
    public var repository: String
    public var commit: String
    public var source: String
    public var installedAt: Date
}

public enum SkillState: Sendable, Equatable {
    /// Nothing with this name yet.
    case new
    /// Installed by ForgeDeck from this repository (or another one).
    case installed(SkillReceipt)
    /// A folder with this name that ForgeDeck did not install. It is never touched.
    case foreign
}

public enum SkillInstallResult: Sendable, Equatable {
    case installed
    case updated
    case keptExisting
}

public enum SkillError: Error, CustomStringConvertible, Equatable {
    case badRepository(String)
    case gitMissing
    case fetchFailed(String)
    case unsafeName(String)
    case unsafeLink(String)
    case notOurs(String)

    public var description: String {
        switch self {
        case .badRepository(let text): "\"\(text)\" is not a GitHub repository. Use owner/repo or a github.com link."
        case .gitMissing: "git is not installed. Install the Xcode Command Line Tools."
        case .fetchFailed(let why): "Could not download the repository: \(why)"
        case .unsafeName(let name): "\"\(name)\" is not a usable skill name."
        case .unsafeLink(let path): "The skill links to a file outside its folder (\(path)), so it was not installed."
        case .notOurs(let name): "\(name) was not installed by ForgeDeck, so it was left alone."
        }
    }
}

public enum AgentSkills {
    public static let receiptName = ".forgedeck-skill.json"

    /// Popular skill repositories. Checked on GitHub when added; star counts change, so none are shown.
    public static let catalog: [SkillRepository] = [
        SkillRepository(id: "anthropics/skills", name: "Anthropic Skills",
                        summary: "Anthropic's public skills: Word, PDF, PowerPoint, and Excel files, frontend design, MCP servers, and writing new skills.",
                        knownSkills: ["skill-creator", "docx", "pdf", "frontend-design"]),
        SkillRepository(id: "pbakaus/impeccable", name: "Impeccable",
                        summary: "A design vocabulary for coding agents: critique, audit, polish, and catching AI-looking interfaces before they ship.",
                        knownSkills: ["impeccable"]),
        SkillRepository(id: "obra/superpowers", name: "Superpowers",
                        summary: "A way of working as skills: brainstorming, writing and executing plans, test-driven development, and parallel agents.",
                        knownSkills: ["brainstorming", "executing-plans"]),
        SkillRepository(id: "vercel-labs/agent-skills", name: "Vercel Agent Skills",
                        summary: "Vercel's skills for React and React Native best practices, component composition, and deploying to Vercel.",
                        knownSkills: ["react-best-practices", "deploy-to-vercel"]),
        SkillRepository(id: "heygen-com/hyperframes", name: "HyperFrames",
                        summary: "Make videos from HTML: compositions, animation, captions, media, and rendering.",
                        knownSkills: ["hyperframes", "hyperframes-cli"]),
        SkillRepository(id: "openai/skills", name: "OpenAI Skills",
                        summary: "OpenAI's curated catalog for Codex: deploy targets, Figma, Playwright, Sentry, Linear, Notion, and security reviews.",
                        knownSkills: ["playwright", "gh-fix-ci"]),
        SkillRepository(id: "trailofbits/skills", name: "Trail of Bits Skills",
                        summary: "Security research, vulnerability detection, and audit workflows from Trail of Bits.",
                        knownSkills: ["audit-context-building"]),
        SkillRepository(id: "huggingface/skills", name: "Hugging Face Skills",
                        summary: "Work with the Hugging Face hub: models, datasets, the hf command line, and cloud setup.",
                        knownSkills: ["hf-cli"]),
    ]

    // MARK: Repository names

    /// "owner/repo" from owner/repo, github.com/owner/repo, or any github.com link into the repository.
    public static func parseRepository(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "git@github.com:", "www."] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        let parts = text.split(separator: "/").map(String.init)
        var candidate: [String]
        if parts.first?.lowercased() == "github.com" {
            candidate = Array(parts.dropFirst().prefix(2))
        } else if parts.count == 2, !parts[0].contains(".") {
            candidate = parts
        } else {
            return nil
        }
        guard candidate.count == 2 else { return nil }
        if candidate[1].hasSuffix(".git") { candidate[1] = String(candidate[1].dropLast(4)) }
        let repository = candidate.joined(separator: "/")
        return UpdateChecker.isValidRepository(repository) ? repository : nil
    }

    // MARK: Fetch

    /// A shallow clone of the default branch: no tags, no LFS files, no prompts. Hooks in a repository never run on clone.
    public static func cloneRequest(_ repository: String, into folder: URL, git: URL) -> ProcessRequest {
        ProcessRequest(executable: git,
                       arguments: ["clone", "--depth", "1", "--single-branch", "--no-tags", "--quiet",
                                   "https://github.com/\(repository).git", folder.path],
                       environment: gitEnvironment(git), timeout: 300, stdin: Data(), maxOutputBytes: 100_000)
    }

    static func gitEnvironment(_ git: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_LFS_SKIP_SMUDGE"] = "1"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["PATH"] = ([git.deletingLastPathComponent().path] + ExecutableLocator.searchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
        return environment
    }

    /// Clones the repository into `folder` (which must not exist yet) and returns the commit it fetched.
    /// A tag, branch, or commit is safe to pass to git when it is plain: letters, digits, dot, dash, slash, underscore.
    public static func isSafeRef(_ ref: String) -> Bool {
        guard let first = ref.first, first != "-", first != "/", ref.count <= 100, !ref.contains("..") else { return false }
        return ref.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "._/-".contains($0) }
    }

    /// Fetches the repository into `folder` (which must not exist yet) and returns the commit it fetched.
    /// With `ref` (a tag, branch, or commit), only that one is fetched; without it, the default branch.
    public static func fetch(_ repository: String, ref: String? = nil, into folder: URL, runner: any ProcessRunning = SystemProcessRunner()) async throws -> String {
        guard UpdateChecker.isValidRepository(repository) else { throw SkillError.badRepository(repository) }
        if let ref, !isSafeRef(ref) { throw SkillError.badRepository("\(repository)@\(ref)") }
        guard let git = ExecutableLocator.find("git") else { throw SkillError.gitMissing }
        let environment = gitEnvironment(git)
        func run(_ arguments: [String], timeout: TimeInterval = 300) async throws {
            let result = try await runner.run(ProcessRequest(executable: git, arguments: arguments, environment: environment,
                                                             timeout: timeout, stdin: Data(), maxOutputBytes: 100_000))
            guard result.ok else {
                let why = result.timedOut ? "it took longer than 5 minutes" : Toolbox.stripANSI(result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SkillError.fetchFailed(why.isEmpty ? "git exited with \(result.exitCode)" : String(why.prefix(300)))
            }
        }
        if let ref {
            // init + fetch one ref works for tags, branches, and commits alike.
            try await run(["init", "--quiet", folder.path], timeout: 20)
            try await run(["-C", folder.path, "fetch", "--depth", "1", "--no-tags", "--quiet", "https://github.com/\(repository).git", ref])
            try await run(["-C", folder.path, "-c", "advice.detachedHead=false", "checkout", "--quiet", "FETCH_HEAD"], timeout: 60)
        } else {
            let clone = try await runner.run(cloneRequest(repository, into: folder, git: git))
            guard clone.ok else {
                let why = clone.timedOut ? "it took longer than 5 minutes" : Toolbox.stripANSI(clone.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SkillError.fetchFailed(why.isEmpty ? "git exited with \(clone.exitCode)" : String(why.prefix(300)))
            }
        }
        let head = try await runner.run(ProcessRequest(executable: git, arguments: ["-C", folder.path, "rev-parse", "HEAD"],
                                                       environment: environment, timeout: 20))
        return head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: npx skills

    /// What to add: a repository, and what an `npx skills add` command asked for.
    public struct Source: Sendable, Equatable {
        public var repository: String
        /// A tag, branch, or commit from owner/repo@ref or a /tree/<ref>/ link.
        public var ref: String?
        /// Skills named with --skill, or the last folder of a /tree/ link. nil: let the person choose.
        public var skills: [String]?
        /// Agents named with -a. nil: the sheet's defaults.
        public var targets: Set<SkillTarget>?
        /// The text was a command, not just a repository.
        public var fromCommand: Bool

        public init(repository: String, ref: String? = nil, skills: [String]? = nil, targets: Set<SkillTarget>? = nil, fromCommand: Bool = false) {
            self.repository = repository
            self.ref = ref
            self.skills = skills
            self.targets = targets
            self.fromCommand = fromCommand
        }
    }

    /// Reads owner/repo, a github.com link, or a pasted `npx skills add …` / `npx skills use …` command.
    /// The command is read, never run: ForgeDeck does the install itself.
    public static func parseSource(_ input: String) -> Source? {
        let words = shellWords(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let first = words.first else { return nil }
        // Runner prefixes: npx, bunx, pnpx, pnpm dlx, yarn dlx; then skills (or skills@version), then add or use.
        var rest = words[...]
        if ["npx", "bunx", "pnpx"].contains(first) {
            rest = rest.dropFirst()
        } else if ["pnpm", "yarn"].contains(first), words.count > 1, words[1] == "dlx" {
            rest = rest.dropFirst(2)
        }
        while let flag = rest.first, flag.hasPrefix("-") { rest = rest.dropFirst() }   // npx -y
        let isCommand = rest.first.map { $0 == "skills" || $0.hasPrefix("skills@") } ?? false
        guard isCommand else {
            // Not a command: a bare repository or link.
            return words.count == 1 ? sourceFromTarget(words[0], fromCommand: false) : nil
        }
        rest = rest.dropFirst()
        guard let verb = rest.first, verb == "add" || verb == "use" || verb == "a" || verb == "install" || verb == "i" else { return nil }
        rest = rest.dropFirst()
        var target: String?
        var skills: [String] = []
        var agents: [String] = []
        var all = false
        var collecting: String?
        for word in rest {
            if word.hasPrefix("-") {
                collecting = nil
                let (flag, value) = word.contains("=") ? (String(word.split(separator: "=", maxSplits: 1)[0]), String(word.split(separator: "=", maxSplits: 1)[1])) : (word, nil)
                switch flag {
                case "-s", "--skill":
                    if let value { skills.append(value) } else { collecting = "skill" }
                case "-a", "--agent":
                    if let value { agents.append(value) } else { collecting = "agent" }
                case "--all": all = true
                default: break   // -g, -y, --copy, --list: ForgeDeck always installs for your user, after you confirm.
                }
                continue
            }
            switch collecting {
            case "skill": skills.append(word)
            case "agent": agents.append(word)
            default: if target == nil { target = word }
            }
        }
        guard let target, var source = sourceFromTarget(target, fromCommand: true) else { return nil }
        // `skills use owner/repo@skill` names a skill, not a ref.
        if verb == "use", let ref = source.ref, isSafeName(ref) {
            source.ref = nil
            source.skills = [ref]
        }
        let named = skills.flatMap { $0.split(separator: ",").map(String.init) }.filter { $0 != "*" }
        if !named.isEmpty { source.skills = named.filter(isSafeName) }
        if all || skills.contains("*") { source.skills = nil }
        if all {
            source.targets = Set(SkillTarget.allCases)
        } else if !agents.isEmpty {
            var targets = Set<SkillTarget>()
            for agent in agents.flatMap({ $0.split(separator: ",") }) {
                let name = String(agent)
                targets.insert(name == "claude-code" || name == "claude" ? .claude : .agents)
            }
            source.targets = targets
        }
        return source
    }

    /// owner/repo, owner/repo@ref, github.com links, and /tree/<ref>/<path>/<skill> links.
    static func sourceFromTarget(_ text: String, fromCommand: Bool) -> Source? {
        var text = text
        var ref: String?
        var skill: String?
        if let range = text.range(of: "/tree/") {
            let tail = text[range.upperBound...].split(separator: "/").map(String.init)
            ref = tail.first
            if tail.count > 1, let last = tail.last { skill = last }
            text = String(text[..<range.lowerBound])
        }
        // owner/repo@ref: an @ after the repository name (not the git@ of an SSH address).
        if let at = text.lastIndex(of: "@") {
            let after = String(text[text.index(after: at)...])
            let atCount = text.filter { $0 == "@" }.count
            let isSSHUser = text.hasPrefix("git@") && atCount == 1
            if !after.contains("/"), !isSSHUser {
                ref = after
                text = String(text[..<at])
            }
        }
        guard let repository = parseRepository(text) else { return nil }
        if let found = ref, !isSafeRef(found) { return nil }
        return Source(repository: repository, ref: ref?.isEmpty == true ? nil : ref,
                      skills: skill.flatMap { isSafeName($0) ? [$0] : nil }, fromCommand: fromCommand)
    }

    /// Splits a command line into words, honoring single and double quotes. Nothing is expanded.
    static func shellWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(character)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    // MARK: Discover

    private static let skippedFolders: Set<String> = [".git", "node_modules", "tests", "test", "__tests__", "fixtures", "examples", "__pycache__", ".venv", "dist-test"]

    /// Every folder with a SKILL.md, grouped by skill name. Test fixtures and dependency folders are skipped.
    public static func discover(in root: URL, maxDepth: Int = 7) -> [FoundSkill] {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return [] }
        var byName: [String: FoundSkill] = [:]
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) || walker.level > maxDepth { walker.skipDescendants() }
                continue
            }
            guard url.lastPathComponent == "SKILL.md", values?.isSymbolicLink != true else { continue }
            let folder = url.deletingLastPathComponent().standardizedFileURL.path
            guard folder.hasPrefix(rootPath + "/") else { continue }
            let relative = String(folder.dropFirst(rootPath.count + 1))
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let front = frontmatter(text)
            let name = front.name.flatMap { isSafeName($0) ? $0 : nil } ?? url.deletingLastPathComponent().lastPathComponent
            guard isSafeName(name) else { continue }
            let recommended = relative.split(separator: "/").contains("skills")
            if var existing = byName[name] {
                existing.sources.append(relative)
                existing.recommended = existing.recommended || recommended
                if existing.summary.isEmpty { existing.summary = front.description ?? "" }
                byName[name] = existing
            } else {
                byName[name] = FoundSkill(name: name, summary: front.description ?? "", sources: [relative], recommended: recommended)
            }
        }
        return byName.values.sorted { ($0.recommended ? 0 : 1, $0.name) < ($1.recommended ? 0 : 1, $1.name) }
    }

    /// name and description from a SKILL.md's YAML front matter. Handles plain, quoted, and folded (> or |) values.
    public static func frontmatter(_ text: String) -> (name: String?, description: String?) {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard raw.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        let end = raw.dropFirst().firstIndex { $0.trimmingCharacters(in: .whitespaces) == "---" } ?? raw.count
        let lines = Array(raw[1..<end])
        func value(_ key: String) -> String? {
            guard let index = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) else { return nil }
            var rest = lines[index].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ">+", "|+"].contains(rest) {
                rest = lines[(index + 1)...].prefix { $0.hasPrefix(" ") || $0.hasPrefix("\t") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            }
            if rest.count >= 2, let quote = rest.first, quote == "\"" || quote == "'", rest.last == quote { rest = String(rest.dropFirst().dropLast()) }
            return rest.isEmpty ? nil : rest
        }
        var description = value("description")
        if let text = description, text.count > 240 { description = String(text.prefix(239)) + "…" }
        return (value("name"), description)
    }

    /// Letters, digits, dot, dash, underscore; not hidden; at most 64 characters. It becomes a folder name.
    public static func isSafeName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber, name.count <= 64 else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "-_.".contains($0) } && !name.contains("..")
    }

    // MARK: Install

    public static func state(of name: String, target: SkillTarget, home: URL) -> SkillState {
        let folder = target.directory(home: home).appending(path: name, directoryHint: .isDirectory)
        guard exists(folder) else { return .new }
        guard !isSymlink(folder), let receipt = receipt(in: folder) else { return .foreign }
        return .installed(receipt)
    }

    public static func receipt(in folder: URL) -> SkillReceipt? {
        guard let data = try? Data(contentsOf: folder.appending(path: receiptName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SkillReceipt.self, from: data)
    }

    /// Copies one skill into an agent's skills folder. A folder ForgeDeck did not install is never replaced.
    /// An older copy ForgeDeck installed goes to `discard` (the Trash in the app) before the new one moves in.
    @discardableResult
    public static func install(_ skill: FoundSkill, from root: URL, repository: String, commit: String, target: SkillTarget, home: URL,
                               now: Date = .now, discard: (URL) throws -> Void = trash) throws -> SkillInstallResult {
        guard isSafeName(skill.name) else { throw SkillError.unsafeName(skill.name) }
        let sourcePath = skill.source(for: target)
        let source = root.appending(path: sourcePath, directoryHint: .isDirectory).standardizedFileURL
        guard source.path.hasPrefix(root.standardizedFileURL.path + "/"), !isSymlink(source) else { throw SkillError.unsafeLink(sourcePath) }
        if let escaping = escapingLink(in: source) { throw SkillError.unsafeLink(escaping) }

        let fm = FileManager.default
        let parent = target.directory(home: home)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appending(path: skill.name, directoryHint: .isDirectory)
        let previous = state(of: skill.name, target: target, home: home)
        if previous == .foreign { return .keptExisting }

        // Copy next to the destination first, so a failed copy never leaves a half-installed skill.
        let staging = parent.appending(path: ".\(skill.name).forgedeck-new", directoryHint: .isDirectory)
        if exists(staging) { try fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SkillReceipt(repository: repository, commit: commit, source: sourcePath, installedAt: now))
            .write(to: staging.appending(path: receiptName))
        if case .installed = previous { try discard(destination) }
        try fm.moveItem(at: staging, to: destination)
        if case .installed = previous { return .updated }
        return .installed
    }

    /// Removes a skill ForgeDeck installed. Anything else is refused.
    public static func remove(_ name: String, target: SkillTarget, home: URL, discard: (URL) throws -> Void = trash) throws {
        guard isSafeName(name) else { throw SkillError.unsafeName(name) }
        guard case .installed = state(of: name, target: target, home: home) else { throw SkillError.notOurs(name) }
        try discard(target.directory(home: home).appending(path: name, directoryHint: .isDirectory))
    }

    /// One installed skill, found by its receipt.
    public struct Installed: Sendable, Equatable, Identifiable {
        public var name: String
        public var target: SkillTarget
        public var receipt: SkillReceipt
        public var id: String { "\(target.rawValue)/\(name)" }
    }

    /// Every skill ForgeDeck installed, in every agent folder.
    public static func installed(home: URL) -> [Installed] {
        SkillTarget.allCases.flatMap { target -> [Installed] in
            let folder = target.directory(home: home)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.sorted().compactMap { name in
                guard isSafeName(name), case .installed(let receipt) = state(of: name, target: target, home: home) else { return nil }
                return Installed(name: name, target: target, receipt: receipt)
            }
        }
    }

    /// Known skills of a repository that are in an agent folder, however they got there.
    public static func present(_ repository: SkillRepository, home: URL) -> [String] {
        repository.knownSkills.filter { name in SkillTarget.allCases.contains { exists($0.directory(home: home).appending(path: name)) } }
    }

    public static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: Files

    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// The first symbolic link inside `folder` that points outside it, as a path relative to the folder.
    static func escapingLink(in folder: URL) -> String? {
        let fm = FileManager.default
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return nil }
        for case let url as URL in walker where isSymlink(url) {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return url.lastPathComponent }
            let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target) : url.deletingLastPathComponent().appending(path: target))
                .standardizedFileURL.resolvingSymlinksInPath().path
            if resolved != base, !resolved.hasPrefix(base + "/") {
                return String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
            }
        }
        return nil
    }
}
