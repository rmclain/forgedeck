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
