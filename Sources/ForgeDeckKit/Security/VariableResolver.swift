import Foundation

// Variable resolution. Precedence, lowest to highest:
//   Global < Organization < Product < Component < Environment < Profile
// The winner is the highest scope whose tier list allows the target environment.
// A secret that is not allowed in the target tier is Blocked, never silently inherited:
// a production secret cannot reach a development session.

public struct ResolutionContext: Sendable {
    public var product: Product
    public var environment: ProductEnvironment
    public var componentID: UUID?
    public var profile: TerminalProfile?
    /// Keys the profile or recipe may receive. nil means every key in scope (preview only).
    public var allowlist: Set<String>?

    public init(product: Product, environment: ProductEnvironment, componentID: UUID? = nil,
                profile: TerminalProfile? = nil, allowlist: Set<String>? = nil) {
        self.product = product
        self.environment = environment
        self.componentID = componentID
        self.profile = profile
        self.allowlist = allowlist
    }
}

public enum ResolutionState: String, Sendable, Codable {
    /// The value comes from a wider scope.
    case inherited
    /// A narrower scope replaced a wider one.
    case overridden
    /// Defined directly at the environment or profile.
    case direct
    /// Required, and nothing in scope defines it.
    case missing
    /// The credential is past its expiry.
    case expired
    /// Defined, but not allowed in this environment tier.
    case blocked
    /// Defined and allowed, but the profile does not list it.
    case notGranted

    public var title: String {
        switch self {
        case .inherited: "Inherited"
        case .overridden: "Overridden"
        case .direct: "Direct"
        case .missing: "Missing"
        case .expired: "Expired"
        case .blocked: "Blocked"
        case .notGranted: "Not granted"
        }
    }

    public var delivers: Bool { self == .inherited || self == .overridden || self == .direct }
}

public struct ResolvedVariable: Sendable, Identifiable, Hashable {
    public var id: String { key }
    public var key: String
    public var state: ResolutionState
    public var winner: VariableDefinition?
    /// Definitions the winner replaced, widest first.
    public var shadowed: [VariableDefinition]
    public var isSecret: Bool
    public var note: String
}

public enum VariableResolver {
    static func applies(_ scope: VariableScope, to context: ResolutionContext) -> Bool {
        switch scope {
        case .global: true
        case .organization(let id): context.product.organizationID == id
        case .product(let id): context.product.id == id
        case .component(let product, let component): context.product.id == product && context.componentID == component
        case .environment(let product, let environment): context.product.id == product && context.environment.id == environment
        case .profile(let product, let profile): context.product.id == product && context.profile?.id == profile
        }
    }

    public static func resolve(_ variables: [VariableDefinition], context: ResolutionContext, now: Date = .now) -> [ResolvedVariable] {
        let inScope = variables.filter { applies($0.scope, to: context) }
        let tier = context.environment.tier
        var resolved: [ResolvedVariable] = []
        for (key, definitions) in Dictionary(grouping: inScope, by: \.key) {
            let ordered = definitions.sorted { $0.scope.precedence < $1.scope.precedence }
            let allowed = ordered.filter { $0.allowedTiers.contains(tier) }
            let isSecret = ordered.contains(where: \.isSecret)
            guard let winner = allowed.last else {
                // Defined somewhere in scope, but for other tiers only.
                let tiers = Set(ordered.flatMap(\.allowedTiers)).map(\.title).sorted().joined(separator: ", ")
                resolved.append(ResolvedVariable(key: key, state: .blocked, winner: nil, shadowed: ordered, isSecret: isSecret,
                                                 note: "Allowed only in \(tiers.isEmpty ? "no environment" : tiers)."))
                continue
            }
            let shadowed = allowed.dropLast()
            var state: ResolutionState
            if !shadowed.isEmpty {
                state = .overridden
            } else if winner.scope.precedence >= VariableScope.environment(product: UUID(), environment: UUID()).precedence {
                state = .direct
            } else {
                state = .inherited
            }
            var note = "\(winner.scope.title) scope"
            if !shadowed.isEmpty { note += ", replaces \(shadowed.map(\.scope.title).joined(separator: ", "))" }
            if winner.credential?.isExpired(now: now) == true {
                state = .expired
                note = "The credential expired."
            } else if let allowlist = context.allowlist, !allowlist.contains(key) {
                state = .notGranted
                note = "The profile does not list this variable."
            }
            resolved.append(ResolvedVariable(key: key, state: state, winner: winner, shadowed: Array(shadowed), isSecret: winner.isSecret, note: note))
        }
        // Keys the profile asks for that nothing defines.
        for key in context.allowlist ?? [] where !resolved.contains(where: { $0.key == key }) {
            resolved.append(ResolvedVariable(key: key, state: .missing, winner: nil, shadowed: [], isSecret: false,
                                             note: "Nothing in scope defines this variable."))
        }
        return resolved.sorted { $0.key < $1.key }
    }

    /// Definitions that warn the user: a secret that also resolves outside production
    /// while being used by a production environment, or a key defined twice at one scope.
    public static func warnings(_ variables: [VariableDefinition]) -> [String] {
        var warnings: [String] = []
        for (_, group) in Dictionary(grouping: variables, by: { "\($0.key)|\($0.scope)" }) where group.count > 1 {
            warnings.append("\(group[0].key) is defined \(group.count) times at \(group[0].scope.title) scope.")
        }
        for variable in variables where variable.isSecret && variable.allowedTiers.contains(.production) && variable.allowedTiers.count > 1 {
            warnings.append("\(variable.key) is a secret allowed in Production and in other environments. Split it into one secret per environment.")
        }
        return warnings.sorted()
    }

    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" }
    }
}
