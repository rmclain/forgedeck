import Foundation

// Environments a repository proposes in `.forgedeck/environments.json`. An agent (or a person) writes the file in the
// checkout; ForgeDeck reads it, checks every value, and shows what would be added. Nothing becomes an environment, and
// nothing is called production, until the person reviews it in the app. The file holds names, domains, and URLs only.

public struct ProposedEnvironment: Codable, Hashable, Sendable {
    public var name: String?
    /// production, staging, development (or local), preview, custom.
    public var tier: String
    public var domains: [String]?
    /// A URL that names the running release (commit or version). Becomes a Version URL check.
    public var versionURL: String?
    /// A URL that answers 2xx when the site is up. Becomes a health check.
    public var healthURL: String?
    /// The GitHub deployment environment name, when deploys go through GitHub.
    public var github: String?
    /// Why the agent thinks this is right: the files it read. Shown in the review.
    public var note: String?
    /// The companion's site root or its /_forgedeck/v1 URL. Becomes a metrics source that reads counters and leads.
    public var metricsURL: String?
    /// The name of the ForgeDeck variable that holds the token for it. Never the token.
    public var metricsToken: String?

    public init(name: String? = nil, tier: String, domains: [String]? = nil, versionURL: String? = nil, healthURL: String? = nil,
                github: String? = nil, note: String? = nil, metricsURL: String? = nil, metricsToken: String? = nil) {
        self.name = name
        self.tier = tier
        self.domains = domains
        self.versionURL = versionURL
        self.healthURL = healthURL
        self.github = github
        self.note = note
        self.metricsURL = metricsURL
        self.metricsToken = metricsToken
    }
}

/// The file as read from one checkout.
public struct EnvironmentProposalFile: Sendable, Hashable {
    public var checkoutID: UUID
    public var checkoutName: String
    public var entries: [ProposedEnvironment]
    /// Set when the file exists but cannot be used at all.
    public var error: String?

    public init(checkoutID: UUID, checkoutName: String, entries: [ProposedEnvironment], error: String? = nil) {
        self.checkoutID = checkoutID
        self.checkoutName = checkoutName
        self.entries = entries
        self.error = error
    }
}

/// One proposed environment, checked against the product as it is now.
public struct EnvironmentProposal: Sendable, Hashable, Identifiable {
    public var id: String
    public var checkoutName: String
    public var entry: ProposedEnvironment
    public var tier: EnvironmentTier?
    public var name: String
    /// What is wrong with the entry. A proposal with problems cannot be added.
    public var problems: [String]
    /// The existing environment it adds to, when one has the same name or tier.
    public var existingID: UUID?
    /// What adding it changes, in words: "New environment", "Domain example.com", "Version URL …".
    public var changes: [String]

    public var isAddable: Bool { problems.isEmpty && !changes.isEmpty }
    public var isProduction: Bool { tier == .production }
}

public enum EnvironmentProposals {
    public static let relativePath = ".forgedeck/environments.json"
    static let maxBytes = 64 * 1024
    static let maxEntries = 10

    /// Reads the file in each checkout. Returns only checkouts that have one.
    public static func read(_ product: Product) -> [EnvironmentProposalFile] {
        product.checkouts.compactMap { checkout in
            read(folder: checkout.path).map { EnvironmentProposalFile(checkoutID: checkout.id, checkoutName: checkout.name, entries: $0.entries, error: $0.error) }
        }
    }

    /// nil when the folder has no file.
    public static func read(folder: String) -> (entries: [ProposedEnvironment], error: String?)? {
        let url = URL(fileURLWithPath: folder).appending(path: relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { return ([], "\(relativePath) is not a regular file.") }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxBytes else { return ([], "\(relativePath) is larger than 64 KB.") }
        guard let data = try? Data(contentsOf: url) else { return ([], "\(relativePath) could not be read.") }
        return parse(data)
    }

    public static func parse(_ data: Data) -> (entries: [ProposedEnvironment], error: String?) {
        struct File: Decodable { var environments: [ProposedEnvironment] }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.environments.count <= maxEntries else { return ([], "The file proposes more than \(maxEntries) environments.") }
            return (file.environments, nil)
        } catch {
            return ([], "\(relativePath) is not valid: it needs {\"environments\": [{\"tier\": \"production\", …}]}.")
        }
    }

    public static func tier(_ text: String) -> EnvironmentTier? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "local" || value == "dev" { return .development }
        if value == "prod" { return .production }
        return EnvironmentTier(rawValue: value)
    }

    /// A bare host name: no scheme, path, port, or spaces.
    public static func isValidDomain(_ text: String) -> Bool {
        let host = text.lowercased()
        guard (1...253).contains(host.count), !host.hasPrefix("."), !host.hasSuffix("."), host.contains(".") || host == "localhost" else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.count) && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }

    static func isValidGitHubName(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || " _.-".contains($0)) }
    }

    /// The companion root a metrics URL names, for comparing: lowercased, without the contract path or a trailing slash.
    static func metricsBase(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        while value.hasSuffix("/") { value.removeLast() }
        for suffix in ["/_forgedeck/v1", "/wp-json/forgedeck/v1"] where value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        return value
    }

    /// Every proposal across the product's files, checked against its current environments.
    public static func plan(_ product: Product, files: [EnvironmentProposalFile]) -> [EnvironmentProposal] {
        var seen = Set<String>()
        var result: [EnvironmentProposal] = []
        for file in files {
            for (index, entry) in file.entries.enumerated() {
                let proposal = check(entry, in: product, id: "\(file.checkoutID.uuidString)-\(index)", checkoutName: file.checkoutName)
                // The same environment proposed by two checkouts is shown once.
                guard seen.insert(proposal.name.lowercased()).inserted else { continue }
                result.append(proposal)
            }
        }
        return result
    }

    public static func check(_ entry: ProposedEnvironment, in product: Product, id: String = UUID().uuidString, checkoutName: String = "") -> EnvironmentProposal {
        var problems: [String] = []
        let tier = tier(entry.tier)
        if tier == nil { problems.append("Unknown tier \"\(entry.tier)\". Use production, staging, development, preview, or custom.") }
        let trimmedName = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = String((trimmedName.isEmpty ? (tier?.title ?? entry.tier) : trimmedName).prefix(40))
        let domains = (entry.domains ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for domain in domains where !isValidDomain(domain) {
            problems.append("\"\(domain)\" is not a domain. Give the host only, like example.com.")
        }
        for (label, text) in [("Version URL", entry.versionURL), ("Health URL", entry.healthURL)] {
            guard let text, !text.isEmpty else { continue }
            do { _ = try URLPolicy.validate(text) } catch { problems.append("\(label): \(error)") }
        }
        if let github = entry.github, !github.isEmpty, !isValidGitHubName(github) { problems.append("\"\(github)\" is not a GitHub environment name.") }
        let metricsURL = metricsBase(entry.metricsURL)
        if let text = entry.metricsURL, !text.isEmpty {
            do { _ = try URLPolicy.validate(text) } catch { problems.append("Metrics URL: \(error)") }
        }
        if let key = entry.metricsToken, !key.isEmpty {
            if !VariableResolver.isValidKey(key) { problems.append("metricsToken is the name of a \(Brand.name) variable, like FORGEDECK_TOKEN_PRODUCTION. Never the token.") }
            if metricsURL == nil { problems.append("metricsToken is given without a metricsURL.") }
        }

        // Same name, or for single-use tiers the same tier: add to that environment instead of making a second one.
        let existing = product.environments.first { $0.name.lowercased() == name.lowercased() }
            ?? product.environments.first { $0.tier == tier && tier != .custom && tier != .preview }
        var changes: [String] = []
        if existing == nil { changes.append("New \(tier?.title ?? "") environment \"\(name)\"") }
        for domain in domains where !(existing?.domains.map { $0.lowercased() }.contains(domain) ?? false) { changes.append("Domain \(domain)") }
        let urls = Set(existing?.probes.map { $0.url.lowercased() } ?? [])
        if let url = entry.versionURL, !url.isEmpty, !urls.contains(url.lowercased()) { changes.append("Version URL \(url)") }
        if let url = entry.healthURL, !url.isEmpty, !urls.contains(url.lowercased()) { changes.append("Health check \(url)") }
        if let metricsURL, !(existing?.metricSources.contains { metricsBase($0.baseURL) == metricsURL } ?? false) {
            changes.append("Leads and metrics from \(metricsURL)" + (entry.metricsToken.map { $0.isEmpty ? "" : " with \($0)" } ?? ""))
        }
        if let github = entry.github, !github.isEmpty, existing?.githubEnvironmentName == nil {
            if product.hasRemote { changes.append("GitHub environment \(github)") } else { problems.append("GitHub environment \"\(github)\" given, but the product has no GitHub repository.") }
        }
        return EnvironmentProposal(id: id, checkoutName: checkoutName, entry: entry, tier: tier, name: existing?.name ?? name,
                                   problems: problems, existingID: existing?.id, changes: changes)
    }

    /// Adds the proposal to the product. Only what `changes` lists: nothing existing is removed or replaced.
    public static func apply(_ proposal: EnvironmentProposal, to product: inout Product) {
        guard proposal.isAddable, let tier = proposal.tier else { return }
        let index: Int
        if let id = proposal.existingID, let found = product.environments.firstIndex(where: { $0.id == id }) {
            index = found
        } else {
            product.environments.append(ProductEnvironment(name: proposal.name, tier: tier))
            index = product.environments.count - 1
        }
        var environment = product.environments[index]
        for domain in (proposal.entry.domains ?? []).map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
        where !environment.domains.map({ $0.lowercased() }).contains(domain) {
            environment.domains.append(domain)
        }
        let urls = Set(environment.probes.map { $0.url.lowercased() })
        for (kind, text) in [(ProbeConfig.Kind.release, proposal.entry.versionURL), (.health, proposal.entry.healthURL)] {
            guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, !urls.contains(text.lowercased()) else { continue }
            var probe = ProbeConfig()
            probe.kind = kind
            probe.name = kind == .release ? "Version" : "Health"
            probe.url = text
            environment.probes.append(probe)
        }
        if let base = metricsBase(proposal.entry.metricsURL), !environment.metricSources.contains(where: { metricsBase($0.baseURL) == base }) {
            var source = MetricSource()
            source.name = "Companion"
            source.baseURL = proposal.entry.metricsURL?.trimmingCharacters(in: .whitespaces) ?? base
            source.bearerVariableKey = proposal.entry.metricsToken?.nilIfEmpty
            source.leadsEnabled = true
            source.eventsEnabled = false
            environment.metricSources.append(source)
        }
        if let github = proposal.entry.github, !github.isEmpty, environment.githubEnvironmentName == nil, product.hasRemote {
            environment.githubEnvironmentName = github
        }
        product.environments[index] = environment
    }
}
