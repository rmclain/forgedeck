import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ReleasesTests {
    private let sha = "0123456789abcdef0123456789abcdef01234567"

    @Test func aReleaseFileHeaderOrPlainLineNamesTheRelease() {
        let file = ReleaseMarker.read(body: Data(#"{"commit_sha":"\#(sha)","version":"1.8.2","built_at":"2026-11-14T12:21:07Z"}"#.utf8), headers: [:])
        #expect(file.sha == sha && file.version == "1.8.2" && file.deployedAt != nil)
        let nested = ReleaseMarker.read(body: Data(#"{"build":{"git":"x","commit":"ABCDEF1"},"release":{"version":"v2.0.0"}}"#.utf8), headers: [:])
        #expect(nested.sha == "abcdef1" && nested.version == "v2.0.0")
        // An HTML page names nothing in its body; the headers still count.
        let page = ReleaseMarker.read(body: Data("<!doctype html><html>".utf8), headers: ["x-release": "3.1.0", "x-commit-sha": sha])
        #expect(page.version == "3.1.0" && page.sha == sha)
        #expect(ReleaseMarker.read(body: Data("abc1234\n".utf8), headers: [:]).sha == "abc1234")
        #expect(ReleaseMarker.read(body: Data("1.2.3".utf8), headers: [:]).version == "1.2.3")
        // Junk is dropped, not shown.
        let junk = ReleaseMarker.read(body: Data(#"{"version":"<script>alert(1)</script>"}"#.utf8), headers: ["x-release": "a b c"])
        #expect(junk.version == nil && junk.sha == nil)
    }

    @Test func aVersionURLIsVerifiedWhenItNamesARelease() async {
        let http = MockHTTPClient()
        http.on("/forgedeck-release.json", json: #"{"commit_sha":"\#(sha)","version":"1.8.2"}"#)
        http.on("/", status: 200, json: "<html></html>")
        var probe = ProbeConfig()
        probe.kind = .release
        probe.url = "https://shop.example.com/forgedeck-release.json"
        let connector = HTTPProbeConnector(http: http)
        let outcome = await connector.status(probe, bearer: nil, expectedTier: .production)
        #expect(outcome.sample.ok)
        #expect(outcome.deployment?.sha == sha)
        #expect(outcome.deployment?.provenance.level == .verified)
        probe.url = "https://shop.example.com/"
        let bare = await connector.status(probe, bearer: nil, expectedTier: .production)
        #expect(bare.sample.ok)
        #expect(bare.deployment?.provenance.level == .unknown)
        #expect(bare.deployment?.detail.contains("forgedeck-release.json") == true)
    }

    @Test func aWordPressPluginCheckoutDeclaresItsVersions() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fd-release-\(UUID().uuidString)/acme-forms")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try """
        <?php
        /**
         * Plugin Name: Acme Forms
         * Version: 1.4.0
         * Text Domain: acme-forms
         */
        """.write(to: folder.appending(path: "acme-forms.php"), atomically: true, encoding: .utf8)
        try "=== Acme Forms ===\nStable tag: 1.3.2\nRequires at least: 6.0\n".write(to: folder.appending(path: "readme.txt"), atomically: true, encoding: .utf8)
        try #"{"name":"acme-forms-build","version":"1.4.0","private":true}"#.write(to: folder.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let local = LocalRelease.detect(in: folder.path)
        #expect(local.fact(.pluginHeader)?.version == "1.4.0")
        #expect(local.fact(.readmeStableTag)?.version == "1.3.2")
        #expect(local.fact(.packageJSON)?.version == "1.4.0")
        // A private package is never suggested for npm.
        #expect(local.suggestions == [ReleaseChannel(kind: .wordpressOrg, package: "acme-forms")].map { var c = $0; c.id = local.suggestions.first?.id ?? c.id; return c })
    }

    @Test func pyprojectNameAndVersionAreRead() {
        let table = LocalRelease.tomlTable("[build-system]\nrequires = [\"x\"]\n[project]\nname = \"acme-tool\"\nversion = \"0.9.1\"\n", names: ["project"])
        #expect(table["name"] == "acme-tool" && table["version"] == "0.9.1")
    }

    @Test func registriesAreAskedReadOnlyAndUnknownNamesAreNotFound() async {
        let http = MockHTTPClient()
        http.on("/plugins/info/1.2", json: #"{"name":"Acme Forms","version":"1.3.2","last_updated":"2026-11-01 3:12pm GMT"}"#)
        http.on("/acme-cli/latest", json: #"{"name":"acme-cli","version":"2.0.1"}"#)
        http.on("/pypi/acme-tool/json", json: #"{"info":{"version":"0.9.0"}}"#)
        let connector = ReleaseRegistryConnector(http: http)
        let wp = await connector.latest(ReleaseChannel(kind: .wordpressOrg, package: "acme-forms"), productID: UUID())
        #expect(wp.version == "1.3.2" && wp.releasedAt != nil && wp.provenance.level == .reported)
        #expect(await connector.latest(ReleaseChannel(kind: .npm, package: "acme-cli"), productID: UUID()).version == "2.0.1")
        #expect(await connector.latest(ReleaseChannel(kind: .pypi, package: "acme-tool"), productID: UUID()).version == "0.9.0")
        let missing = await connector.latest(ReleaseChannel(kind: .npm, package: "nobody-has-this"), productID: UUID())
        #expect(missing.problem == .notFound)
        // A bad name never reaches the network.
        let before = http.requests.count
        let bad = await connector.latest(ReleaseChannel(kind: .wordpressOrg, package: "../etc"), productID: UUID())
        #expect(bad.problem == .notConfigured && http.requests.count == before)
        #expect(http.requests.allSatisfy { $0.httpMethod == nil || $0.httpMethod == "GET" })
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func findingsSayWhatIsUnreleasedOrMismatched() {
        var local = LocalRelease()
        local.facts = [.init(source: .pluginHeader, file: "a.php", version: "1.4.0"), .init(source: .readmeStableTag, file: "readme.txt", version: "1.3.2")]
        let channel = ReleaseChannel(kind: .wordpressOrg, package: "acme-forms")
        var published = ReleaseObservation()
        published.version = "1.3.2"
        let findings = ReleaseCheck.findings(local: local, channels: [(channel, published)], githubTag: "v1.4.0")
        #expect(findings.count == 3)
        #expect(findings[0].text.contains("Stable tag 1.3.2") && findings[0].tone == .warn)
        #expect(findings[1].text.contains("Not released yet") && findings[1].tone == .warn)
        #expect(findings[2].tone == .ok)
        #expect(ReleaseCheck.compare("v1.10.0", "1.9.9") == .orderedDescending)
        #expect(ReleaseCheck.compare("1.2.0-beta.1", "1.2.0") == .orderedAscending)
        #expect(ReleaseCheck.compare("2.0", "2.0.0") == .orderedSame)
    }

    @Test func aFailedLookupKeepsTheLastVersionAndANewOneIsAnnounced() {
        var product = Product(name: "Acme Forms")
        let channel = ReleaseChannel(kind: .wordpressOrg, package: "acme-forms")
        product.releaseChannels = [channel]
        var portfolio = Portfolio()
        portfolio.products = [product]
        var cache = ObservationCache()
        func observation(_ version: String?, problem: ObservationProblem? = nil) -> ReleaseObservation {
            var o = ReleaseObservation()
            o.channelID = channel.id
            o.productID = product.id
            o.version = version
            o.problem = problem
            o.provenance = Provenance(source: .packageRegistry, level: version == nil ? .unknown : .reported)
            return o
        }
        cache.apply([.release(observation("1.3.2"))], portfolio: portfolio)
        cache.apply([.release(observation(nil, problem: .offline))], portfolio: portfolio)
        #expect(cache.releases?[channel.id]?.version == "1.3.2")
        #expect(cache.activity.isEmpty)
        cache.apply([.release(observation("1.4.0"))], portfolio: portfolio)
        #expect(cache.activity.first?.title == "WordPress.org published 1.4.0")
    }

    @Test func anOlderCacheFileWithoutReleasesStillLoads() throws {
        let data = try JSONEncoder().encode(ObservationCache())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "releases")
        let decoded = try JSONDecoder().decode(ObservationCache.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.releases == nil)
        var productJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Product(name: "Old"))) as? [String: Any])
        productJSON.removeValue(forKey: "releaseChannels")
        #expect(try JSONDecoder().decode(Product.self, from: JSONSerialization.data(withJSONObject: productJSON)).releaseChannels == nil)
    }

    @Test func theAgentLearnsVariableNamesAndExecLinesButNeverValues() {
        var product = Product(name: "Acme Shop")
        var production = ProductEnvironment(name: "Production", tier: .production)
        production.id = UUID()
        product.environments = [ProductEnvironment(name: "Development", tier: .development), production]
        var profile = TerminalProfile()
        profile.name = "migrate"
        profile.environmentID = production.id
        profile.allowedExecutables = ["php"]
        profile.variableAllowlist = ["DB_PASSWORD"]
        product.profiles = [profile]
        var secret = VariableDefinition()
        secret.key = "DB_PASSWORD"
        secret.isSecret = true
        secret.scope = .product(product.id)
        secret.allowedTiers = [.production]
        var plain = VariableDefinition()
        plain.key = "API_BASE"
        plain.plainValue = "https://do-not-print.example"
        plain.scope = .product(product.id)
        plain.allowedTiers = [.development, .production]
        var portfolio = Portfolio()
        portfolio.variables = [secret, plain]
        let text = try? #require(AgentContextBundle.variablesSection(product, portfolio: portfolio))
        #expect(text?.contains("`DB_PASSWORD` (secret)") == true)
        #expect(text?.contains("forgedeck exec --product acme-shop --environment Production --profile migrate -- php") == true)
        #expect(text?.contains("Touch ID") == true)
        #expect(text?.contains("do-not-print") == false)
        #expect(AgentContextBundle.variablesSection(Product(name: "Empty"), portfolio: Portfolio()) == nil)
    }
}
