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
