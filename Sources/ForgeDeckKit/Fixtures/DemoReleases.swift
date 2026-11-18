import Foundation

extension DemoFixtures {
    /// Demo release state for Lumen: its WordPress plugin is ahead of what WordPress.org publishes,
    /// and its readme's Stable tag lags the plugin header. Callers label it Demo.
    public static func releases(for product: Product, now: Date = .now) -> (local: LocalRelease, channels: [(ReleaseChannel, ReleaseObservation?)], githubTag: String?)? {
        guard product.isDemo, product.slug == "lumen" else { return nil }
        var local = LocalRelease()
        local.facts = [
            .init(source: .pluginHeader, file: "lumen-analytics.php", version: "1.4.0"),
            .init(source: .readmeStableTag, file: "readme.txt", version: "1.3.2"),
            .init(source: .packageJSON, file: "package.json", version: "1.4.0"),
        ]
        var channel = ReleaseChannel(kind: .wordpressOrg, package: "lumen-analytics")
        channel.id = UUID(uuidString: "6B0D5C1E-0000-4000-8000-00000000DE01") ?? UUID()
        local.suggestions = [channel, ReleaseChannel(kind: .npm, package: "@lumen-demo/sdk")]
        var observation = ReleaseObservation()
        observation.channelID = channel.id
        observation.productID = product.id
        observation.version = "1.3.2"
        observation.releasedAt = now.addingTimeInterval(-9 * 86_400)
        observation.detail = "WordPress.org publishes 1.3.2"
        observation.provenance = Provenance(observedAt: now.addingTimeInterval(-120), source: .fixture, level: .reported, ttl: 3_600, isDemo: true)
        return (local, [(channel, observation)], "v1.3.2")
    }
}

extension DemoFixtures {
    /// Demo `.forgedeck/environments.json` for Lumen: production gains a Version URL, and a preview site is new.
    public static func environmentProposals(for product: Product) -> [EnvironmentProposalFile] {
        guard product.isDemo, product.slug == "lumen", let checkout = product.checkouts.first else { return [] }
        return [EnvironmentProposalFile(checkoutID: checkout.id, checkoutName: checkout.name, entries: [
            ProposedEnvironment(name: "Production", tier: "production", domains: ["lumen.example"],
                                versionURL: "https://lumen.example/forgedeck-release.json",
                                note: "The deploy workflow writes forgedeck-release.json to the web root."),
            ProposedEnvironment(name: "Preview", tier: "preview", domains: ["preview.lumen.example"],
                                healthURL: "https://preview.lumen.example/health", note: "Pull requests deploy here."),
            ProposedEnvironment(name: "Old box", tier: "prod-ish", domains: ["https://old.lumen.example/"]),
        ])]
    }

    /// Demo `.forgedeck/run.json` for Lumen: a dev server, Docker, tests, and one command that is refused.
    public static func runProposals(for product: Product) -> [RunProposalFile] {
        guard product.isDemo, product.slug == "lumen", let checkout = product.checkouts.first else { return [] }
        return [RunProposalFile(checkoutID: checkout.id, checkoutName: checkout.name, checkoutPath: checkout.path, entries: [
            ProposedRun(label: "Start Dev Server", kind: "web", steps: [["npm", "install"], ["npm", "run", "dev"]], url: "http://localhost:5173",
                        note: "package.json dev script runs Vite; the README says npm install first."),
            ProposedRun(label: "Start with Docker", kind: "web", steps: [["docker", "compose", "up", "--build"]], url: "http://localhost:8080",
                        variables: ["DATABASE_URL"], note: "compose.yaml starts the app and Postgres."),
            ProposedRun(label: "Run Tests", steps: [["npm", "test"]], terminal: false, note: "Vitest, from package.json."),
            ProposedRun(label: "Deploy Preview", steps: [["npx", "vercel", "deploy"]]),
        ])]
    }

    /// Demo skill suggestions for Lumen. Made-up names; nothing installs.
    public static func skillSuggestions(for product: Product) -> [ProposedSkill] {
        guard product.isDemo, product.slug == "lumen" else { return [] }
        return [
            ProposedSkill(name: "demo-design-review", repo: "example/demo-skills", why: "Reviews the React screens for layout, contrast, and empty states."),
            ProposedSkill(name: "demo-vitest", plugin: "demo-vitest", marketplace: "example/demo-plugins",
                          why: "Writes and fixes Vitest tests; the repo uses Vitest.", includes: ["skills", "hooks"]),
        ]
    }
}

extension DemoFixtures {
    /// Lumen's Issues list: short notes, the way people write them, one already on GitHub, one done.
    public static func issues(now: Date = .now) -> [ProductIssue] {
        var exportBug = ProductIssue(title: "CSV export drops the last row", notes: "Seen on the Demo dashboard with 3+ filters.",
                                     createdAt: now.addingTimeInterval(-86_400 * 2))
        exportBug.githubNumber = 214
        exportBug.githubURL = "https://github.com/northwind-demo/lumen/issues/214"
        var started = ProductIssue(title: "dark mode for the embed widget", createdAt: now.addingTimeInterval(-86_400 * 5))
        started.startedAt = now.addingTimeInterval(-3_600 * 3)
        started.startedWith = "claude"
        var done = ProductIssue(title: "Rename \"Seats\" to \"Members\" in billing", isDone: true, createdAt: now.addingTimeInterval(-86_400 * 9))
        done.doneAt = now.addingTimeInterval(-86_400)
        return [ProductIssue(title: "onboarding email feels long", createdAt: now.addingTimeInterval(-3_600)), exportBug, started, done]
    }
}

extension DemoFixtures {
    /// A demo project setup record: an idea, planned by the agent, waiting for review. Callers label it Demo.
    public static func genesis(now: Date = .now) -> GenesisRecord {
        GenesisRecord(idea: "A SaaS app for managing customer subscriptions, with a web dashboard, PostgreSQL, Stripe billing, and a production deployment.",
                      usesAgent: true, phase: .planning, createdAt: now.addingTimeInterval(-600))
    }

    /// The demo blueprint for a demo product with a setup record. Made-up plan; nothing is built.
    public static func blueprint(for product: Product) -> BlueprintFile? {
        guard product.isDemo, product.genesis != nil else { return nil }
        let approved = product.genesis?.approvedStack != nil
        let blueprint = Blueprint(
            summary: "A multi-tenant web app where small businesses manage customer subscriptions: plans, invoices, and churn. A Next.js dashboard and API on one deployment, PostgreSQL for data, and Stripe for billing and webhooks.",
            stack: .init(name: "Next.js + PostgreSQL + Stripe",
                         why: "One TypeScript codebase for the dashboard and the API routes Stripe webhooks need. Postgres fits relational billing data. Node 22 and Docker are already on this Mac.",
                         parts: ["Next.js", "TypeScript", "PostgreSQL", "Prisma", "Stripe", "Auth.js"]),
            alternatives: [.init(name: "Remix + PostgreSQL", why: "Similar shape with simpler data loading; a smaller ecosystem for billing examples.", parts: ["Remix", "PostgreSQL"]),
                           .init(name: "Django + HTMX", why: "Choose it if the team prefers Python and server-rendered pages.", parts: ["Django", "HTMX", "PostgreSQL"])],
            structure: [.init(path: "app/", purpose: "dashboard pages and API routes"), .init(path: "app/api/stripe/", purpose: "webhook handler"),
                        .init(path: "prisma/", purpose: "schema and migrations"), .init(path: "tests/", purpose: "Vitest and Playwright")],
            tools: [.init(name: "node", why: "runs Next.js", installed: true), .init(name: "docker", why: "local Postgres", installed: true),
                    .init(name: "stripe", why: "forwards webhooks locally", installed: false)],
            steps: [.init(title: "Generate the app with create-next-app", status: approved ? "done" : "pending", detail: approved ? "Next.js 15, TypeScript, App Router" : nil),
                    .init(title: "Add Prisma and a Postgres compose service", status: approved ? "done" : "pending"),
                    .init(title: "Add Auth.js sign-in", status: approved ? "running" : "pending"),
                    .init(title: "Add Stripe checkout and the webhook route", status: "pending"),
                    .init(title: "Add /api/version and /api/health", status: "pending"),
                    .init(title: "Run the build and tests", status: "pending")],
            production: .init(host: "Vercel", domain: "app.subscriptiondesk.example", staging: true, versionPath: "/api/version", healthPath: "/api/health",
                              companion: "node", note: "Vercel builds Next.js without configuration; Neon for Postgres."),
            variables: [.init(name: "DATABASE_URL", why: "Postgres connection", secret: true, environments: ["development", "staging", "production"]),
                        .init(name: "STRIPE_SECRET_KEY", why: "server-side Stripe calls", secret: true, environments: ["development", "production"]),
                        .init(name: "STRIPE_WEBHOOK_SECRET", why: "verifies webhook signatures", secret: true, environments: ["production"]),
                        .init(name: "AUTH_SECRET", why: "signs sessions", secret: true)],
            questions: ["Do customers sign in themselves, or only your staff?"])
        let (problems, warnings) = BlueprintCheck.check(blueprint)
        return BlueprintFile(blueprint: blueprint, problems: problems, warnings: warnings)
    }
}
