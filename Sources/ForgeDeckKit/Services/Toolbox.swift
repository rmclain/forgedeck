import Foundation

// A small catalog of third-party command-line tools that save AI tokens or help with repositories.
// ForgeDeck detects them, shows how to install them, and runs a few fixed actions against a
// checkout. It never installs anything by itself: an install opens in a terminal, where you see
// and confirm the command. Each action is an argument array; nothing goes through a shell.

public enum ToolCategory: String, CaseIterable, Sendable, Codable {
    case tokens, repoHealth, git, usage

    public var title: String {
        switch self {
        case .tokens: "Save tokens"
        case .repoHealth: "Repository health"
        case .git: "Git"
        case .usage: "AI usage"
        }
    }

    public var blurb: String {
        switch self {
        case .tokens: "Let an agent find code by structure instead of reading whole files."
        case .repoHealth: "Find leaked secrets, vulnerable dependencies, and what a codebase is made of."
        case .git: "Read changes and history more easily."
        case .usage: "See what your AI sessions cost."
        }
    }
}

public enum InstallMethod: String, Sendable, Codable {
    case brew, npx, pipx, uv

    public var title: String {
        switch self {
        case .brew: "Homebrew"
        case .npx: "npx"
        case .pipx: "pipx"
        case .uv: "uv"
        }
    }
}

public struct InstallOption: Sendable, Hashable {
    public var method: InstallMethod
    /// Program name first, resolved on this Mac before it runs.
    public var command: [String]
}

public struct ToolAction: Sendable, Hashable, Identifiable {
    public enum Scope: String, Sendable { case checkout, global }
    public var id: String
    public var label: String
    /// `{path}` is replaced by the checkout path, as one whole argument.
    public var arguments: [String]
    /// The program to run. nil runs the tool itself (or npx for an npx tool).
    public var program: String?
    public var scope: Scope = .checkout
    public var safety: ActionSafety = .readOnly
    public var note = ""
    /// The action needs this file inside the checkout, like graphify-out/graph.json.
    public var requiresFile: String?
}

public struct ToolSpec: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var category: ToolCategory
    public var summary: String
    /// How it saves tokens or time. One sentence.
    public var why: String
    public var homepage: String
    /// The binary to look for. nil for tools that run only through npx.
    public var executable: String?
    /// For npx tools: the package, pinned.
    public var npxPackage: String?
    public var install: [InstallOption]
    public var actions: [ToolAction]
    /// A one-line hint an AI agent can use, put into CONTEXT.md when the tool is installed.
    public var agentHint: String?

    public static func == (a: ToolSpec, b: ToolSpec) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum Toolbox {
    public static let catalog: [ToolSpec] = [
        ToolSpec(id: "repomix", name: "Repomix", category: .tokens,
                 summary: "Packs a repository into one AI-friendly file. --compress keeps signatures and drops bodies.",
                 why: "ForgeDeck builds its repo maps from it. The token tree shows which folders eat the budget.",
                 homepage: "https://github.com/yamadashy/repomix", executable: nil, npxPackage: "repomix@\(PackBuilder.repomixVersion)",
                 install: [InstallOption(method: .brew, command: ["brew", "install", "repomix"])],
                 actions: [ToolAction(id: "repomix-tree", label: "Token count by folder",
                                      arguments: ["--compress", "--no-file-summary", "--output", "/dev/null", "--token-count-tree", "1000"],
                                      note: "Shows folders over 1,000 tokens after compression. Writes nothing.")]),
        ToolSpec(id: "graphify", name: "graphify", category: .tokens,
                 summary: "Turns a folder into a knowledge graph an agent can query instead of reading files.",
                 why: "A graph query answers \"what touches X\" in a few hundred tokens.",
                 homepage: "https://github.com/Graphify-Labs/graphify", executable: "graphify", npxPackage: nil,
                 install: [InstallOption(method: .uv, command: ["uv", "tool", "install", "graphifyy"]),
                           InstallOption(method: .pipx, command: ["pipx", "install", "graphifyy"])],
                 actions: [ToolAction(id: "graphify-hubs", label: "Most connected nodes", arguments: ["god-nodes", "--graph", "{path}/graphify-out/graph.json"],
                                      note: "Reads the existing graph.", requiresFile: "graphify-out/graph.json"),
                           ToolAction(id: "graphify-update", label: "Update the graph (code only)", arguments: ["update", "{path}"], safety: .localWrite,
                                      note: "Re-extracts changed code files without a model. Writes graphify-out/ in the repository.",
                                      requiresFile: "graphify-out/graph.json")],
                 agentHint: "`graphify query \"<question>\"` answers questions from graphify-out/graph.json where one exists."),
        ToolSpec(id: "ast-grep", name: "ast-grep", category: .tokens,
                 summary: "Searches and rewrites code by syntax tree patterns.",
                 why: "An agent finds every call of a function by structure, with no false matches, instead of reading files.",
                 homepage: "https://ast-grep.github.io", executable: "ast-grep", npxPackage: nil,
                 install: [InstallOption(method: .brew, command: ["brew", "install", "ast-grep"])],
                 actions: [],
                 agentHint: "`ast-grep run -p '<pattern>' -l <language>` finds code by structure."),
        ToolSpec(id: "ripgrep", name: "ripgrep", category: .tokens,
                 summary: "Fast text search that respects .gitignore.",
                 why: "Claude Code already uses it. Installed system-wide it is also available to Codex and scripts.",
                 homepage: "https://github.com/BurntSushi/ripgrep", executable: "rg", npxPackage: nil,
                 install: [InstallOption(method: .brew, command: ["brew", "install", "ripgrep"])],
                 actions: [ToolAction(id: "rg-todo", label: "List TODO and FIXME", arguments: ["--no-heading", "--line-number", "--max-count", "200", "-e", "TODO", "-e", "FIXME", "{path}"],
                                      note: "Read-only.")],
                 agentHint: "`rg` is installed for fast text search."),
        ToolSpec(id: "gitleaks", name: "Gitleaks", category: .repoHealth,
                 summary: "Finds secrets committed anywhere in a repository's history.",
                 why: "Catches a leaked key before it reaches GitHub or an AI context pack.",
                 homepage: "https://github.com/gitleaks/gitleaks", executable: "gitleaks", npxPackage: nil,
                 install: [InstallOption(method: .brew, command: ["brew", "install", "gitleaks"])],
                 actions: [ToolAction(id: "gitleaks-git", label: "Scan history for secrets", arguments: ["git", "--no-banner", "--redact", "--verbose", "{path}"],
                                      note: "Findings are redacted. Exit code 1 means it found something."),
                           ToolAction(id: "gitleaks-dir", label: "Scan the working folder", arguments: ["dir", "--no-banner", "--redact", "--verbose", "{path}"],
                                      note: "Includes uncommitted files. Findings are redacted.")]),
        ToolSpec(id: "osv-scanner", name: "OSV-Scanner", category: .repoHealth,
                 summary: "Checks lockfiles against the OSV vulnerability database.",
                 why: "One command across npm, PyPI, Composer, Go, Cargo, and more.",
                 homepage: "https://github.com/google/osv-scanner", executable: "osv-scanner", npxPackage: nil,
                 install: [InstallOption(method: .brew, command: ["brew", "install", "osv-scanner"])],
                 actions: [ToolAction(id: "osv-scan", label: "Scan dependencies", arguments: ["scan", "source", "-r", "{path}"],
                                      note: "Sends package names and versions to osv.dev. No source code leaves the Mac.")]),
        ToolSpec(id: "scc", name: "scc", category: .repoHealth,
                 summary: "Counts lines, code, comments, and complexity by language.",
                 why: "A quick answer to \"how big is this, and in what\" before asking an agent about it.",
                 homepage: "https://github.com/boyter/scc", executable: "scc", npxPackage: nil,
                 install: [InstallOption(method: .brew, command: ["brew", "install", "scc"])],
                 actions: [ToolAction(id: "scc-count", label: "Count code", arguments: ["--no-cocomo", "{path}"], note: "Read-only.")]),
        ToolSpec(id: "difftastic", name: "difftastic", category: .git,
                 summary: "A diff that understands syntax: moved code and reformatting stop looking like changes.",
                 why: "Smaller, clearer diffs to read or paste into a review.",
                 homepage: "https://github.com/Wilfred/difftastic", executable: "difft", npxPackage: nil,
                 install: [InstallOption(method: .brew, command: ["brew", "install", "difftastic"])],
                 actions: [ToolAction(id: "difft-diff", label: "Show uncommitted changes", arguments: ["-C", "{path}", "-c", "diff.external=difft", "diff", "--ext-diff"],
                                      program: "git", note: "Read-only. Uses difftastic for this one command only.")]),
        ToolSpec(id: "git-cliff", name: "git-cliff", category: .git,
                 summary: "Writes a changelog from commit messages.",
                 why: "Release notes without asking an agent to read the history.",
                 homepage: "https://git-cliff.org", executable: "git-cliff", npxPackage: nil,
                 install: [InstallOption(method: .brew, command: ["brew", "install", "git-cliff"])],
                 actions: [ToolAction(id: "cliff-unreleased", label: "Draft notes since the last tag", arguments: ["--workdir", "{path}", "--unreleased"],
                                      note: "Prints to the log. Writes nothing.")]),
        ToolSpec(id: "ccusage", name: "ccusage", category: .usage,
                 summary: "Reports Claude Code token use and cost from the logs on this Mac.",
                 why: "Measure whether a context change actually saved tokens.",
                 homepage: "https://github.com/ryoppippi/ccusage", executable: nil, npxPackage: "ccusage@20.0.51",
                 install: [],
                 actions: [ToolAction(id: "ccusage-daily", label: "Usage by day", arguments: ["daily"], scope: .global,
                                      note: "Reads ~/.claude locally. Nothing is uploaded."),
                           ToolAction(id: "ccusage-blocks", label: "Current 5-hour block", arguments: ["blocks", "--active"], scope: .global,
                                      note: "Reads ~/.claude locally.")]),
        ToolSpec(id: "serena", name: "Serena", category: .tokens,
                 summary: "An MCP server with language-server tools: find a symbol, find its references, edit by symbol.",
                 why: "Best for deep work inside one large repository. Set it up from its Quick Start.",
                 homepage: "https://github.com/oraios/serena", executable: nil, npxPackage: nil,
                 install: [], actions: []),
    ]

    public static func spec(_ id: String) -> ToolSpec? { catalog.first { $0.id == id } }

    public enum Status: Sendable, Equatable {
        case installed(path: String)
        /// Runs through npx on demand. The first run downloads the pinned package.
        case onDemand
        case missing
        /// Set up outside ForgeDeck (an MCP server).
        case external

        public var isUsable: Bool {
            switch self {
            case .installed, .onDemand: true
            case .missing, .external: false
            }
        }
    }

    public static func status(_ spec: ToolSpec, environment: [String: String] = [:]) -> Status {
        if let executable = spec.executable {
            return ExecutableLocator.find(executable, environment: environment).map { .installed(path: $0.path) } ?? .missing
        }
        if spec.npxPackage != nil {
            if spec.id == "repomix", let path = ExecutableLocator.find("repomix", environment: environment) { return .installed(path: path.path) }
            return ExecutableLocator.find("npx", environment: environment) == nil ? .missing : .onDemand
        }
        return .external
    }

    /// The install option that can run on this Mac, with its program resolved.
    public static func installCommand(_ spec: ToolSpec) -> [String]? {
        for option in spec.install {
            guard let program = option.command.first, let url = ExecutableLocator.find(program) else { continue }
            return [url.path] + option.command.dropFirst()
        }
        return nil
    }

    public enum Unavailable: Error, CustomStringConvertible, Equatable {
        case notInstalled(String)
        case needsFile(String)
        case noCheckout

        public var description: String {
            switch self {
            case .notInstalled(let name): "\(name) is not installed."
            case .needsFile(let file): "This needs \(file) in the checkout."
            case .noCheckout: "This action runs in a checkout."
            }
        }
    }

    /// The program and arguments for an action. Placeholders become whole arguments.
    public static func command(_ action: ToolAction, of spec: ToolSpec, checkout: String?) throws -> (URL, [String], URL?) {
        if action.scope == .checkout {
            guard let checkout else { throw Unavailable.noCheckout }
            if let file = action.requiresFile, !FileManager.default.fileExists(atPath: (checkout as NSString).appendingPathComponent(file)) {
                throw Unavailable.needsFile(file)
            }
        }
        let arguments = action.arguments.map { argument in
            checkout.map { argument.replacingOccurrences(of: "{path}", with: $0) } ?? argument
        }
        let directory = checkout.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let program = action.program {
            guard spec.executable.flatMap({ ExecutableLocator.find($0) }) != nil else { throw Unavailable.notInstalled(spec.name) }
            guard let url = ExecutableLocator.find(program) else { throw Unavailable.notInstalled(program) }
            return (url, arguments, directory)
        }
        if let executable = spec.executable {
            guard let url = ExecutableLocator.find(executable) else { throw Unavailable.notInstalled(spec.name) }
            return (url, arguments, directory)
        }
        if spec.id == "repomix", let url = ExecutableLocator.find("repomix") { return (url, arguments, directory) }
        if let package = spec.npxPackage {
            guard let npx = ExecutableLocator.find("npx") else { throw Unavailable.notInstalled("npx (Node.js)") }
            return (npx, ["--yes", package] + arguments, directory)
        }
        throw Unavailable.notInstalled(spec.name)
    }

    /// Runs an action and returns its redacted output. Terminal colors are removed.
    public static func run(_ action: ToolAction, of spec: ToolSpec, checkout: String?, runner: any ProcessRunning = SystemProcessRunner(),
                           timeout: TimeInterval = 180) async throws -> ProcessResult {
        let (program, arguments, directory) = try command(action, of: spec, checkout: checkout)
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["GIT_PAGER"] = "cat"
        environment["PATH"] = ([program.deletingLastPathComponent().path] + ExecutableLocator.searchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
        var result = try await runner.run(ProcessRequest(executable: program, arguments: arguments, workingDirectory: directory,
                                                         environment: environment, timeout: timeout, maxOutputBytes: 400_000))
        let redactor = Redactor()
        result.stdout = redactor.redact(stripANSI(result.stdout))
        result.stderr = redactor.redact(stripANSI(result.stderr))
        return result
    }

    private static let ansi = try! NSRegularExpression(pattern: #"\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07]*\x07"#)

    public static func stripANSI(_ text: String) -> String {
        ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Installed tools an agent can use, for CONTEXT.md.
    public static func agentHints() -> [String] {
        catalog.compactMap { spec in
            guard let hint = spec.agentHint, case .installed = status(spec) else { return nil }
            return hint
        }
    }
}
