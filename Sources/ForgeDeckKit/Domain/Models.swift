import Foundation

// The portfolio registry. Everything here is a definition the user made or approved.
// Observed facts (Git state, remote heads, deployments, health, metrics) live in
// ObservationCache, so clearing the cache never deletes a product definition.
//
// Secrets never appear in these types. A secret is a CredentialReference that points
// at a Keychain item or an external secret manager.

public enum Brand {
    /// The one place the product name is defined.
    public static let name = "ForgeDeck"
    public static let cliName = "forgedeck"
    public static let bundleID = "com.forgedeck.app"
    public static let keychainService = "com.forgedeck.vault"
}

public enum Lifecycle: String, Codable, CaseIterable, Sendable {
    case idea, active, maintenance, archived

    public var title: String {
        switch self {
        case .idea: "Idea"
        case .active: "Active"
        case .maintenance: "Maintenance"
        case .archived: "Archived"
        }
    }
}

public enum EnvironmentTier: String, Codable, CaseIterable, Sendable {
    case development, staging, production, preview, custom

    public var title: String {
        switch self {
        case .development: "Local"
        case .staging: "Staging"
        case .production: "Production"
        case .preview: "Preview"
        case .custom: "Custom"
        }
    }

    public var isProduction: Bool { self == .production }
}

public enum ComponentKind: String, Codable, CaseIterable, Sendable {
    case backend, frontend, site, plugin, mobile, worker, infrastructure, database, cli, other

    public var title: String {
        switch self {
        case .backend: "Backend"
        case .frontend: "Frontend"
        case .site: "Site"
        case .plugin: "Plugin"
        case .mobile: "Mobile app"
        case .worker: "Worker"
        case .infrastructure: "Infrastructure"
        case .database: "Database"
        case .cli: "CLI"
        case .other: "Other"
        }
    }
}

public struct Organization: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name = "My Portfolio"
    public var tags: [String] = []
    public init() {}
    public init(name: String) { self.name = name }
}

public struct ProductLink: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case site, dashboard, admin, runbook, repository, other }
    public var id = UUID()
    public var label = ""
    public var url = ""
    public var kind: Kind = .site
    public init() {}
    public init(label: String, url: String, kind: Kind) { self.label = label; self.url = url; self.kind = kind }
}

public struct Component: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name = ""
    public var kind: ComponentKind = .other
    public var stack: [String] = []
    public init() {}
    public init(name: String, kind: ComponentKind, stack: [String] = []) { self.name = name; self.kind = kind; self.stack = stack }
}

public struct Repository: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var provider = "github"
    public var owner = ""
    public var name = ""
    public var defaultBranch = "main"
    public var webURL = ""
    public var cloneURL = ""
    public var componentID: UUID?
    public init() {}

    public var fullName: String { owner.isEmpty ? name : "\(owner)/\(name)" }
}

/// What discovery read from nonsecret project files.
public struct DetectedMetadata: Codable, Hashable, Sendable {
    public var stack: [String] = []
    public var startCommand: [String] = []
    public var testCommand: [String] = []
    public var devURL: String?
    public var composeServices: [String] = []
    public var hasDockerfile = false
    public var wordpressPluginName: String?
    public var suggestedKind: ComponentKind = .other
    public init() {}
}

public struct LocalCheckout: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name = ""
    /// Last known absolute path. The bookmark is the recovery mechanism when a folder moves.
    public var path = ""
    public var bookmark: Data?
    public var repositoryID: UUID?
    public var componentID: UUID?
    public var isGitRepository = true
    public var isWorktree = false
    public var mainWorktreePath: String?
    public var detected = DetectedMetadata()
    public var addedAt = Date.now
    public init() {}
}

/// A read-only HTTP check against one environment. `.companion` parses the
/// ForgeDeck status contract and yields a runtime-verified release. `.release` reads a version
/// file or header the site serves publicly (forgedeck-release.json, X-Release), with no companion.
public struct ProbeConfig: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case health, companion, release

        /// The check reports which release is running, not only that the URL answers.
        public var reportsRelease: Bool { self != .health }
    }
    public var id = UUID()
    public var name = ""
    public var kind: Kind = .health
    public var url = ""
    public var componentID: UUID?
    /// Key of a variable whose value is sent as a bearer token. Never the value itself.
    public var bearerVariableKey: String?
    public var expectedStatus = 200
    public var timeoutSeconds = 8.0
    /// When set, a companion that reports another product id is rejected.
    public var expectedProductID: String?
    public init() {}
}

public struct SSHHostConfig: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    /// A Host alias from the user's own ~/.ssh/config. Keys stay with the SSH agent.
    public var alias = ""
    public var label = ""
    /// The probes shown by default for this host. Every probe comes from the fixed SSHProbeCommand.catalog.
    public var allowedProbeIDs: [String] = ["uptime"]
    /// Optional release file the host writes during deploy, read with `cat`.
    public var releaseFilePath: String?
    public var componentID: UUID?
    public init() {}
}

public struct MetricSource: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case companion, genericREST }
    public var id = UUID()
    public var name = ""
    public var kind: Kind = .companion
    /// Base URL. The adapter appends the versioned contract paths.
    public var baseURL = ""
    public var bearerVariableKey: String?
    public var leadsEnabled = true
    public var eventsEnabled = true
    public init() {}
}

public struct ProductEnvironment: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name = ""
    public var tier: EnvironmentTier = .development
    public var domains: [String] = []
    public var probes: [ProbeConfig] = []
    public var sshHosts: [SSHHostConfig] = []
    public var metricSources: [MetricSource] = []
    /// GitHub deployment environment name to read reported deployments from.
    public var githubEnvironmentName: String?
    public var dockerComposeProject: String?
    public init() {}
    public init(name: String, tier: EnvironmentTier) { self.name = name; self.tier = tier }
}

public enum ActionSafety: String, Codable, CaseIterable, Sendable, Comparable {
    case readOnly, localWrite, remoteWrite, productionCritical

    public var title: String {
        switch self {
        case .readOnly: "Read-only"
        case .localWrite: "Local write"
        case .remoteWrite: "Remote write"
        case .productionCritical: "Production critical"
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public struct ActionRecipe: Codable, Identifiable, Hashable, Sendable {
    public enum Executor: String, Codable, CaseIterable, Sendable { case local, ssh, openURL }
    public var id = UUID()
    public var label = ""
    public var executor: Executor = .local
    /// For `.local`: the program. For `.ssh`: an SSHProbeCommand id. For `.openURL`: unused.
    public var executable = ""
    public var arguments: [String] = []
    public var url: String?
    public var sshAlias: String?
    public var checkoutID: UUID?
    public var workingSubdirectory = ""
    public var environmentID: UUID?
    /// Variable keys the recipe may receive. Resolution still applies every scope rule.
    public var variableKeys: [String] = []
    public var safety: ActionSafety = .readOnly
    public var timeoutSeconds = 600.0
    /// Detected recipes start unapproved. Only approved recipes run.
    public var isApproved = false
    public var isSuggested = false
    public var opensInTerminal = false
    /// More commands after the first, run in order. The recipe stops at the first that fails.
    /// Optional so files written before steps existed still load.
    public var extraSteps: [[String]]?
    public init() {}

    /// Every command the recipe runs, first to last.
    public var steps: [[String]] { [[executable] + arguments] + (extraSteps ?? []) }

    public mutating func setSteps(_ steps: [[String]]) {
        guard let first = steps.first, let program = first.first else { return }
        executable = program
        arguments = Array(first.dropFirst())
        let rest = Array(steps.dropFirst()).filter { !$0.isEmpty }
        extraSteps = rest.isEmpty ? nil : rest
    }
}

public struct TerminalProfile: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name = ""
    public var terminalBundleID: String?
    public var checkoutID: UUID?
    public var workingSubdirectory = ""
    public var environmentID: UUID?
    /// Variable keys this profile may receive through `forgedeck exec`.
    public var variableAllowlist: [String] = []
    /// Program names `forgedeck exec` may start with this profile. Empty means none.
    public var allowedExecutables: [String] = []
    public init() {}
}

/// Another product whose code an AI agent should know about when it works on this one.
public struct ContextLink: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var productID = UUID()
    /// Also point the agent at a compressed pack of that product's code, when one is built.
    public var includePack = false
    public var note = ""
    public init() {}
    public init(productID: UUID, includePack: Bool = false, note: String = "") {
        self.productID = productID
        self.includePack = includePack
        self.note = note
    }
}

public struct Product: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var slug = ""
    public var name = ""
    public var tagline = ""
    public var notes = ""
    public var group = "Products"
    public var organizationID: UUID?
    public var tags: [String] = []
    public var stack: [String] = []
    public var links: [ProductLink] = []
    public var isFavorite = false
    public var lifecycle: Lifecycle = .active
    /// Hue in degrees for the generated icon gradient.
    public var hue = 180.0
    public var monogram = ""
    public var createdAt = Date.now
    public var lastOpenedAt: Date?
    /// True for sample products from checked-in fixtures. Shown as Demo everywhere.
    public var isDemo = false
    public var components: [Component] = []
    public var repositories: [Repository] = []
    public var checkouts: [LocalCheckout] = []
    public var environments: [ProductEnvironment] = []
    public var recipes: [ActionRecipe] = []
    public var profiles: [TerminalProfile] = []
    /// Related products an agent gets context for when it starts in this product.
    public var contextLinks: [ContextLink] = []
    /// Symlinks from this product's checkouts into folders that load them, like a local WordPress site.
    public var installLinks: [InstallLink] = []
    /// Registries this product publishes to (WordPress.org, npm, PyPI). Optional so older files load.
    public var releaseChannels: [ReleaseChannel]?

    public init() {}

    public init(name: String, group: String = "Products") {
        self.name = name
        self.group = group
        slug = Slug.make(name)
        monogram = Monogram.make(name)
        hue = Monogram.hue(name)
    }

    public var isArchived: Bool { lifecycle == .archived }
    public func environment(tier: EnvironmentTier) -> ProductEnvironment? { environments.first { $0.tier == tier } }
    public func environment(id: UUID?) -> ProductEnvironment? { environments.first { $0.id == id } }
    public func component(id: UUID?) -> Component? { components.first { $0.id == id } }
    public func checkout(id: UUID?) -> LocalCheckout? { checkouts.first { $0.id == id } }
    public func repository(id: UUID?) -> Repository? { repositories.first { $0.id == id } }
    public var primaryCheckout: LocalCheckout? { checkouts.first }
    public var hasLocal: Bool { !checkouts.isEmpty }
    public var hasRemote: Bool { !repositories.isEmpty }
    public var hasProduction: Bool { environment(tier: .production) != nil }
}

public enum Slug {
    public static func make(_ text: String) -> String {
        let lowered = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var out = ""
        var lastDash = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "product" : out
    }

    /// A slug no other product uses.
    public static func unique(_ text: String, taken: Set<String>) -> String {
        let base = make(text)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

public enum Monogram {
    public static func make(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return String(a).uppercased() + String(b).lowercased()
        }
        let letters = Array(name.filter { $0.isLetter || $0.isNumber }.prefix(2))
        guard let first = letters.first else { return "•" }
        return String(first).uppercased() + (letters.count > 1 ? String(letters[1]).lowercased() : "")
    }

    /// A stable hue from the name, so an icon keeps its color across launches.
    public static func hue(_ name: String) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Double(hash % 360)
    }
}

// MARK: Connections and variables

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case github, http, ssh, docker, companion, genericMetrics

    public var title: String {
        switch self {
        case .github: "GitHub"
        case .http: "HTTP health"
        case .ssh: "SSH"
        case .docker: "Docker"
        case .companion: "ForgeDeck Companion"
        case .genericMetrics: "REST metrics"
        }
    }
}

public enum SecretOrigin: String, Codable, CaseIterable, Sendable {
    case keychain, onePassword, environmentReference, sshAgent

    public var title: String {
        switch self {
        case .keychain: "Keychain"
        case .onePassword: "1Password CLI"
        case .environmentReference: "Environment reference"
        case .sshAgent: "SSH agent"
        }
    }
}

/// Points at a secret. Holds no secret bytes.
public struct CredentialReference: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var origin: SecretOrigin = .keychain
    /// Keychain account, `op://` reference, or environment variable name.
    public var locator = ""
    public var createdAt = Date.now
    public var rotatedAt: Date?
    public var expiresAt: Date?
    public var rotationIntervalDays: Int?
    public init() {}

    public static func keychain() -> CredentialReference {
        var ref = CredentialReference()
        ref.locator = ref.id.uuidString
        return ref
    }

    public func rotationDue(now: Date = .now) -> Date? {
        guard let days = rotationIntervalDays else { return nil }
        return (rotatedAt ?? createdAt).addingTimeInterval(Double(days) * 86_400)
    }

    public func isExpired(now: Date = .now) -> Bool { expiresAt.map { $0 <= now } ?? false }
}

public struct Connection: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var provider: ProviderKind = .github
    public var displayName = ""
    public var accountIdentity = ""
    public var baseURL = ""
    public var scopes: [String] = []
    public var credential: CredentialReference?
    public var createdAt = Date.now
    public init() {}
}

public enum VariableScope: Codable, Hashable, Sendable {
    case global
    case organization(UUID)
    case product(UUID)
    case component(product: UUID, component: UUID)
    case environment(product: UUID, environment: UUID)
    case profile(product: UUID, profile: UUID)

    /// Higher wins. Global defaults < Organization < Product < Component < Environment < Profile.
    public var precedence: Int {
        switch self {
        case .global: 0
        case .organization: 1
        case .product: 2
        case .component: 3
        case .environment: 4
        case .profile: 5
        }
    }

    public var title: String {
        switch self {
        case .global: "Global"
        case .organization: "Organization"
        case .product: "Product"
        case .component: "Component"
        case .environment: "Environment"
        case .profile: "Profile"
        }
    }

    public var productID: UUID? {
        switch self {
        case .global, .organization: nil
        case .product(let id): id
        case .component(let id, _), .environment(let id, _), .profile(let id, _): id
        }
    }
}

public struct VariableDefinition: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var key = ""
    public var scope: VariableScope = .global
    public var isSecret = false
    /// Only for nonsecret variables.
    public var plainValue: String?
    public var credential: CredentialReference?
    /// Tiers this value may resolve into. A production secret lists only `.production`,
    /// so it can never reach a development session by inheritance.
    public var allowedTiers: [EnvironmentTier] = [.development]
    public var isRequired = false
    public var note = ""
    public var updatedAt = Date.now
    public init() {}
}

// MARK: Settings

public struct AppSettings: Codable, Hashable, Sendable {
    public func model(for agent: String) -> String? {
        agentModels?[agent].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    public var preferredTerminalBundleID = "com.apple.Terminal"
    public var preferredEditorBundleID = "com.microsoft.VSCode"
    public var projectRoots: [String] = []
    public var pollingIntervalSeconds = 300
    public var pollingEnabled = true
    public var cacheRetentionDays = 90
    public var revealTimeoutSeconds = 30
    public var requireAuthForProductionSecrets = true
    public var showMenuBarExtra = true
    public var aiAgentProgram = "claude"
    /// "external" opens terminals in the preferred terminal app. nil or "embedded" opens them inside ForgeDeck.
    /// Optional so settings written before the in-app terminal still load.
    public var terminalPlacement: String?
    /// The model each agent starts with, by program name. Missing or empty uses the agent's default.
    public var agentModels: [String: String]?
    public var trustedExecutables: [String] = ["git", "npm", "pnpm", "yarn", "node", "swift", "python3", "php", "composer", "docker", "make", "cargo", "go"]
    public var appearance = "system"
    /// Forge Remote: a Claude Code Remote Control server for every product. nil means never set up.
    public var remote: ForgeRemoteSettings?
    public init() {}
}

public struct Portfolio: Codable, Sendable {
    public static let currentSchemaVersion = 4
    public var schemaVersion = Portfolio.currentSchemaVersion
    public var organizations: [Organization] = [Organization()]
    public var products: [Product] = []
    public var connections: [Connection] = []
    public var variables: [VariableDefinition] = []
    public var settings = AppSettings()
    public init() {}

    public func product(slug: String) -> Product? {
        let wanted = slug.lowercased()
        guard !wanted.isEmpty else { return nil }
        if let exact = products.first(where: { $0.slug == wanted }) { return exact }
        // An id prefix must be long enough to mean one product.
        guard wanted.count >= 8 else { return nil }
        let matches = products.filter { $0.id.uuidString.lowercased().hasPrefix(wanted) }
        return matches.count == 1 ? matches[0] : nil
    }

    public func product(id: UUID?) -> Product? { products.first { $0.id == id } }
    public var groups: [String] {
        var seen: [String] = []
        for product in products where !seen.contains(product.group) { seen.append(product.group) }
        return seen
    }

    public func connection(provider: ProviderKind) -> Connection? { connections.first { $0.provider == provider } }
}

@discardableResult
public func with<T>(_ value: T, _ change: (inout T) -> Void) -> T {
    var copy = value
    change(&copy)
    return copy
}
