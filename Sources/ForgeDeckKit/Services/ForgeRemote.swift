import Foundation

// Forge Remote: Claude Code's Remote Control server, started by ForgeDeck in a workspace of its own.
// Each session started from the Claude app or claude.ai/code starts there with empty context and a short
// briefing. The forgedeck skill tells it where to find a product and which context the task needs.
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

/// The folder remote sessions start in: a short CLAUDE.md, .claude/settings.json (folder access), and the forgedeck skill.
public struct ForgeRemoteWorkspace: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }
    public init(store: StoreLocation) { folder = store.directory.appending(path: "remote", directoryHint: .isDirectory) }

    public var briefingFile: URL { folder.appending(path: "CLAUDE.md") }
    public var settingsFile: URL { folder.appending(path: ".claude/settings.json") }
    public var skillsFolder: URL { folder.appending(path: ".claude/skills", directoryHint: .isDirectory) }

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
        if try ForgeDeckSkill.install(in: skillsFolder, cli: cli ?? Brand.cliName) { changed = true }
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

    /// The few lines every remote session loads at start. Everything else comes from the forgedeck skill, on demand.
    public static func briefing(portfolio: Portfolio, context: ContextLocation, cli: String?, machine: String) -> String {
        let count = ForgeRemote.products(in: portfolio).count
        return """
        # Forge Session

        A remote Claude Code session on \(cell(machine)), started by \(Brand.name). The person is probably on their phone: keep replies short.

        - Read nothing until the person asks for something. Then use the `\(ForgeDeckSkill.name)` skill to find the product \
        (\(count) on this Mac) and only the context that task needs.
        - One product per session. If the person asks for another, suggest a new session in the Claude app (it starts clean) \
        or `/clear`. If they go on here anyway, treat earlier work as belonging to the other product.
        - Do no project work in this folder. Never deploy, push, publish, or change remote data unless asked in this session.

        """
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
    }
}
