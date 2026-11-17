import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct AgentContextTests {
    static let pack = """
    # Files

    ## File: Sources/Core/Store.swift
    ```swift
    /// Keeps products.
    public final class Store {
    public func load() throws -> [Product]
    ⋮----
    func save(_ product: Product)
    ```

    ## File: Sources/Core/Product.swift
    ```swift
    public struct Product: Codable {
    var name: String
    ```

    ## File: Sources/UI/ListView.swift
    ```swift
    struct ListView: View {
    let store: Store
    func row(_ product: Product) -> some View
    ```

    ## File: README.md
    ```markdown
    # Not code
    ```
    """

    @Test func theMapRanksFilesByHowOftenOthersUseThem() {
        let map = RepoMap.make(fromPack: Self.pack)
        let headers = map.split(separator: "\n").filter { !$0.hasPrefix("  ") }.map(String.init)
        #expect(headers.first?.hasPrefix("Sources/Core/Product.swift") == true)
        #expect(headers.first?.contains("used by 2") == true)
        #expect(map.contains("  public final class Store"))
        #expect(map.contains("  func row(_ product: Product) -> some View"))
        #expect(!map.contains("README.md"))
        #expect(!map.contains("⋮"))
    }

    @Test func theMapStaysInsideItsBudget() {
        var big = "# Files\n"
        for index in 0..<400 {
            big += "\n## File: Sources/File\(index).swift\n```swift\npublic struct Type\(index) {\nfunc work\(index)(a: Int, b: String) -> Bool\n```\n"
        }
        let map = RepoMap.make(fromPack: big, budgetTokens: 500)
        #expect(map.count <= 500 * 4 + 120)
        #expect(map.hasSuffix("more files with declarations: see the full pack"))
    }

    @Test func aPackIsCurrentOnlyOnTheSameCleanCommit() {
        let info = PackInfo(checkoutID: UUID(), commit: "abc1234", wasDirty: false, builtAt: .now, bytes: 4_000, tool: "repomix")
        var git = GitSnapshot()
        git.headSHA = "abc1234"
        #expect(info.isCurrent(for: git))
        git.untracked = 1
        #expect(!info.isCurrent(for: git))
        git.untracked = 0
        git.headSHA = "def5678"
        #expect(!info.isCurrent(for: git))
        #expect(!info.isCurrent(for: nil))
        let dirty = PackInfo(checkoutID: UUID(), commit: "abc1234", wasDirty: true, builtAt: .now, bytes: 1, tool: "")
        git.headSHA = "abc1234"
        #expect(!dirty.isCurrent(for: git))
        #expect(info.approxTokens == 1_000)
    }

    @Test func repomixRunsPinnedWithoutAShellAndNeverPacksSecretFiles() {
        let output = URL(fileURLWithPath: "/tmp/out.md")
        let npx = URL(fileURLWithPath: "/opt/homebrew/bin/npx")
        let (program, arguments) = PackBuilder.command(output: output, repomix: nil, npx: npx)!
        #expect(program == npx)
        #expect(arguments.prefix(2) == ["--yes", "repomix@\(PackBuilder.repomixVersion)"])
        #expect(arguments.contains("--compress"))
        #expect(arguments.contains("/tmp/out.md"))
        let ignore = arguments[arguments.firstIndex(of: "--ignore")! + 1]
        #expect(ignore.contains("**/.env"))
        #expect(ignore.contains("**/*.pem"))
        #expect(!arguments.contains("--no-security-check"))
        let installed = URL(fileURLWithPath: "/usr/local/bin/repomix")
        #expect(PackBuilder.command(output: output, repomix: installed, npx: npx)?.0 == installed)
        #expect(PackBuilder.command(output: output, repomix: nil, npx: nil) == nil)
    }

    @Test func aFailedPackLeavesNothingBehind() async throws {
        let root = try makeTempDir("ctx")
        let repo = try makeTempDir("repo")
        defer { removeTemp(root); removeTemp(repo) }
        let location = ContextLocation(root: root)
        let runner = FakeRunner { _ in ProcessResult(exitCode: 1, stderr: "boom token=ghp_abcdefghijklmnopqrstuvwxyz0123") }
        var checkout = LocalCheckout()
        checkout.path = repo.path
        await #expect(throws: PackError.self) { _ = try await PackBuilder(runner: runner, location: location).build(checkout, git: nil) }
        #expect(PackBuilder(location: location).info(checkout) == nil)
        do { _ = try await PackBuilder(runner: runner, location: location).build(checkout, git: nil) } catch {
            #expect(!String(describing: error).contains("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        }
        if ExecutableLocator.find("npx") == nil, ExecutableLocator.find("repomix") == nil { return }
        #expect(runner.requests.first?.workingDirectory?.path == repo.path)
        #expect(runner.requests.first?.arguments.contains(where: { $0.contains(root.path) }) == true)
    }

    @Test func theBundleListsRelatedCheckoutsAndHoldsNoSecrets() throws {
        let root = try makeTempDir("ctx")
        let app = try makeTempDir("app repo")
        let api = try makeTempDir("api's repo")
        defer { removeTemp(root); removeTemp(app); removeTemp(api) }
        try FileManager.default.createDirectory(at: api.appending(path: "Sources/Routes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: api.appending(path: "node_modules/x"), withIntermediateDirectories: true)
        try write("SECRET=hunter2-marker", to: api.appending(path: ".env"))
        try write("token ghp_abcdefghijklmnopqrstuvwxyz0123", to: api.appending(path: "notes.txt"))
        try FileManager.default.createDirectory(at: api.appending(path: "graphify-out"), withIntermediateDirectories: true)
        try write("{}", to: api.appending(path: "graphify-out/graph.json"))
        try write("# Graph Report - api\n\n## Summary\n- 12 nodes\n\n## Community Hubs (Navigation)\n- Routes\n\n## God Nodes\n- should not appear\n", to: api.appending(path: "graphify-out/GRAPH_REPORT.md"))

        var portfolio = Portfolio()
        var apiProduct = Product(name: "API")
        var apiCheckout = LocalCheckout()
        apiCheckout.name = "api"
        apiCheckout.path = api.path
        apiProduct.checkouts = [apiCheckout]
        apiProduct.stack = ["FastAPI"]
        var appProduct = Product(name: "App")
        var appCheckout = LocalCheckout()
        appCheckout.name = "app"
        appCheckout.path = app.path
        appProduct.checkouts = [appCheckout]
        appProduct.contextLinks = [ContextLink(productID: apiProduct.id, includePack: true, note: "The app calls this API")]
        portfolio.products = [appProduct, apiProduct]

        let bundle = try AgentContextBundle.write(for: appProduct, portfolio: portfolio, cache: ObservationCache(), location: ContextLocation(root: root))
        let text = try String(contentsOf: bundle.contextFile, encoding: .utf8)
        #expect(bundle.workingDirectory == app.path)
        #expect(bundle.readableFolders.contains(api.path))
        #expect(!bundle.readableFolders.contains(app.path))
        #expect(bundle.contextFolders.first == bundle.contextFile.deletingLastPathComponent().path)
        #expect(!bundle.readableFolders.contains(bundle.contextFile.deletingLastPathComponent().path))
        #expect(bundle.relatedNames == ["API"])
        #expect(text.contains("## API"))
        #expect(text.contains("The app calls this API"))
        #expect(text.contains("Sources/"))
        #expect(!text.contains("node_modules"))
        #expect(!text.contains(".env"))
        #expect(!text.contains("hunter2-marker"))
        #expect(!text.contains("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        #expect(text.contains("- 12 nodes"))
        #expect(text.contains("graphify query"))
        #expect(!text.contains("should not appear"))
        #expect(text.contains("Compressed code pack: not built yet"))
        #expect(bundle.approxTokens < 2_000)
        let attributes = try FileManager.default.attributesOfItem(atPath: bundle.contextFile.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func eachAgentGetsTheContextItCanUse() {
        let bundle = AgentContextBundle(contextFile: URL(fileURLWithPath: "/ctx/app/CONTEXT.md"), workingDirectory: "/code/app",
                                        readableFolders: ["/code/it's api"], relatedNames: ["API"], approxTokens: 500, contextFolders: ["/ctx/app"])
        let claude = bundle.command(program: URL(fileURLWithPath: "/usr/local/bin/claude"))
        #expect(claude == ["/usr/local/bin/claude", "--settings", #"{"permissions":{"allow":["Read(//ctx/app/**)"]}}"#,
                           "--add-dir", "/code/it's api", "--append-system-prompt", bundle.pointer])
        #expect(bundle.pointer.contains("/ctx/app/CONTEXT.md"))
        #expect(bundle.pointer.count < 400)
        #expect(bundle.command(program: URL(fileURLWithPath: "/bin/codex")) == ["/bin/codex", bundle.pointer])
        #expect(bundle.command(program: URL(fileURLWithPath: "/bin/opencode")) == ["/bin/opencode", "--prompt", bundle.pointer, "/code/app"])
        // The copy-paste form quotes every word, apostrophes included.
        let line = TerminalLauncher.copyCommand(directory: bundle.workingDirectory, command: claude)
        #expect(line.contains(#"'/code/it'\''s api'"#))
    }

    @Test func theTerminalShowsWhatTheAgentWasStartedWith() {
        let bundle = AgentContextBundle(contextFile: URL(fileURLWithPath: "/Users/me/ctx/app/CONTEXT.md"), workingDirectory: "/code/app",
                                        readableFolders: ["/code/api"], relatedNames: ["API", "Plugin"], approxTokens: 2_400, contextFolders: ["/ctx/app"])
        let claude = bundle.banner(product: "App", program: "claude", home: "/Users/me")
        #expect(claude.contains("~/ctx/app/CONTEXT.md"))
        #expect(claude.contains("API, Plugin"))
        #expect(claude.contains("1 folder added with --add-dir") && claude.contains("no trust prompt"))
        #expect(claude.contains("system prompt"))
        #expect(claude.hasSuffix("\r\n"))
        let codex = bundle.banner(product: "App", program: "codex", home: "/Users/me")
        #expect(!codex.contains("--add-dir"))
        #expect(bundle.banner(product: "App", program: "gemini").contains("2 folders added with --include-directories"))
        #expect(codex.contains("first message"))
        let alone = AgentContextBundle(contextFile: URL(fileURLWithPath: "/c/CONTEXT.md"), workingDirectory: "/w", readableFolders: [], relatedNames: [], approxTokens: 10)
        #expect(alone.banner(product: "W", program: "claude").contains("none linked"))
    }

    @Test func linksSurviveMigrationAndDanglingLinksAreRepaired() throws {
        let v2 = #"{"schemaVersion":2,"products":[{"id":"6E6B4B9C-1D2B-4D59-9A2E-1C1F8E4A1B01","slug":"a","name":"A","tagline":"","notes":"","group":"G","tags":[],"stack":[],"links":[],"isFavorite":false,"lifecycle":"active","hue":1,"monogram":"A","createdAt":"2026-11-01T00:00:00Z","isDemo":false,"components":[],"repositories":[],"checkouts":[],"environments":[],"recipes":[],"profiles":[]}],"organizations":[],"connections":[],"variables":[],"settings":{}}"#
        let migrated = try PortfolioMigrator.migrate(Data(v2.utf8))
        let json = try JSONSerialization.jsonObject(with: migrated) as! [String: Any]
        #expect(json["schemaVersion"] as? Int == Portfolio.currentSchemaVersion)
        #expect(((json["products"] as! [[String: Any]])[0]["contextLinks"] as? [Any])?.isEmpty == true)

        var portfolio = Portfolio()
        var product = Product(name: "A")
        product.contextLinks = [ContextLink(productID: UUID()), ContextLink(productID: product.id)]
        portfolio.products = [product]
        #expect(IntegrityChecker.problems(in: portfolio).contains { $0.contains("itself") })
        #expect(IntegrityChecker.repair(portfolio).products[0].contextLinks.isEmpty)
    }
}

/// Packs real repositories with the real repomix. Run with FORGEDECK_LIVE_TOOLS=1 (needs Node; npx may download repomix once).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FORGEDECK_LIVE_TOOLS"] == "1")) struct LivePack {
    @Test func repomixPacksARepositoryAndTheMapIsMuchSmaller() async throws {
        let root = try makeTempDir("ctx")
        let repoURL = try makeTempDir("live repo")
        defer { removeTemp(root); removeTemp(repoURL) }
        let repo = try TestRepo.create(at: repoURL)
        try FileManager.default.createDirectory(at: repoURL.appending(path: "Sources"), withIntermediateDirectories: true)
        var body = ""
        for index in 0..<40 {
            body += "public struct Widget\(index) {\n    public var size = \(index)\n    public func render(scale: Double) -> String {\n        let value = Double(size) * scale\n        return \"widget \\(value)\"\n    }\n}\n\n"
        }
        _ = try repo.commit(file: "Sources/Widgets.swift", content: body, message: "widgets")
        try write("API_KEY=live-pack-secret-marker", to: repoURL.appending(path: ".env"))
        var checkout = LocalCheckout()
        checkout.path = repoURL.path
        let git = await GitService().snapshot(path: repoURL.path)
        let location = ContextLocation(root: root)
        let info = try await PackBuilder(location: location).build(checkout, git: git)
        let pack = try String(contentsOf: location.pack(checkout), encoding: .utf8)
        let map = try String(contentsOf: location.map(checkout), encoding: .utf8)
        #expect(pack.contains("Widget7"))
        #expect(!pack.contains("live-pack-secret-marker"))
        #expect(!pack.contains("let value = Double(size) * scale"))
        #expect(map.contains("public struct Widget"))
        #expect(map.count < pack.count)
        #expect(info.commit == git.headSHA)
    }
}

@Suite struct RepoMapFilterTests {
    @Test func oldPacksAndDataFilesNeverLeadTheMap() {
        let pack = """
        ## File: repo.xml
        ```xml
        public class Everything
        function all()
        ```

        ## File: src/game.js
        ```js
        function step(dt)
        ```

        ## File: dist/app.min.js
        ```js
        function a()
        ```
        """
        let map = RepoMap.make(fromPack: pack)
        #expect(map.hasPrefix("src/game.js"))
        #expect(!map.contains("repo.xml"))
        #expect(!map.contains("app.min.js"))
        #expect(PackBuilder.alwaysIgnored.contains("**/repo.xml"))
    }
}
