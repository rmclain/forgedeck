import Foundation

// Which products have an MCP server, found only in files on this Mac: the agents' own config files
// and the products' code. Nothing connects to a server, no credential is read, and no AI runs, so the
// answer is the same every time for the same files.
//
// Secrets stay out: headers and env values are never parsed into these types, and a URL keeps only
// its host for display. URL path words are kept for matching (a server at /wp-json/orders/mcp belongs
// to orders) but never shown, because some servers put a private token in the path.

// MARK: Configured servers

/// The agent whose config file holds a server.
public enum MCPClient: String, Sendable, Hashable, Codable, CaseIterable {
    case claudeCode, claudePlugin, claudeDesktop, codex, cursor, repository

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudePlugin: "Claude Code plugin"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .repository: "Repository .mcp.json"
        }
    }
}

public enum MCPTransport: String, Sendable, Hashable, Codable {
    case stdio, http, sse
}

/// Where a server's address points, from its host alone.
public enum MCPReach: String, Sendable, Hashable, Codable {
    /// A program the agent starts on this Mac.
    case localProcess
    /// localhost, *.local, *.test.
    case thisMac
    /// A private network address.
    case homeNetwork
    case internet

    public var title: String {
        switch self {
        case .localProcess: "Runs on this Mac"
        case .thisMac: "This Mac"
        case .homeNetwork: "Local network"
        case .internet: "Internet"
        }
    }
}

/// One MCP server entry in one agent's config.
public struct MCPServerEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var client: MCPClient
    /// The checkout or folder the entry is limited to. nil: every project.
    public var projectPath: String?
    /// The plugin that provides it, and the GitHub repository the plugin comes from.
    public var plugin: String?
    public var pluginRepository: String?
    public var transport: MCPTransport
    /// host or host:port. Never the path or query.
    public var host: String?
    /// The program's file name, like npx or uvx.
    public var program: String?
    /// The package npx, uvx, bunx, or pipx runs, like rea-agents@6.8.0.
    public var package: String?
    /// Lowercased words of the URL path. For matching only; never displayed.
    var pathWords: Set<String> = []
    /// Absolute paths in the command, its arguments, or its working folder. For matching only.
    var localPaths: [String] = []

    public var id: String { "\(client.rawValue)|\(projectPath ?? plugin ?? "*")|\(name)" }

    public init(name: String, client: MCPClient, projectPath: String? = nil, plugin: String? = nil, pluginRepository: String? = nil,
                transport: MCPTransport, host: String? = nil, program: String? = nil, package: String? = nil) {
        self.name = name
        self.client = client
        self.projectPath = projectPath
        self.plugin = plugin
        self.pluginRepository = pluginRepository
        self.transport = transport
        self.host = host
        self.program = program
        self.package = package
    }

    public var reach: MCPReach {
        guard let host else { return .localProcess }
        return MCPInventory.reach(ofHost: host)
    }

    /// The name says production: ends with -prod, _prod, -production, or contains "prod" as a word.
    public var isNamedProduction: Bool {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == "prod" || $0 == "production" || $0 == "live" }
    }

    /// "Claude Code · every project", "Claude Code · this checkout", "Claude Code plugin net-tools".
    public var whereTitle: String {
        if let plugin { return "\(client.title) \(plugin)" }
        if client == .repository { return "This repository's .mcp.json" }
        return projectPath == nil ? "\(client.title) · every project" : "\(client.title) · one project"
    }

    /// The package runs whatever version is newest each time it starts.
    public var isUnpinned: Bool {
        guard let package, let program, ["npx", "uvx", "bunx", "pnpx"].contains(program) else { return false }
        let bare = package.hasPrefix("@") ? String(package.dropFirst()) : package
        return !bare.contains("@") && !bare.contains("==")
    }
}

/// Why a server belongs to a product. Strongest first.
public enum MCPMatchReason: Sendable, Hashable {
    case projectConfig
    case runsFromCheckout
    case pluginRepository(String)
    case domain(EnvironmentTier)
    case addressNames(String)
    case named

    public var sentence: String {
        switch self {
        case .projectConfig: "Set up for this checkout"
        case .runsFromCheckout: "Runs a program from this checkout"
        case .pluginRepository(let repository): "The plugin is built from \(repository)"
        case .domain(let tier): "Its address is the \(tier.title.lowercased()) domain"
        case .addressNames(let word): "Its address names \(word)"
        case .named: "Named after the product"
        }
    }

    var strength: Int {
        switch self {
        case .projectConfig: 0
        case .runsFromCheckout: 1
        case .pluginRepository: 2
        case .domain: 3
        case .addressNames: 4
        case .named: 5
        }
    }
}

/// A configured server matched to a product.
public struct MCPConnection: Sendable, Hashable, Identifiable {
    public var entry: MCPServerEntry
    public var reason: MCPMatchReason
    /// The environment its address belongs to, when the domain says so.
    public var tier: EnvironmentTier?

    public var id: String { entry.id }

    public init(entry: MCPServerEntry, reason: MCPMatchReason, tier: EnvironmentTier? = nil) {
        self.entry = entry
        self.reason = reason
        self.tier = tier
    }

    /// Reaches production: its domain is the production domain, or it is on the internet and named prod.
    public var isProduction: Bool { tier == .production || (tier == nil && entry.isNamedProduction && entry.reach == .internet) }

    /// "Production", "Staging", "This Mac", "Local network", "Internet".
    public var reachTitle: String {
        if isProduction { return tier == .production ? "Production" : "Production (by name)" }
        if let tier, tier != .development { return tier.title }
        return entry.reach.title
    }
}

// MARK: Code

public struct MCPTool: Sendable, Hashable, Identifiable {
    public var name: String
    public var summary: String
    /// true: marked read-only. false: marked as a write. nil: the code does not say.
    public var readOnly: Bool?
    public var id: String { name }

    public init(name: String, summary: String, readOnly: Bool? = nil) {
        self.name = name
        self.summary = summary
        self.readOnly = readOnly
    }
}

/// An MCP server found in a product's code.
public struct MCPServerCode: Sendable, Hashable {
    /// PHP, Python, TypeScript.
    public var language: String
    /// Files that register tools or hold the server, relative to the checkout. At most a few.
    public var files: [String]
    public var tools: [MCPTool]
    /// The server's own instructions to agents, when the code holds them as text.
    public var instructions: String?
    public var instructionsFile: String?
    /// MCP.md or docs/MCP.md in the repository: how to use the server, in the team's words.
    public var guide: String?
    public var guideFile: String?
    /// The registry name from server.json.
    public var registryName: String?
    public var registrySummary: String?
    /// The code is an MCP server (an SDK dependency, registered tools, or server.json), not only a guide file.
    public var servesMCP: Bool

    public init(language: String, files: [String] = [], tools: [MCPTool] = [], instructions: String? = nil, instructionsFile: String? = nil,
                guide: String? = nil, guideFile: String? = nil, registryName: String? = nil, registrySummary: String? = nil, servesMCP: Bool) {
        self.language = language
        self.files = files
        self.tools = tools
        self.instructions = instructions
        self.instructionsFile = instructionsFile
        self.guide = guide
        self.guideFile = guideFile
        self.registryName = registryName
        self.registrySummary = registrySummary
        self.servesMCP = servesMCP
    }

    public var readOnlyCount: Int { tools.filter { $0.readOnly == true }.count }
    public var writeCount: Int { tools.filter { $0.readOnly == false }.count }
}

/// Everything ForgeDeck knows about one product's MCP servers.
public struct MCPProductInfo: Sendable, Hashable {
    public var connections: [MCPConnection]
    /// Code per checkout path.
    public var code: [String: MCPServerCode]

    public init(connections: [MCPConnection] = [], code: [String: MCPServerCode] = [:]) {
        self.connections = connections
        self.code = code
    }

    public var isEmpty: Bool { connections.isEmpty && code.values.allSatisfy { !$0.servesMCP && $0.guide == nil } }
    public var servesMCP: Bool { code.values.contains(where: \.servesMCP) }
    public var reachesProduction: Bool { connections.contains(where: \.isProduction) }
    /// Distinct server names, for badges.
    public var serverNames: [String] {
        var seen = Set<String>()
        return connections.map(\.entry.name).filter { seen.insert($0).inserted }
    }
    public var primaryCode: MCPServerCode? { code.values.sorted { $0.tools.count > $1.tools.count }.first }

    /// "MCP · 2 connections", "MCP server", for the header tag.
    public var badgeTitle: String {
        let count = serverNames.count
        if count == 0 { return "MCP server" }
        return "MCP · \(count) connection\(count == 1 ? "" : "s")"
    }
}

public enum MCPInventory {
    /// Everything for one product, read now: configs, the checkouts' .mcp.json, and a code scan. For the CLI.
    public static func info(for product: Product, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> MCPProductInfo {
        let entries = configured(home: home) + product.checkouts.flatMap { repositoryServers(checkout: $0.path) }
        var code: [String: MCPServerCode] = [:]
        for checkout in product.checkouts { if let found = scan(checkout: checkout.path) { code[checkout.path] = found } }
        return MCPProductInfo(connections: connections(for: product, entries: entries), code: code)
    }

    // MARK: Read configs

    /// Every configured server in the agents' config files under `home`.
    public static func configured(home: URL) -> [MCPServerEntry] {
        let fm = FileManager.default
        func data(_ path: String) -> Data? { fm.contents(atPath: home.appending(path: path).path) }
        var entries: [MCPServerEntry] = []
        if let data = data(".claude.json") { entries += parseClaudeCode(data) }
        if let data = data("Library/Application Support/Claude/claude_desktop_config.json") { entries += parseServers(data, client: .claudeDesktop) }
        if let data = data(".cursor/mcp.json") { entries += parseServers(data, client: .cursor) }
        if let data = data(".codex/config.toml"), let text = String(data: data, encoding: .utf8) { entries += parseCodex(text) }
        if let installed = data(".claude/plugins/installed_plugins.json") {
            entries += parsePlugins(installed: installed, marketplaces: data(".claude/plugins/known_marketplaces.json")) { path in fm.contents(atPath: path) }
        }
        return entries
    }

    /// A checkout's own .mcp.json.
    public static func repositoryServers(checkout: String) -> [MCPServerEntry] {
        guard let data = FileManager.default.contents(atPath: (checkout as NSString).appendingPathComponent(".mcp.json")) else { return [] }
        return parseServers(data, client: .repository, projectPath: checkout)
    }

    /// ~/.claude.json: mcpServers for every project, and projects[path].mcpServers for one.
    public static func parseClaudeCode(_ data: Data) -> [MCPServerEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var entries = servers(in: root["mcpServers"], client: .claudeCode, projectPath: nil)
        if let projects = root["projects"] as? [String: Any] {
            for (path, value) in projects.sorted(by: { $0.key < $1.key }) {
                entries += servers(in: (value as? [String: Any])?["mcpServers"], client: .claudeCode, projectPath: path)
            }
        }
        return entries
    }

    /// The common {"mcpServers": {...}} file: .mcp.json, Claude Desktop, Cursor, plugins.
    public static func parseServers(_ data: Data, client: MCPClient, projectPath: String? = nil, plugin: String? = nil, pluginRepository: String? = nil) -> [MCPServerEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return servers(in: root["mcpServers"] ?? root["servers"], client: client, projectPath: projectPath).map { entry in
            var entry = entry
            entry.plugin = plugin
            entry.pluginRepository = pluginRepository
            return entry
        }
    }

    private static func servers(in value: Any?, client: MCPClient, projectPath: String?) -> [MCPServerEntry] {
        guard let servers = value as? [String: Any] else { return [] }
        return servers.sorted { $0.key < $1.key }.compactMap { name, raw in
            guard let config = raw as? [String: Any] else { return nil }
            return entry(name: name, client: client, projectPath: projectPath,
                         type: config["type"] as? String, url: (config["url"] ?? config["serverUrl"]) as? String,
                         command: config["command"] as? String, args: config["args"] as? [String] ?? [], cwd: config["cwd"] as? String)
        }
    }

    /// Only these fields are read. Headers and env are skipped on purpose: they hold credentials.
    static func entry(name: String, client: MCPClient, projectPath: String?, type: String?, url: String?, command: String?, args: [String], cwd: String?) -> MCPServerEntry {
        var entry = MCPServerEntry(name: name, client: client, projectPath: projectPath, transport: .stdio)
        if let url, let parts = URLComponents(string: url), let host = parts.host?.lowercased() {
            entry.transport = (type?.lowercased() == "sse" || parts.path.hasSuffix("/sse")) ? .sse : .http
            entry.host = parts.port.map { "\(host):\($0)" } ?? host
            entry.pathWords = Set(parts.path.lowercased().split(separator: "/").map(String.init))
        } else if let command {
            entry.transport = .stdio
            entry.program = (command as NSString).lastPathComponent
            // Skip flags and the value after a --long flag (uvx --python-preference system pkg).
            var plain: [String] = []
            for (index, arg) in args.enumerated() where !arg.hasPrefix("-") {
                if index > 0, args[index - 1].hasPrefix("--"), !args[index - 1].contains("=") { continue }
                plain.append(arg)
            }
            if let program = entry.program, ["npx", "uvx", "bunx", "pnpx", "pipx"].contains(program) {
                entry.package = plain.first { $0 != "run" && !$0.hasPrefix("/") }
            }
            entry.localPaths = ([command, cwd].compactMap { $0 } + args).filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
                .map { ($0 as NSString).expandingTildeInPath }
        }
        return entry
    }

    /// ~/.codex/config.toml: [mcp_servers.name] tables with command, args, url.
    public static func parseCodex(_ text: String) -> [MCPServerEntry] {
        var entries: [MCPServerEntry] = []
        var name: String?
        var fields: [String: String] = [:]
        var args: [String] = []
        func flush() {
            if let name { entries.append(entry(name: name, client: .codex, projectPath: nil, type: nil, url: fields["url"], command: fields["command"], args: args, cwd: fields["cwd"])) }
            name = nil; fields = [:]; args = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                if table.hasPrefix("mcp_servers.") {
                    let rest = String(table.dropFirst("mcp_servers.".count))
                    // [mcp_servers.x.env] belongs to x and holds secrets: skip its keys, keep x.
                    if rest.contains(".") { if name != nil { fields["__skip"] = "1" }; continue }
                    flush()
                    name = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } else {
                    flush()
                }
                continue
            }
            guard name != nil, fields["__skip"] == nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "command", "url", "cwd": fields[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            case "args":
                args = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
            default: break
            }
        }
        flush()
        return entries
    }

    /// Claude Code plugins: each installed plugin's .mcp.json, with the GitHub repository its marketplace comes from.
    public static func parsePlugins(installed: Data, marketplaces: Data?, read: (String) -> Data?) -> [MCPServerEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: installed)) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        let markets = marketplaces.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        var entries: [MCPServerEntry] = []
        for (key, value) in plugins.sorted(by: { $0.key < $1.key }) {
            let install = ((value as? [Any])?.first ?? value) as? [String: Any]
            guard let path = install?["installPath"] as? String, let data = read((path as NSString).appendingPathComponent(".mcp.json")) else { continue }
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            let market = parts.count == 2 ? (markets[parts[1]] as? [String: Any])?["source"] as? [String: Any] : nil
            let repository = (market?["source"] as? String) == "github" ? market?["repo"] as? String : nil
            entries += parseServers(data, client: .claudePlugin, plugin: parts[0], pluginRepository: repository)
        }
        return entries
    }

    // MARK: Reach

    public static func reach(ofHost hostAndPort: String) -> MCPReach {
        let host = hostAndPort.split(separator: ":").first.map(String.init)?.lowercased() ?? hostAndPort
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".test") || host.hasSuffix(".localhost") {
            return .thisMac
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 100 && (64...127).contains(octets[1])) {
                return .homeNetwork
            }
            if octets[0] == 127 { return .thisMac }
        }
        return .internet
    }

    // MARK: Match

    /// Words too common to tie a server to a product.
    private static let genericWords: Set<String> = ["app", "src", "api", "public", "web", "www", "site", "server", "client", "mcp", "wp-json", "plugins", "plugin", "core", "main", "test", "dev", "v1", "v2"]

    /// The configured servers that belong to a product, with the strongest reason for each.
    public static func connections(for product: Product, entries: [MCPServerEntry]) -> [MCPConnection] {
        let checkouts = product.checkouts.map { ($0.path as NSString).standardizingPath }
        var words = Set([product.slug.lowercased()] + product.checkouts.map { ($0.path as NSString).lastPathComponent.lowercased() }
                        + product.repositories.map { $0.name.lowercased() })
        words = words.filter { $0.count >= 4 && !genericWords.contains($0) }
        let repositories = Set(product.repositories.map { "\($0.owner)/\($0.name)".lowercased() })
        var domains: [String: EnvironmentTier] = [:]
        for environment in product.environments {
            for domain in environment.domains { if let key = hostKey(domain) { domains[key] = environment.tier } }
        }
        for link in product.links where link.kind == .site { if let key = hostKey(link.url) { domains[key] = domains[key] ?? .production } }

        var found: [String: MCPConnection] = [:]
        for entry in entries {
            var reasons: [MCPMatchReason] = []
            var tier: EnvironmentTier?
            if let project = entry.projectPath.map({ ($0 as NSString).standardizingPath }),
               checkouts.contains(where: { project == $0 || project.hasPrefix($0 + "/") }) {
                reasons.append(.projectConfig)
            }
            if entry.localPaths.contains(where: { path in checkouts.contains { path == $0 || path.hasPrefix($0 + "/") } }) { reasons.append(.runsFromCheckout) }
            if let repository = entry.pluginRepository, repositories.contains(repository.lowercased()) { reasons.append(.pluginRepository(repository)) }
            if let host = entry.host.flatMap(hostKey), let match = domains[host] {
                reasons.append(.domain(match))
                tier = match
            }
            if let word = words.sorted().first(where: { entry.pathWords.contains($0) }) { reasons.append(.addressNames(word)) }
            let base = baseName(entry.name)
            if words.contains(entry.name.lowercased()) || words.contains(base) { reasons.append(.named) }
            guard let best = reasons.min(by: { $0.strength < $1.strength }) else { continue }
            // A project-scoped entry for another project never matches by name alone.
            if let project = entry.projectPath, best.strength >= MCPMatchReason.named.strength,
               !checkouts.contains(where: { project.hasPrefix($0) }) { continue }
            found[entry.id] = MCPConnection(entry: entry, reason: best, tier: tier)
        }
        return found.values.sorted { ($0.isProduction ? 1 : 0, $0.reason.strength, $0.entry.name) < ($1.isProduction ? 1 : 0, $1.reason.strength, $1.entry.name) }
    }

    /// The host to compare. Hosts on this Mac (localhost, *.local) match only with the same port, since
    /// every local server shares them; a local host without a port never matches.
    static func hostKey(_ text: String) -> String? {
        let parts = URLComponents(string: text.contains("://") ? text : "https://\(text)")
        guard let host = parts?.host?.lowercased(), !host.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard reach(ofHost: bare) == .thisMac else { return bare }
        guard let port = parts?.port else { return nil }
        return "\(bare):\(port)"
    }

    static func bareHost(_ text: String) -> String {
        var host = text.lowercased()
        if let parsed = URLComponents(string: host.contains("://") ? host : "https://\(host)")?.host { host = parsed }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// orders-prod → orders; home_mcp_local → home_mcp.
    static func baseName(_ name: String) -> String {
        var base = name.lowercased()
        for suffix in ["-production", "_production", "-prod", "_prod", "-staging", "_staging", "-stage", "-dev", "_dev", "-local", "_local", "-live"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        return base
    }

    // MARK: Code

    private static let skippedFolders: Set<String> = [".git", "node_modules", "vendor", ".venv", "venv", "dist", "build", "tests", "test", "__tests__",
                                                      "_vendor", "coverage", ".next", "__pycache__", "site-packages", ".build"]
    private static let guideFiles = ["MCP.md", "docs/MCP.md", "docs/mcp.md", ".forgedeck/mcp.md", "mcp/README.md"]

    /// Reads a checkout for an MCP server: dependencies, registered tools, the server's instructions, and a guide file.
    /// Returns nil when there is no sign of MCP. Reads at most `maxFiles` source files.
    public static func scan(checkout: String, maxFiles: Int = 4000) -> MCPServerCode? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: checkout, isDirectory: true)
        func read(_ relative: String, limit: Int = 1_500_000) -> String? {
            let url = root.appending(path: relative)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= limit else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        var code = MCPServerCode(language: "", files: [], tools: [], servesMCP: false)
        var languages: [String: Int] = [:]
        if let manifest = read("package.json"), manifest.range(of: #""(@modelcontextprotocol/sdk|fastmcp|mcp-framework|mcp-handler|@vercel/mcp-adapter|@mastra/mcp)""#, options: .regularExpression) != nil {
            code.servesMCP = true; languages["TypeScript", default: 0] += 1
        }
        for file in ["pyproject.toml", "requirements.txt", "setup.py"] {
            if let text = read(file), text.range(of: #"(?m)(^|["'\s])(mcp|fastmcp)(\[[a-z,]+\])?\s*([<>=~!]|["',]|$)"#, options: .regularExpression) != nil {
                code.servesMCP = true; languages["Python", default: 0] += 1
            }
        }
        if let text = read("composer.json"), text.contains("mcp-adapter") || text.contains("abilities-api") { code.servesMCP = true; languages["PHP", default: 0] += 1 }
        if let text = read("server.json"), let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], json["name"] != nil {
            code.servesMCP = true
            code.registryName = json["name"] as? String
            code.registrySummary = json["description"] as? String
        }
        for file in guideFiles {
            if let text = read(file, limit: 200_000) { code.guide = String(text.prefix(20_000)); code.guideFile = file; break }
        }

        // Source files. A folder or file with "mcp" in its name is read first, since that is where servers live.
        var sources: [String] = []
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if skippedFolders.contains(url.lastPathComponent) || walker.level > 8 { walker.skipDescendants() }
                    continue
                }
                guard ["php", "py", "ts", "js", "mjs", "mts"].contains(url.pathExtension) else { continue }
                sources.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
                if sources.count >= maxFiles { break }
            }
        }
        sources.sort { ($0.lowercased().contains("mcp") ? 0 : 1, $0) < ($1.lowercased().contains("mcp") ? 0 : 1, $1) }

        var tools: [String: MCPTool] = [:]
        var order: [String] = []
        var files: [String] = []
        var bestInstructions: (text: String, file: String)?
        for relative in sources {
            guard let text = read(relative) else { continue }
            let isMCPPath = relative.lowercased().contains("mcp")
            // Cheap filter: only files that mention tools or MCP.
            guard isMCPPath || text.range(of: "tool", options: .caseInsensitive) != nil || text.contains("ability") else { continue }
            let language = relative.hasSuffix(".php") ? "PHP" : relative.hasSuffix(".py") ? "Python" : "TypeScript"
            let found = extractTools(text, language: language)
            if !found.isEmpty {
                files.append(relative)
                languages[language, default: 0] += found.count
                for tool in found where tools[tool.name] == nil {
                    tools[tool.name] = tool
                    order.append(tool.name)
                }
            }
            if let instructions = extractInstructions(text, language: language, isMCPPath: isMCPPath),
               instructions.count > (bestInstructions?.text.count ?? 0) {
                bestInstructions = (instructions, relative)
            }
            if tools.count >= 300 { break }
        }
        // Registered tools without an SDK dependency still count only when they look like an MCP server.
        if !tools.isEmpty, code.servesMCP || files.contains(where: { $0.lowercased().contains("mcp") }) { code.servesMCP = true }
        guard code.servesMCP || code.guide != nil else { return nil }
        code.tools = code.servesMCP ? order.compactMap { tools[$0] } : []
        code.files = Array(files.prefix(6))
        if code.servesMCP, let bestInstructions {
            code.instructions = String(bestInstructions.text.prefix(20_000))
            code.instructionsFile = bestInstructions.file
        }
        code.language = languages.max { $0.value < $1.value }?.key ?? ""
        return code
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let phpAbility = regex(#"'([a-z0-9][a-z0-9/_-]{1,80})'\s*(?:=>\s*array\(|,\s*array\()\s*'label'\s*=>\s*'((?:[^'\\]|\\.)*)'\s*,\s*'description'\s*=>\s*'((?:[^'\\]|\\.)*)'"#)
    private static let pyTool = regex(#"@(?:\w+(?:\.\w+)*\.)?tool\s*(\((?:[^()]|\([^()]*\))*\))?\s*(?:@\w[\w.]*(?:\((?:[^()]|\([^()]*\))*\))?\s*)*(?:async\s+)?def\s+(\w+)\s*\("#)
    private static let tsTool = regex(#"\.(?:tool|registerTool)\(\s*["'`]([\w./-]+)["'`]\s*,\s*(?:\{[^{}]*?(?:description|title)\s*:\s*)?["'`]([^"'`]*)["'`]"#)
    private static let docstring = regex(#"\)\s*(?:->\s*[^:]+)?:\s*\n\s*(?:"""|''')\s*([^\n]*)"#)

    /// Tools registered in one source file.
    static func extractTools(_ text: String, language: String) -> [MCPTool] {
        let ns = text as NSString
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        func window(after match: NSTextCheckingResult, _ length: Int) -> String {
            let start = match.range.location + match.range.length
            return ns.substring(with: NSRange(location: start, length: min(length, ns.length - start)))
        }
        var tools: [MCPTool] = []
        switch language {
        case "PHP":
            for match in phpAbility.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let key = group(match, 1), let label = group(match, 2) else { continue }
                let body = window(after: match, 900)
                let end = body.range(of: "'run'")?.lowerBound ?? body.endIndex
                let head = body[..<end]
                let readOnly: Bool? = head.contains("'readonly'") ? head.range(of: #"'readonly'\s*=>\s*true"#, options: .regularExpression) != nil : nil
                let description = group(match, 3) ?? ""
                tools.append(MCPTool(name: key.split(separator: "/").last.map(String.init) ?? key,
                                     summary: firstSentence(description.isEmpty ? label : description), readOnly: readOnly))
            }
            // When a file marks its read-only abilities, an ability without the mark is a write.
            if tools.contains(where: { $0.readOnly != nil }) {
                tools = tools.map { tool in var tool = tool; tool.readOnly = tool.readOnly ?? false; return tool }
            }
        case "Python":
            let mentionsMCP = text.range(of: "mcp", options: .caseInsensitive) != nil
            for match in pyTool.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard var name = group(match, 2) else { continue }
                // A bare @tool belongs to many libraries (LangChain, CrewAI). Count it only in MCP code.
                if ns.substring(with: match.range).hasPrefix("@tool"), !mentionsMCP { continue }
                let decorator = group(match, 1) ?? ""
                if let explicit = decorator.firstMatch(of: /name\s*=\s*["']([^"']+)["']/) { name = String(explicit.1) }
                var summary = decorator.firstMatch(of: /description\s*=\s*["']([^"']+)["']/).map { String($0.1) } ?? ""
                if summary.isEmpty, let doc = docstring.firstMatch(in: text, range: NSRange(location: match.range.location + match.range.length,
                                                                                             length: min(600, ns.length - match.range.location - match.range.length))) {
                    summary = group(doc, 1) ?? ""
                }
                let hint = decorator.firstMatch(of: /readOnlyHint["']?\s*[:=]\s*(True|False|true|false)/).map { $0.1.lowercased() == "true" }
                tools.append(MCPTool(name: name, summary: firstSentence(summary), readOnly: hint))
            }
        default:
            for match in tsTool.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let name = group(match, 1) else { continue }
                let after = window(after: match, 600)
                let hint = after.firstMatch(of: /readOnlyHint\s*:\s*(true|false)/).map { $0.1 == "true" }
                tools.append(MCPTool(name: name, summary: firstSentence(group(match, 2) ?? ""), readOnly: hint))
            }
        }
        return tools
    }

    private static let heredoc = regex(#"<<<\s*'?([A-Z_][A-Z0-9_]*)'?\n([\s\S]*?)\n\s*\1;"#)
    private static let phpInstructions = regex(#"'instructions'\s*=>\s*'((?:[^'\\]|\\.){80,})'"#)
    private static let pyInstructions = regex(#"instructions\s*=\s*(?:\(\s*)?(?:"""([\s\S]{80,}?)"""|'''([\s\S]{80,}?)'''|"((?:[^"\\]|\\.){80,})")"#)
    private static let tsInstructions = regex(#"instructions\s*:\s*(?:`([\s\S]{80,}?)`|"((?:[^"\\]|\\.){80,})"|'((?:[^'\\]|\\.){80,})')"#)

    /// The server's instructions when the code holds them as one literal. Text built at run time is not guessed at.
    static func extractInstructions(_ text: String, language: String, isMCPPath: Bool) -> String? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        func first(_ regex: NSRegularExpression) -> String? {
            guard let match = regex.firstMatch(in: text, range: range) else { return nil }
            for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                return ns.substring(with: match.range(at: index))
            }
            return nil
        }
        var found: String?
        switch language {
        case "PHP":
            found = first(phpInstructions)
            // A heredoc in an MCP file that talks about instructions, like a Guide class returning the server's instructions.
            if found == nil, isMCPPath, text.contains("instructions") {
                found = heredoc.matches(in: text, range: range).map { ns.substring(with: $0.range(at: 2)) }.max { $0.count < $1.count }
            }
        case "Python": found = first(pyInstructions)
        default: found = first(tsInstructions)
        }
        guard let found, found.count >= 200 else { return nil }
        return found.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\'", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstSentence(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "\\'", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = clean.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { return String(clean[..<end.upperBound]).trimmingCharacters(in: .whitespaces) }
        return clean.count > 160 ? String(clean.prefix(159)) + "…" : clean
    }

    // MARK: Advice

    public struct Advice: Sendable, Hashable, Identifiable {
        public var text: String
        public var isWarning: Bool
        public var id: String { text }
    }

    /// Practices that follow from the facts above. Each one names the server it is about.
    public static func advice(_ info: MCPProductInfo) -> [Advice] {
        var items: [Advice] = []
        let production = info.connections.filter(\.isProduction)
        for connection in production where connection.entry.projectPath == nil && connection.entry.client == .claudeCode {
            items.append(Advice(text: "\(connection.entry.name) reaches production and is set up for every Claude Code project, so an agent working in any repository can use it. Add it only to the projects that need it (claude mcp add --scope project).", isWarning: true))
        }
        if let first = production.first {
            items.append(Advice(text: "Changes through \(first.entry.name) go live. Ask the agent to read first and to show what it will change before any write.", isWarning: true))
        }
        let local = info.connections.filter { !$0.isProduction && ($0.entry.reach == .thisMac || $0.entry.reach == .localProcess) }
        if let first = production.first, let rehearsal = local.first {
            items.append(Advice(text: "Try a change with \(rehearsal.entry.name) (this Mac) before running it with \(first.entry.name).", isWarning: false))
        }
        if let code = info.primaryCode, code.servesMCP {
            if code.writeCount > 0 {
                items.append(Advice(text: "\(code.writeCount) of \(code.tools.count) tools change data and \(code.readOnlyCount) only read. Start a session with the read tools.", isWarning: false))
            } else if !code.tools.isEmpty, code.tools.allSatisfy({ $0.readOnly == nil }) {
                items.append(Advice(text: "The tools do not say whether they only read. Mark them (readOnlyHint, or a readonly flag) so agents and people can tell writes apart.", isWarning: false))
            }
            if info.connections.isEmpty {
                items.append(Advice(text: "This repository serves MCP, but no agent on this Mac is set up to use it.", isWarning: false))
            }
            if code.instructions == nil, code.guide == nil {
                items.append(Advice(text: "No instructions found as text. Give the server instructions, or add MCP.md to the repository, so every agent gets the same rules.", isWarning: false))
            }
        }
        for connection in info.connections where connection.entry.isUnpinned {
            items.append(Advice(text: "\(connection.entry.name) runs the newest \(connection.entry.package ?? "package") each time it starts. Pin a version so a release cannot change it under you.", isWarning: false))
        }
        if !info.connections.isEmpty, info.code.values.allSatisfy({ !$0.servesMCP && $0.guide == nil }) {
            items.append(Advice(text: "The server's code is not in a checkout here, so its tools and instructions cannot be read. Add MCP.md to the repository to keep how to use it next to the product.", isWarning: false))
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.text).inserted }
    }

    /// Lines for CONTEXT.md, so an agent starting in the product knows its MCP servers before it acts.
    public static func contextSection(_ info: MCPProductInfo) -> String? {
        guard !info.isEmpty else { return nil }
        var lines = ["## MCP servers", ""]
        for connection in info.connections {
            lines.append("- \(connection.entry.name): \(connection.entry.whereTitle), \(connection.reachTitle.lowercased())\(connection.entry.host.map { " (\($0))" } ?? "")."
                         + (connection.isProduction ? " Writes change production: read first and confirm before any write." : ""))
        }
        if let code = info.primaryCode, code.servesMCP {
            lines.append("- This repository serves MCP: \(code.tools.count) tool\(code.tools.count == 1 ? "" : "s")\(code.files.first.map { ", registered in \($0)" } ?? "").")
            if let file = code.instructionsFile { lines.append("- The server's instructions to agents are in \(file).") }
        }
        if let file = info.primaryCode?.guideFile { lines.append("- How to use it: \(file).") }
        return lines.joined(separator: "\n")
    }
}
