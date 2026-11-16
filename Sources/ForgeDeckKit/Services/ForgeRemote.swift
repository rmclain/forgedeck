import Foundation

// Forge Remote: Claude Code's Remote Control server, started by ForgeDeck in a workspace of its own.
// Each session started from the Claude app or claude.ai/code starts there with empty context, reads
// the Forge Session briefing (every product, its folders, and its context file), and works on one product.
// Nothing here talks to the network: the agent does, under the person's own Claude account.

public struct ForgeRemoteSettings: Codable, Hashable, Sendable {
    /// Permission modes offered in Settings. Modes that skip every question are left out on purpose.
    public enum Mode: String, CaseIterable, Sendable {
        case ask = "default", acceptEdits, plan, auto

        public var title: String {
            switch self {
            case .ask: "Ask before every change"
            case .acceptEdits: "Edit files without asking"
            case .plan: "Plan only, change nothing"
            case .auto: "Auto (Claude decides what is safe)"
            }
        }
    }

    public var enabled = false
    /// The name of the first session, shown in the Claude app.
    public var name = "Forge Session"
    public var permissionMode = Mode.ask.rawValue
    /// Hold off idle sleep while the server runs. Closing the lid still sleeps the Mac.
    public var keepAwake = true

    public init() {}

    public var mode: Mode { Mode(rawValue: permissionMode) ?? .ask }

    enum CodingKeys: String, CodingKey { case enabled, name, permissionMode, keepAwake }

    /// Every key is optional, so settings written by an older or newer build still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Forge Session"
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode) ?? Mode.ask.rawValue
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
    }
}

public enum ForgeRemote {
    /// The agent that has a Remote Control server. Other agents have no equivalent to start.
    public static let program = "claude"
    public static let namePrefix = "Forge"

    public static func supports(_ program: String) -> Bool { program == Self.program }

    /// The products a remote session may work on: real, not archived, with a folder on this Mac.
    public static func products(in portfolio: Portfolio) -> [Product] {
        portfolio.products.filter { !$0.isDemo && $0.lifecycle != .archived && $0.hasLocal }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The session name, trimmed to something the app shows well.
    public static func sessionName(_ settings: ForgeRemoteSettings) -> String {
        let trimmed = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = String(trimmed.filter { !$0.isNewline && $0 != "\0" }.prefix(60))
        return clean.isEmpty ? "Forge Session" : clean
    }

    /// `claude remote-control …`: a server whose sessions all start in the workspace. An argument array, no shell.
    public static func command(program: URL, settings: ForgeRemoteSettings) -> [String] {
        [program.path, "remote-control",
         "--name", sessionName(settings),
         "--remote-control-session-name-prefix", namePrefix,
         "--permission-mode", settings.mode.rawValue,
         "--spawn", "same-dir"]
    }
}

/// The folder remote sessions start in: CLAUDE.md (the briefing) and .claude/settings.json (folder access).
public struct ForgeRemoteWorkspace: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }
    public init(store: StoreLocation) { folder = store.directory.appending(path: "remote", directoryHint: .isDirectory) }

    public var briefingFile: URL { folder.appending(path: "CLAUDE.md") }
    public var settingsFile: URL { folder.appending(path: ".claude/settings.json") }

    /// Writes both files. Returns true when either changed, so a caller can tell the person.
    @discardableResult
    public func write(portfolio: Portfolio, context: ContextLocation, cli: String?, machine: String = Host.current().localizedName ?? "this Mac",
                      now: Date = .now) throws -> Bool {
        try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let briefing = Self.briefing(portfolio: portfolio, context: context, cli: cli, machine: machine)
        let settings = try Self.settings(portfolio: portfolio, context: context)
        var changed = false
        for (url, data) in [(briefingFile, Data(briefing.utf8)), (settingsFile, settings)] where (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
            changed = true
        }
        return changed
    }

    /// Claude Code project settings: every product folder and the context folder become working directories.
    public static func settings(portfolio: Portfolio, context: ContextLocation) throws -> Data {
        var folders = ForgeRemote.products(in: portfolio).flatMap { $0.checkouts.map(\.path) }
        folders.append(context.root.path)
        var seen = Set<String>()
        let unique = folders.filter { !$0.isEmpty && seen.insert($0).inserted }
        let object: [String: Any] = ["permissions": ["additionalDirectories": unique]]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    /// The briefing every remote session reads first. Names, folders, and rules: no secrets.
    public static func briefing(portfolio: Portfolio, context: ContextLocation, cli: String?, machine: String) -> String {
        let products = ForgeRemote.products(in: portfolio)
        let tool = cli ?? Brand.cliName
        var rows = products.map { product -> String in
            let folders = product.checkouts.map { "`\($0.path)`" }.joined(separator: ", ")
            let about = product.tagline.isEmpty ? product.stack.prefix(4).joined(separator: ", ") : product.tagline
            return "| \(cell(product.name)) | `\(product.slug)` | \(cell(product.group)) | \(folders) | `\(context.contextFile(product).path)` | \(cell(about)) |"
        }
        if rows.isEmpty { rows = ["| (none yet) | | | | | Add a product with a local folder in \(Brand.name). |"] }
        return """
        # Forge Session

        You are a remote Claude Code session on \(cell(machine)), started by \(Brand.name). The person is probably on their phone or \
        on claude.ai/code, not at this Mac. Keep replies short and say plainly what you changed.

        You can work on any product below. This folder is only a starting point: do no project work here.

        ## Start of every session

        1. If the person has not named a product, list the products below by name and ask which one.
        2. Read that product's context file before anything else. It holds its folders, environments, related products, and variable names.
        3. `cd` into its folder and work there. When a product has more than one folder, ask which one unless the request makes it clear.

        ## One product per session

        A session works on one product. When the person asks for a different product:

        - Say that this session still holds the earlier product's context, and suggest starting a new session in the Claude app. \
        Every new session starts here with empty context. `/clear` does the same in this session.
        - If they want to go on here anyway, read the new product's context file, `cd` into its folder, and treat everything \
        earlier in this session as belonging to the other product. Do not carry file names, commands, or assumptions across.
        - Never edit two products in one task unless the person asks for exactly that.

        ## Rules

        - Read-only by default for anything outside the product's folder. Never deploy, push to a shared branch, publish a release, \
        change DNS, or change remote or production data unless the person asks for that in this session.
        - Commit only when asked. No force pushes, no `git reset --hard`, no deleting branches.
        - Secrets stay in the macOS Keychain. Use `\(tool) exec` as the product's context file describes. Never print a value. \
        Production values need Touch ID at this Mac, which the person cannot give from a phone: say so and stop.
        - `\(tool) list` and `\(tool) status <slug> --json` show current state.

        ## Products

        | Product | Slug | Group | Folder | Context file | About |
        |---|---|---|---|---|---|
        \(rows.joined(separator: "\n"))

        \(Brand.name) rewrites this file when products change. Edits to it are lost.

        """
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
    }
}
