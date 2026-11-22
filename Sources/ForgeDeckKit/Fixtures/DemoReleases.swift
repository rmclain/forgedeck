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
        guard product.isDemo else { return [] }
        if product.slug == "orbit-crm" {
            return [
                ProposedSkill(name: "demo-nextjs", repo: "example/demo-skills", why: "App Router conventions, server actions, and route handlers."),
                ProposedSkill(name: "demo-stripe", repo: "example/demo-skills", why: "Checkout, subscriptions, and verifying webhook signatures."),
                ProposedSkill(name: "demo-playwright", plugin: "demo-playwright", marketplace: "example/demo-plugins",
                              why: "Writes and runs the end-to-end tests.", includes: ["skills"]),
            ]
        }
        guard product.slug == "lumen" else { return [] }
        return [
            ProposedSkill(name: "demo-design-review", repo: "example/demo-skills", why: "Reviews the React screens for layout, contrast, and empty states."),
            ProposedSkill(name: "demo-vitest", plugin: "demo-vitest", marketplace: "example/demo-plugins",
                          why: "Writes and fixes Vitest tests; the repo uses Vitest.", includes: ["skills", "hooks"]),
        ]
    }
}

extension DemoFixtures {
    /// Lumen's Issues list: short notes, the way people write them, one already on GitHub, one done.
    /// Lumen's Memory tab: rules from the person and facts an agent saved.
    public static func memory(now: Date = .now) -> [MemoryNote] {
        [MemoryNote(text: "Run the tests with make test; it starts the local database first.", kind: .rule, createdAt: now.addingTimeInterval(-86_400 * 12)),
         MemoryNote(text: "Never change the public embed API without bumping its version in embed/VERSION.", kind: .rule,
                    createdAt: now.addingTimeInterval(-86_400 * 6), addedBy: "claude"),
         MemoryNote(text: "Billing webhooks arrive at /api/stripe; the handler retries, so it must stay idempotent.", kind: .note,
                    createdAt: now.addingTimeInterval(-86_400 * 3), addedBy: "claude"),
         MemoryNote(text: "The dashboard charts come from the reports service, not the main database.", kind: .note, createdAt: now.addingTimeInterval(-3_600 * 5))]
    }

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
        done.doneBy = "claude"
        done.doneSummary = "Billing pages, emails, and the plan table now say Members; tests updated."
        done.githubNumber = 296
        done.githubURL = "https://github.com/northwind-demo/lumen/issues/296"
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
                         parts: ["Next.js 15 App Router", "TypeScript", "PostgreSQL 17", "Prisma ORM", "Stripe Billing", "Auth.js", "Vitest", "Playwright end-to-end tests"]),
            alternatives: [.init(name: "Remix + PostgreSQL", why: "Similar shape with simpler data loading; a smaller ecosystem for billing examples.", parts: ["Remix", "PostgreSQL"]),
                           .init(name: "Django + HTMX", why: "Choose it if the team prefers Python and server-rendered pages.", parts: ["Django", "HTMX", "PostgreSQL"])],
            structure: [.init(path: "app/", purpose: "dashboard pages and API routes"), .init(path: "app/api/stripe/webhooks/handlers/", purpose: "webhook handler, one file per Stripe event type"),
                        .init(path: "prisma/", purpose: "schema and migrations"), .init(path: "tests/", purpose: "Vitest and Playwright")],
            tools: [.init(name: "node", why: "runs Next.js", installed: true), .init(name: "docker", why: "local Postgres", installed: true),
                    .init(name: "stripe", why: "forwards webhooks to the local server so checkout and subscription events can be tested without deploying", installed: false)],
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

extension DemoFixtures {
    /// Lumen's plans: one ready to review, made from the dark-mode issue, and one finished.
    public static func plans(issues: [ProductIssue], now: Date = .now) -> [FeaturePlan] {
        var ready = FeaturePlan(request: "dark mode for the embed widget", issueID: issues.first { $0.title.hasPrefix("dark mode") }?.id,
                                createdAt: now.addingTimeInterval(-3_600 * 3))
        ready.startedWith = "claude"
        ready.phase = .ready
        ready.title = "Dark mode for the embed widget"
        ready.summary = "The widget reads the host page's color scheme, with a data-theme attribute to force light or dark. "
            + "Colors move to CSS variables so both themes share one stylesheet."
        ready.steps = [
            .init(id: "1", title: "Move widget colors to CSS variables", detail: "Replace the 14 hard-coded colors in widget.css; no visual change in light mode.",
                  files: ["packages/embed/src/widget.css"]),
            .init(id: "2", title: "Add the dark palette", detail: "A prefers-color-scheme block with contrast checked against WCAG AA.",
                  files: ["packages/embed/src/theme.css"]),
            .init(id: "3", title: "Support data-theme=\"light|dark|auto\"", detail: "Read the attribute on mount; auto follows the host page.",
                  files: ["packages/embed/src/mount.ts", "packages/embed/README.md"]),
            .init(id: "4", title: "Theme switcher in the dashboard's embed settings", detail: "A three-way picker that updates the snippet.",
                  files: ["apps/web/app/settings/embed/page.tsx"], optional: true),
            .init(id: "5", title: "Visual tests for both themes", detail: "Playwright screenshots of the widget in light and dark.",
                  files: ["packages/embed/tests/theme.spec.ts"]),
        ]
        ready.questions = ["Should auto follow the host page or the visitor's system setting when they differ?"]
        ready.risks = ["Customers who override widget colors with !important may see mixed themes."]

        var done = FeaturePlan(request: "Rename Seats to Members in billing", createdAt: now.addingTimeInterval(-86_400 * 3))
        done.startedWith = "claude"
        done.title = "Rename Seats to Members"
        done.steps = [.init(id: "1", title: "Rename in the billing UI"), .init(id: "2", title: "Rename in emails"), .init(id: "3", title: "Update tests")]
        for index in done.steps.indices { done.steps[index].doneAt = now.addingTimeInterval(-86_400) }
        done.phase = .done
        done.executedAt = now.addingTimeInterval(-86_400 * 2)
        done.doneAt = now.addingTimeInterval(-86_400)
        return [ready, done]
    }
}
