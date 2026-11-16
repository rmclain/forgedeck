import Foundation

// Scoped execution: start one approved program with only the variables its profile grants.
// Values are read just before launch and handed to the child through its environment,
// in memory. They are never written to a file, a command line, a log, or stdout.
//
// What this does not protect against: the child process and everything it starts can
// read its own environment. That is the point of giving it the value.

public enum ExecDenial: Error, CustomStringConvertible, Equatable {
    case unknownProduct(String)
    case unknownEnvironment(String)
    case unknownProfile(String)
    case profileEnvironmentMismatch(profile: String, environment: String)
    case executableNotAllowed(String, allowed: [String])
    case executableNotFound(String)
    case blocked([String])
    case missing([String])
    case productionNeedsConfirmation
    case authenticationFailed
    case archived(String)
    case secretUnavailable(key: String, reason: String)

    public var description: String {
        switch self {
        case .unknownProduct(let slug): "No product \"\(slug)\". Run `\(Brand.cliName) list`."
        case .unknownEnvironment(let name): "The product has no environment \"\(name)\"."
        case .unknownProfile(let name): "The product has no profile \"\(name)\". Run `\(Brand.cliName) env list <product>`."
        case .profileEnvironmentMismatch(let profile, let environment):
            "Profile \"\(profile)\" belongs to another environment, not \(environment)."
        case .executableNotAllowed(let name, let allowed):
            "The profile does not allow \"\(name)\". Allowed: \(allowed.isEmpty ? "nothing" : allowed.joined(separator: ", ")). Edit the profile in \(Brand.name)."
        case .executableNotFound(let name): "\(name) was not found on this Mac."
        case .blocked(let keys): "Denied: \(keys.joined(separator: ", ")) may not be used in this environment."
        case .missing(let keys): "Missing: \(keys.joined(separator: ", ")). Define them in \(Brand.name) first."
        case .productionNeedsConfirmation: "Production secrets need confirmation at this Mac. Run the command in a terminal you are sitting at."
        case .authenticationFailed: "Authentication was cancelled or failed. Nothing ran."
        case .archived(let name): "\(name) is archived. Actions are disabled."
        case .secretUnavailable(let key, let reason): "\(key): \(reason)"
        }
    }
}

public struct ExecRequest: Sendable {
    public var productSlug: String
    public var environmentName: String
    public var profileName: String
    public var command: [String]
    public var actor = "cli"

    public init(productSlug: String, environmentName: String, profileName: String, command: [String], actor: String = "cli") {
        self.productSlug = productSlug
        self.environmentName = environmentName
        self.profileName = profileName
        self.command = command
        self.actor = actor
    }
}

/// Everything needed to start the child. `secretValues` exists only in memory.
public struct ExecPlan: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    public var grantedKeys: [String]
    public var secretKeys: [String]
    public var environment: [String: String]
    public var secretValues: [String]
    public var product: Product
    public var environmentName: String
    public var isProduction: Bool
}

public struct ExecService: Sendable {
    public var credentials: CredentialResolver
    public var authorizer: any Authorizing
    public var audit: any AuditSink
    /// The environment the child starts from before granted variables are added.
    public var baseEnvironment: [String: String]

    public init(credentials: CredentialResolver = CredentialResolver(), authorizer: any Authorizing = DeviceOwnerAuthorizer(),
                audit: any AuditSink = AuditLog(), baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.credentials = credentials
        self.authorizer = authorizer
        self.audit = audit
        self.baseEnvironment = baseEnvironment
    }

    public static func environment(named name: String, in product: Product) -> ProductEnvironment? {
        let wanted = name.lowercased()
        return product.environments.first { $0.name.lowercased() == wanted }
            ?? product.environments.first { $0.tier.rawValue == wanted }
            ?? (wanted == "local" ? product.environment(tier: .development) : nil)
    }

    /// Applies every rule and reads the granted values. Throws without reading any secret when a rule fails.
    public func plan(_ request: ExecRequest, portfolio: Portfolio) async throws -> ExecPlan {
        func deny(_ denial: ExecDenial, product: Product? = nil) -> ExecDenial {
            audit.record(AuditEvent(actor: request.actor, action: "exec.denied", product: product?.slug ?? request.productSlug,
                                    environment: request.environmentName,
                                    detail: "profile=\(request.profileName) program=\(request.command.first.map { ($0 as NSString).lastPathComponent } ?? "") reason=\(denial.auditCode)",
                                    outcome: "denied"))
            return denial
        }
        guard let product = portfolio.product(slug: request.productSlug) else { throw deny(.unknownProduct(request.productSlug)) }
        guard !product.isArchived else { throw deny(.archived(product.name), product: product) }
        guard let environment = Self.environment(named: request.environmentName, in: product) else {
            throw deny(.unknownEnvironment(request.environmentName), product: product)
        }
        guard let profile = product.profiles.first(where: { $0.name.lowercased() == request.profileName.lowercased() }) else {
            throw deny(.unknownProfile(request.profileName), product: product)
        }
        // A profile made for development cannot be pointed at production by passing another flag.
        guard profile.environmentID == nil || profile.environmentID == environment.id else {
            throw deny(.profileEnvironmentMismatch(profile: profile.name, environment: environment.name), product: product)
        }
        guard let program = request.command.first, !program.isEmpty else { throw deny(.executableNotAllowed("", allowed: profile.allowedExecutables), product: product) }
        let programName = (program as NSString).lastPathComponent
        // A bare name only: a path would let a look-alike binary anywhere pass the allowlist.
        guard !program.contains("/"), profile.allowedExecutables.contains(program) else {
            throw deny(.executableNotAllowed(programName, allowed: profile.allowedExecutables), product: product)
        }
        // Found in fixed folders, never through the caller's PATH, which the caller controls.
        guard let executable = ExecutableLocator.find(program, environment: [:]) else {
            throw deny(.executableNotFound(programName), product: product)
        }

        let checkout = product.checkout(id: profile.checkoutID) ?? product.primaryCheckout
        let context = ResolutionContext(product: product, environment: environment, componentID: checkout?.componentID,
                                        profile: profile, allowlist: Set(profile.variableAllowlist))
        let resolved = VariableResolver.resolve(portfolio.variables, context: context)
            .filter { profile.variableAllowlist.contains($0.key) }
        let blocked = resolved.filter { $0.state == .blocked || $0.state == .expired }.map(\.key)
        guard blocked.isEmpty else { throw deny(.blocked(blocked), product: product) }
        let missing = resolved.filter { $0.state == .missing }.map(\.key)
        guard missing.isEmpty else { throw deny(.missing(missing), product: product) }

        let granted = resolved.filter(\.state.delivers)
        let secretKeys = granted.filter(\.isSecret).map(\.key)
        if environment.tier.isProduction, !secretKeys.isEmpty, portfolio.settings.requireAuthForProductionSecrets {
            let reason = "give \(programName) the production secrets \(secretKeys.joined(separator: ", ")) for \(product.name)"
            guard await authorizer.confirm(reason: reason) else { throw deny(.authenticationFailed, product: product) }
        }

        var env = baseEnvironment
        var secretValues: [String] = []
        for variable in granted {
            guard let definition = variable.winner else { continue }
            if definition.isSecret {
                guard let reference = definition.credential else {
                    throw deny(.secretUnavailable(key: variable.key, reason: "no credential is stored"), product: product)
                }
                do {
                    let value = try await credentials.value(for: reference)
                    env[variable.key] = value
                    secretValues.append(value)
                } catch {
                    throw deny(.secretUnavailable(key: variable.key, reason: String(describing: error)), product: product)
                }
            } else {
                env[variable.key] = definition.plainValue ?? ""
            }
        }
        env["FORGEDECK_PRODUCT"] = product.slug
        env["FORGEDECK_ENVIRONMENT"] = environment.tier.rawValue

        var directory: URL?
        if let checkout {
            let base = URL(fileURLWithPath: checkout.path, isDirectory: true)
            directory = profile.workingSubdirectory.isEmpty ? base : base.appending(path: profile.workingSubdirectory, directoryHint: .isDirectory)
        }
        audit.record(AuditEvent(actor: request.actor, action: "exec.granted", product: product.slug, environment: environment.name,
                                detail: "profile=\(profile.name) program=\(programName) variables=\(granted.map(\.key).joined(separator: ","))"))
        return ExecPlan(executable: executable, arguments: Array(request.command.dropFirst()), workingDirectory: directory,
                        grantedKeys: granted.map(\.key), secretKeys: secretKeys, environment: env, secretValues: secretValues,
                        product: product, environmentName: environment.name, isProduction: environment.tier.isProduction)
    }
}

extension ExecDenial {
    /// A short code for the audit log. It carries no names from the command line.
    var auditCode: String {
        switch self {
        case .unknownProduct: "unknown-product"
        case .unknownEnvironment: "unknown-environment"
        case .unknownProfile: "unknown-profile"
        case .profileEnvironmentMismatch: "profile-environment-mismatch"
        case .executableNotAllowed: "executable-not-allowed"
        case .executableNotFound: "executable-not-found"
        case .blocked(let keys): "blocked:\(keys.joined(separator: ","))"
        case .missing(let keys): "missing:\(keys.joined(separator: ","))"
        case .productionNeedsConfirmation: "production-needs-confirmation"
        case .authenticationFailed: "authentication-failed"
        case .archived: "archived"
        case .secretUnavailable(let key, _): "secret-unavailable:\(key)"
        }
    }
}
