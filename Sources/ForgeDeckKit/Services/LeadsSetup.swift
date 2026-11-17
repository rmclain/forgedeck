import CryptoKit
import Foundation

// Leads setup: ForgeDeck makes the access token (kept in the Keychain, only its SHA-256 goes to the product), then the
// agent wires the product's real lead sources into the companion contract and proposes the metrics source back.
// `forgedeck leads <product>` shows what arrived, so the agent can confirm leads are coming in.

public enum LeadsSetup {
    /// What ForgeDeck reads. Never events:read or anything that writes.
    public static let scopes = ["status:read", "metrics:read", "leads:read"]
    public static let contractURL = "https://github.com/rmclain/forgedeck/tree/main/Companions"

    /// The variable that holds the token for one environment, like FORGEDECK_TOKEN_PRODUCTION.
    public static func tokenVariable(for tier: EnvironmentTier) -> String { "FORGEDECK_TOKEN_" + tier.rawValue.uppercased() }

    /// 256 random bits, `fdk_` and base64url, like the companion packages make.
    public static func generateToken() -> String {
        let key = SymmetricKey(size: .bits256)
        let text = key.withUnsafeBytes { Data($0) }.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "fdk_" + text
    }

    /// The SHA-256 hex the server stores. Not a secret: it cannot be used as the token.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Where leads are most useful: production, then staging, then the local environment.
    public static func target(in product: Product) -> ProductEnvironment? {
        product.environment(tier: .production) ?? product.environment(tier: .staging) ?? product.environment(tier: .development) ?? product.environments.first
    }

    // MARK: The prompt

    public static func prompt(for product: Product, environment: ProductEnvironment, checkout: LocalCheckout, tokenVariable: String,
                              tokenHash: String?, cli: String, localSite: LocalSite?) -> String {
        let tool = cli.contains(" ") ? "\"\(cli)\"" : cli
        var facts = ["- Product: \(product.name) (`\(product.slug)`)\(product.tagline.isEmpty ? "" : ": \(product.tagline)")",
                     "- Folder: \(checkout.path)",
                     "- Environment for leads: \(environment.name) (\(environment.tier.title))\(environment.domains.isEmpty ? "" : " at " + environment.domains.joined(separator: ", "))"]
        if !product.stack.isEmpty { facts.append("- Stack: " + product.stack.joined(separator: ", ")) }
        let hints = RunSetup.hints(for: checkout)
        if !hints.isEmpty { facts.append("- Files at the top: " + hints.joined(separator: ", ")) }
        if let localSite { facts.append("- Runs inside the Local site \(localSite.name) at \(localSite.url(admin: false))") }
        let sources = product.environments.flatMap { env in env.metricSources.map { "\($0.baseURL) (\(env.name)\($0.leadsEnabled ? ", leads on" : ", leads off"))" } }
        facts.append(sources.isEmpty ? "- Metrics sources in \(Brand.name): none yet" : "- Metrics sources in \(Brand.name): " + sources.joined(separator: "; "))
        let token: String
        if let tokenHash {
            token = """
            \(Brand.name) made a new token and keeps it in the Keychain as \(tokenVariable). You never see it. The server stores only its SHA-256:
               \(tokenHash)
               Scopes: \(scopes.joined(separator: ", ")). Put the hash in the server's config or secret settings for \(environment.name) \
            (an environment variable such as FORGEDECK_TOKEN_SHA256, or a wp-config.php constant). It is not a secret, but keep it out of the repository.
            """
        } else {
            token = """
            \(Brand.name) already has a token in \(tokenVariable). If the server does not have its hash, ask me to choose New Token in \
            Set Up Leads and start again; never ask me for the token itself.
            """
        }
        return """
        Help me see \(product.name)'s leads, signups, and purchases in \(Brand.name). Start by looking, not building.

        What \(Brand.name) knows:
        \(facts.joined(separator: "\n"))

        ## Step 1: find what this product collects (change nothing)

        Read the code, config, and installed plugins or packages. Look for each of these:
        - Leads: contact, quote, demo, or inquiry forms. WordPress: Gravity Forms, Contact Form 7, WPForms, Fluent Forms, Formidable, \
        Ninja Forms, Elementor forms, or the theme's or plugin's own forms and tables. Apps: form handlers and API routes, and calls to \
        HubSpot, Mailchimp, ConvertKit, or a CRM.
        - Signups and trials: user registration, auth provider sign-ups, trial starts, waitlists, newsletter opt-ins.
        - Purchases: WooCommerce or Easy Digital Downloads orders, Stripe Checkout or webhooks, Paddle, Lemon Squeezy, Shopify, \
        paid registrations or tickets.
        - Renewals and cancellations: subscriptions (WooCommerce Subscriptions, Stripe subscriptions, memberships).
        - Bookings and registrations: appointments, events, courses. A free one counts as a lead, a paid one as a purchase.

        Then tell me in a short table: what it is, where it lives in the code, where each one is stored (its own table, a plugin's \
        table, or only emailed or sent to another service), and what it would count as: lead, signup, paid_conversion, renewal, or \
        cancellation. Something that is only emailed and never stored cannot be counted until it is saved; say so.

        ## Step 2: ask me

        Ask which of these I want \(Brand.name) to see, and whether to set up the check now. Stop and wait for my answer.

        ## Step 3: set up the check (only after I say yes)

        \(Brand.name) reads them through a small read-only API, the companion contract (\(contractURL)):
        - GET /_forgedeck/v1/manifest, /status, /metrics?window=24h|7d|30d, and /leads?cursor=&limit=, with `Authorization: Bearer <token>`.
        - /metrics returns {"schema_version": "1.0", "product_id": "\(product.slug)", "environment": "\(environment.tier.rawValue)", "window": "24h", \
        "metrics": {"leads": 12, "signups": 9, "paid_conversions": 2}}. Counters: leads, signups, paid_conversions, renewals, \
        cancellations, and mrr_cents for revenue.
        - /leads returns {"schema_version": "1.0", "items": [{"id": "evt_123", "kind": "lead", "occurred_at": "2026-11-15T14:05:00Z", \
        "source": "contact_form", "title": "New lead"}], "next_cursor": null}. value_cents is allowed on purchases. Never send names, \
        emails, phone numbers, or messages: ids, kinds, times, a source name, and an amount only.
        - No token configured: 503. Wrong token: 401. HTTPS except on localhost. GET only. Compare token hashes in constant time.
        - Ready-made packages: Node and Express, Python and FastAPI, and a WordPress plugin, in the Companions folder at that link. \
        For a WordPress plugin you own, adding the routes to it is often simpler than a second plugin.

        \(token)

        1. Add the companion in the product's own code, in a change I review: copy the matching package or implement the routes above. \
        Turn on status, metrics, and leads only. Count from the real stored data for the ones I chose; never invent numbers. If the \
        product already has a companion, connect the missing sources to it.
        2. Test it locally: request /manifest, /metrics?window=24h, and /leads with a local test token, make one test lead or order, \
        and check that it appears.
        3. Propose the metrics source in `.forgedeck/environments.json` in the folder, on the \(environment.name) entry (tier \
        "\(environment.tier.rawValue)"): "metricsURL": the site root or the URL ending in /_forgedeck/v1, and "metricsToken": \
        "\(tokenVariable)". Keep everything else the file has. Run `\(tool) env check \(product.slug)` and fix every problem.
        4. Don't deploy, push, or publish unless I ask. Once it is live, I press Review… on Proposed environments in \(Brand.name).
        5. Then run `\(tool) leads \(product.slug)` to confirm \(Brand.name) is receiving them. 401 means the hash on the server does not \
        match \(tokenVariable). No leads yet means nothing new happened since: make a test lead on the live site if I agree.
        """
    }

    // MARK: What arrived

    public struct SourceReport: Codable, Sendable, Equatable {
        public var name: String
        public var environment: String
        public var url: String
        public var leadsEnabled: Bool
        public var lastChecked: Date?
        public var lastSuccess: Date?
        public var problem: String?
        public var leads24h: Int
        public var leads7d: Int
        public var newestLead: Date?
        public var newestKind: String?
        /// The source's 24-hour counters, as it reported them.
        public var counters: [String: Double]
    }

    public static func report(for product: Product, cache: ObservationCache, now: Date = .now) -> [SourceReport] {
        product.environments.flatMap { environment in
            environment.metricSources.map { source in
                let metrics = cache.sync["metrics:\(source.id.uuidString)"]
                let leads = cache.sync["leads:\(source.id.uuidString)"]
                let events = cache.leads.filter { $0.sourceID == source.id && !$0.isDemo }
                let newest = events.max { $0.occurredAt < $1.occurredAt }
                var counters: [String: Double] = [:]
                for sample in cache.metrics where sample.sourceID == source.id && sample.window == "24h" { counters[sample.key] = sample.value }
                let attempts = [metrics?.lastAttempt, source.leadsEnabled ? leads?.lastAttempt : nil].compactMap { $0 }
                let successes = [metrics?.lastSuccess, source.leadsEnabled ? leads?.lastSuccess : nil].compactMap { $0 }
                let problem = metrics?.lastProblem ?? (source.leadsEnabled ? leads?.lastProblem : nil)
                return SourceReport(name: source.name.isEmpty ? "Companion" : source.name, environment: environment.name, url: source.baseURL,
                                    leadsEnabled: source.leadsEnabled, lastChecked: attempts.max(), lastSuccess: successes.max(),
                                    problem: problem?.title,
                                    leads24h: events.filter { now.timeIntervalSince($0.occurredAt) < 86_400 }.count,
                                    leads7d: events.filter { now.timeIntervalSince($0.occurredAt) < 7 * 86_400 }.count,
                                    newestLead: newest?.occurredAt, newestKind: newest?.kind.rawValue, counters: counters)
            }
        }
    }
}
