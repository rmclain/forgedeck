import Foundation

// Storage: three files in one folder.
//   portfolio.json   definitions (products, connections, variable metadata, settings). Versioned, migrated.
//   cache.json       observations. Bounded. Safe to delete.
//   audit.jsonl      append-only audit events, one JSON object per line.
// No file ever holds a secret value. Secrets live in the Keychain.
//
// The app is the only writer of portfolio.json and cache.json. The CLI reads them and
// appends to audit.jsonl (O_APPEND, so two writers cannot interleave inside a line).

public struct StoreLocation: Sendable {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    /// FORGEDECK_HOME overrides the folder (tests, snapshots, experiments).
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> StoreLocation {
        if let path = environment["FORGEDECK_HOME"], !path.isEmpty {
            return StoreLocation(directory: URL(fileURLWithPath: path, isDirectory: true))
        }
        return StoreLocation(directory: URL.applicationSupportDirectory.appending(path: Brand.name, directoryHint: .isDirectory))
    }

    public static func isOverridden(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(environment["FORGEDECK_HOME"] ?? "").isEmpty
    }

    public var portfolioURL: URL { directory.appending(path: "portfolio.json") }
    public var cacheURL: URL { directory.appending(path: "cache.json") }
    public var auditURL: URL { directory.appending(path: "audit.jsonl") }
    public var logsDirectory: URL { directory.appending(path: "logs", directoryHint: .isDirectory) }
    public var launchDirectory: URL { directory.appending(path: "launch", directoryHint: .isDirectory) }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

public enum StoreError: Error, CustomStringConvertible, Equatable {
    case newerSchema(found: Int, supported: Int)
    case corrupt(String)
    case integrity([String])

    public var description: String {
        switch self {
        case .newerSchema(let found, let supported):
            "This data was written by a newer version (schema \(found), this build reads up to \(supported))."
        case .corrupt(let why): "The data file could not be read: \(why)"
        case .integrity(let problems): "Integrity check failed: \(problems.joined(separator: "; "))"
        }
    }
}

public enum JSONCoding {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Schema migrations run on the raw JSON before decoding, one version at a time.
public enum PortfolioMigrator {
    public typealias JSON = [String: Any]

    public static func migrate(_ data: Data) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: data) as? JSON else {
            throw StoreError.corrupt("top level is not an object")
        }
        var version = json["schemaVersion"] as? Int ?? 1
        guard version <= Portfolio.currentSchemaVersion else {
            throw StoreError.newerSchema(found: version, supported: Portfolio.currentSchemaVersion)
        }
        while version < Portfolio.currentSchemaVersion {
            json = step(json, from: version)
            version += 1
            json["schemaVersion"] = version
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    private static func step(_ json: JSON, from version: Int) -> JSON {
        var json = json
        switch version {
        case 1:
            // v1 called the last lifecycle stage "retired" and had no per-product profiles or recipes.
            if var products = json["products"] as? [JSON] {
                for index in products.indices {
                    if products[index]["lifecycle"] as? String == "retired" { products[index]["lifecycle"] = "archived" }
                    if products[index]["profiles"] == nil { products[index]["profiles"] = [JSON]() }
                    if products[index]["recipes"] == nil { products[index]["recipes"] = [JSON]() }
                }
                json["products"] = products
            }
        case 2:
            // v3 adds context links between products.
            if var products = json["products"] as? [JSON] {
                for index in products.indices where products[index]["contextLinks"] == nil {
                    products[index]["contextLinks"] = [JSON]()
                }
                json["products"] = products
            }
        case 3:
            // v4 adds install links (symlinks into local sites).
            if var products = json["products"] as? [JSON] {
                for index in products.indices where products[index]["installLinks"] == nil {
                    products[index]["installLinks"] = [JSON]()
                }
                json["products"] = products
            }
        default:
            break
        }
        return json
    }
}

public enum IntegrityChecker {
    /// Problems in the references between definitions. An empty list means the portfolio is sound.
    public static func problems(in portfolio: Portfolio) -> [String] {
        var problems: [String] = []
        var slugs = Set<String>()
        var ids = Set<UUID>()
        for product in portfolio.products {
            if !slugs.insert(product.slug).inserted { problems.append("duplicate slug \(product.slug)") }
            if !ids.insert(product.id).inserted { problems.append("duplicate product id \(product.id)") }
            let components = Set(product.components.map(\.id))
            let repos = Set(product.repositories.map(\.id))
            let checkouts = Set(product.checkouts.map(\.id))
            let environments = Set(product.environments.map(\.id))
            for repo in product.repositories {
                if let id = repo.componentID, !components.contains(id) { problems.append("\(product.slug): repository \(repo.fullName) points at a missing component") }
            }
            for checkout in product.checkouts {
                if let id = checkout.repositoryID, !repos.contains(id) { problems.append("\(product.slug): checkout \(checkout.name) points at a missing repository") }
                if let id = checkout.componentID, !components.contains(id) { problems.append("\(product.slug): checkout \(checkout.name) points at a missing component") }
            }
            for recipe in product.recipes {
                if let id = recipe.checkoutID, !checkouts.contains(id) { problems.append("\(product.slug): recipe \(recipe.label) points at a missing checkout") }
                if let id = recipe.environmentID, !environments.contains(id) { problems.append("\(product.slug): recipe \(recipe.label) points at a missing environment") }
            }
            for link in product.installLinks where link.checkoutID.map({ !checkouts.contains($0) }) ?? true {
                problems.append("\(product.slug): install link \(link.linkName) points at a missing checkout")
            }
            for link in product.contextLinks where link.productID == product.id {
                problems.append("\(product.slug): links to itself for context")
            }
            for profile in product.profiles {
                if let id = profile.checkoutID, !checkouts.contains(id) { problems.append("\(product.slug): profile \(profile.name) points at a missing checkout") }
                if let id = profile.environmentID, !environments.contains(id) { problems.append("\(product.slug): profile \(profile.name) points at a missing environment") }
            }
        }
        let productIDs = Set(portfolio.products.map(\.id))
        for variable in portfolio.variables {
            if let id = variable.scope.productID, !productIDs.contains(id) { problems.append("variable \(variable.key) is scoped to a missing product") }
            if variable.isSecret, variable.plainValue != nil { problems.append("secret variable \(variable.key) carries a plain value") }
        }
        return problems
    }

    /// Repairs dangling references instead of refusing to load.
    public static func repair(_ portfolio: Portfolio) -> Portfolio {
        var portfolio = portfolio
        var slugs = Set<String>()
        for index in portfolio.products.indices {
            var product = portfolio.products[index]
            if product.slug.isEmpty || slugs.contains(product.slug) { product.slug = Slug.unique(product.name, taken: slugs) }
            slugs.insert(product.slug)
            let components = Set(product.components.map(\.id))
            let repos = Set(product.repositories.map(\.id))
            let checkouts = Set(product.checkouts.map(\.id))
            let environments = Set(product.environments.map(\.id))
            for i in product.repositories.indices where !components.contains(product.repositories[i].componentID ?? UUID()) { product.repositories[i].componentID = nil }
            for i in product.checkouts.indices {
                if !repos.contains(product.checkouts[i].repositoryID ?? UUID()) { product.checkouts[i].repositoryID = nil }
                if !components.contains(product.checkouts[i].componentID ?? UUID()) { product.checkouts[i].componentID = nil }
            }
            for i in product.recipes.indices {
                if !checkouts.contains(product.recipes[i].checkoutID ?? UUID()) { product.recipes[i].checkoutID = nil }
                if !environments.contains(product.recipes[i].environmentID ?? UUID()) { product.recipes[i].environmentID = nil }
            }
            product.installLinks.removeAll { link in link.checkoutID.map { !checkouts.contains($0) } ?? true }
            for i in product.profiles.indices {
                if !checkouts.contains(product.profiles[i].checkoutID ?? UUID()) { product.profiles[i].checkoutID = nil }
                if !environments.contains(product.profiles[i].environmentID ?? UUID()) { product.profiles[i].environmentID = nil }
            }
            portfolio.products[index] = product
        }
        let productIDs = Set(portfolio.products.map(\.id))
        for index in portfolio.products.indices {
            let own = portfolio.products[index].id
            portfolio.products[index].contextLinks.removeAll { !productIDs.contains($0.productID) || $0.productID == own }
        }
        portfolio.variables.removeAll { $0.scope.productID.map { !productIDs.contains($0) } ?? false }
        for index in portfolio.variables.indices where portfolio.variables[index].isSecret { portfolio.variables[index].plainValue = nil }
        return portfolio
    }
}

public struct PortfolioStore: Sendable {
    public let location: StoreLocation

    public init(location: StoreLocation = .resolve()) { self.location = location }

    public func loadPortfolio() throws -> Portfolio {
        guard let data = FileManager.default.contents(atPath: location.portfolioURL.path) else { return Portfolio() }
        let migrated: Data
        do { migrated = try PortfolioMigrator.migrate(data) } catch let error as StoreError { throw error } catch {
            throw StoreError.corrupt(error.localizedDescription)
        }
        do {
            return IntegrityChecker.repair(try JSONCoding.decoder().decode(Portfolio.self, from: migrated))
        } catch {
            throw StoreError.corrupt(String(describing: error))
        }
    }

    public func save(_ portfolio: Portfolio) throws {
        try location.prepare()
        var portfolio = portfolio
        portfolio.schemaVersion = Portfolio.currentSchemaVersion
        try write(JSONCoding.encoder().encode(portfolio), to: location.portfolioURL)
    }

    public func loadCache() -> ObservationCache {
        guard let data = FileManager.default.contents(atPath: location.cacheURL.path),
              let cache = try? JSONCoding.decoder().decode(ObservationCache.self, from: data) else { return ObservationCache() }
        return cache
    }

    public func save(_ cache: ObservationCache) throws {
        try location.prepare()
        try write(JSONCoding.encoder(pretty: false).encode(cache), to: location.cacheURL)
    }

    public func clearCache() throws {
        if FileManager.default.fileExists(atPath: location.cacheURL.path) {
            try FileManager.default.removeItem(at: location.cacheURL)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: Safe export and import

/// A versioned configuration export. Credentials become placeholders: the reference
/// survives, the secret does not, and bookmarks (machine-specific) are dropped.
public struct PortfolioExport: Codable, Sendable {
    public static let format = "forgedeck-export"
    public var format = PortfolioExport.format
    public var exportVersion = 1
    public var exportedAt = Date.now
    public var portfolio = Portfolio()
    public var credentialPlaceholders: [String] = []
    public init() {}
}

public enum PortfolioExporter {
    public static func export(_ portfolio: Portfolio, includeDemo: Bool = false) throws -> Data {
        var out = PortfolioExport()
        var copy = portfolio
        if !includeDemo {
            copy.products.removeAll(where: \.isDemo)
            let kept = Set(copy.products.map(\.id))
            copy.variables.removeAll { $0.scope.productID.map { !kept.contains($0) } ?? false }
        }
        for p in copy.products.indices {
            for c in copy.products[p].checkouts.indices { copy.products[p].checkouts[c].bookmark = nil }
        }
        // A value that someone marked nonsecret but that looks like a token is withheld too.
        for index in copy.variables.indices {
            if copy.variables[index].isSecret {
                copy.variables[index].plainValue = nil
                out.credentialPlaceholders.append(copy.variables[index].key)
            } else if let value = copy.variables[index].plainValue, Redactor.looksLikeSecret(value) {
                copy.variables[index].plainValue = nil
                out.credentialPlaceholders.append(copy.variables[index].key)
            }
        }
        for connection in copy.connections where connection.credential != nil {
            out.credentialPlaceholders.append("connection:\(connection.displayName)")
        }
        out.portfolio = copy
        return try JSONCoding.encoder().encode(out)
    }

    public struct ImportReport: Sendable, Equatable {
        public var productsAdded = 0
        public var productsSkipped = 0
        public var variablesAdded = 0
        public var credentialsToReenter: [String] = []
    }

    /// Validates an export file and returns its portfolio.
    public static func validate(_ data: Data) throws -> PortfolioExport {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["format"] as? String == PortfolioExport.format else {
            throw StoreError.corrupt("not a \(Brand.name) export file")
        }
        guard let version = json["exportVersion"] as? Int, version <= 1 else {
            throw StoreError.corrupt("export version is newer than this build")
        }
        guard let inner = json["portfolio"] else { throw StoreError.corrupt("export has no portfolio") }
        let migrated = try PortfolioMigrator.migrate(JSONSerialization.data(withJSONObject: inner))
        var export = PortfolioExport()
        do {
            export.portfolio = try JSONCoding.decoder().decode(Portfolio.self, from: migrated)
        } catch {
            throw StoreError.corrupt(String(describing: error))
        }
        export.credentialPlaceholders = json["credentialPlaceholders"] as? [String] ?? []
        let problems = IntegrityChecker.problems(in: export.portfolio)
        guard problems.isEmpty else { throw StoreError.integrity(problems) }
        return export
    }

    /// Merges an export into a portfolio. Products that already exist (same id or slug) are kept as they are.
    public static func merge(_ export: PortfolioExport, into portfolio: inout Portfolio) -> ImportReport {
        var report = ImportReport()
        for product in export.portfolio.products {
            if portfolio.products.contains(where: { $0.id == product.id || $0.slug == product.slug }) {
                report.productsSkipped += 1
            } else {
                portfolio.products.append(product)
                report.productsAdded += 1
            }
        }
        for variable in export.portfolio.variables where !portfolio.variables.contains(where: { $0.id == variable.id }) {
            if let productID = variable.scope.productID, portfolio.product(id: productID) == nil { continue }
            portfolio.variables.append(variable)
            report.variablesAdded += 1
        }
        for connection in export.portfolio.connections where !portfolio.connections.contains(where: { $0.id == connection.id }) {
            portfolio.connections.append(connection)
        }
        report.credentialsToReenter = export.credentialPlaceholders
        return report
    }
}

// MARK: Audit

public struct AuditEvent: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var at = Date.now
    /// "app" or "cli"
    public var actor = "app"
    public var action = ""
    public var product: String?
    public var environment: String?
    /// Names and counts only. Passed through the redactor before it is written.
    public var detail = ""
    public var outcome = "ok"
    public init() {}
    public init(actor: String, action: String, product: String? = nil, environment: String? = nil, detail: String = "", outcome: String = "ok") {
        self.actor = actor; self.action = action; self.product = product
        self.environment = environment; self.detail = detail; self.outcome = outcome
    }
}

public protocol AuditSink: Sendable {
    func record(_ event: AuditEvent)
}

public struct AuditLog: AuditSink, Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public init(location: StoreLocation = .resolve()) { url = location.auditURL }

    public func record(_ event: AuditEvent) {
        var event = event
        event.detail = Redactor().redact(event.detail)
        guard var line = try? JSONCoding.encoder(pretty: false).encode(event) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    public func read(limit: Int = 500) -> [AuditEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONCoding.decoder()
        return text.split(separator: "\n").suffix(limit).compactMap {
            try? decoder.decode(AuditEvent.self, from: Data($0.utf8))
        }.reversed()
    }
}

public final class MemoryAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AuditEvent] = []
    public init() {}
    public func record(_ event: AuditEvent) { lock.withLock { stored.append(event) } }
    public var events: [AuditEvent] { lock.withLock { stored } }
}
