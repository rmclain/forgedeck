import Foundation
import Testing
@testable import ForgeDeckKit

// Shared helpers. Nothing here touches the network, the real store folder, or the
// default Keychain service.

/// A whole-second instant, so ISO 8601 round trips compare equal.
let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)

let shaA = String(repeating: "a", count: 40)
let shaB = String(repeating: "b", count: 40)
let shaC = String(repeating: "c", count: 40)
let shaD = String(repeating: "d", count: 40)

func makeTempDir(_ label: String = "t") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "forgedeck-tests-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func removeTemp(_ url: URL) { try? FileManager.default.removeItem(at: url) }

/// The path with symlinks resolved, for comparing what git or a shell printed.
func realPath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: Subprocesses

struct ToolResult {
    var code: Int32
    var out: String
    var err: String
}

struct ToolFailure: Error, CustomStringConvertible {
    var description: String
}

@discardableResult
func runTool(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil) throws -> ToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    if let environment { process.environment = environment }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ToolResult(code: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
}

/// Git for building test repositories: no user or system configuration, a fixed identity.
let gitTestEnvironment: [String: String] = {
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_AUTHOR_NAME"] = "Test Author"
    env["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
    env["GIT_COMMITTER_NAME"] = "Test Author"
    env["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
    env["LC_ALL"] = "C"
    return env
}()

@discardableResult
func git(_ arguments: [String], in directory: URL) throws -> String {
    let result = try runTool("/usr/bin/git", arguments, cwd: directory, environment: gitTestEnvironment)
    guard result.code == 0 else {
        throw ToolFailure(description: "git \(arguments.joined(separator: " ")) failed (\(result.code)): \(result.err)")
    }
    return result.out
}

struct TestRepo {
    let url: URL
    var path: String { url.path }

    /// `git init -b main` plus one commit.
    static func create(at url: URL) throws -> TestRepo {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: url)
        let repo = TestRepo(url: url)
        try repo.commit(file: "README.md", content: "hello\n", message: "initial")
        return repo
    }

    @discardableResult
    func commit(file: String, content: String, message: String) throws -> String {
        try content.write(to: url.appending(path: file), atomically: true, encoding: .utf8)
        try git(["add", "--", file], in: url)
        try git(["commit", "-q", "-m", message], in: url)
        return try head()
    }

    func head() throws -> String { try git(["rev-parse", "HEAD"], in: url).trimmed }
}

// MARK: Fakes

final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [ProcessRequest] = []
    private let handler: @Sendable (ProcessRequest) throws -> ProcessResult

    init(_ handler: @escaping @Sendable (ProcessRequest) throws -> ProcessResult) { self.handler = handler }

    convenience init(result: ProcessResult) { self.init { _ in result } }

    var requests: [ProcessRequest] { lock.withLock { log } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        lock.withLock { log.append(request) }
        return try handler(request)
    }
}

final class FakeOpener: AppOpening, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var log: [(items: [URL], app: URL)] = []
    private var urlLog: [URL] = []
    let installed: Set<String>
    let fails: Bool

    init(installed: Set<String> = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.microsoft.VSCode"], fails: Bool = false) {
        self.installed = installed
        self.fails = fails
    }

    var opened: [(items: [URL], app: URL)] { lock.withLock { log } }
    var openedURLs: [URL] { lock.withLock { urlLog } }

    func applicationURL(bundleID: String) -> URL? {
        installed.contains(bundleID) ? URL(fileURLWithPath: "/Applications/Fake/\(bundleID).app") : nil
    }

    func open(_ items: [URL], withApplicationAt app: URL) async throws {
        if fails { throw Failure() }
        lock.withLock { log.append((items, app)) }
    }

    func open(_ url: URL) async throws {
        if fails { throw Failure() }
        lock.withLock { urlLog.append(url) }
    }

    func reveal(_ url: URL) {}
}

/// Counts every read, so a test can prove a denial happened before any secret was touched.
final class SpySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let inner: MemorySecretStore

    init(_ values: [String: String]) { inner = MemorySecretStore(values) }

    var reads: Int { lock.withLock { count } }

    func read(_ locator: String) throws -> String {
        lock.withLock { count += 1 }
        return try inner.read(locator)
    }

    func write(_ value: String, locator: String) throws { try inner.write(value, locator: locator) }
    func delete(_ locator: String) throws { try inner.delete(locator) }
    func exists(_ locator: String) -> Bool { inner.exists(locator) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

// MARK: Evidence world

/// One product with a repository, a checkout, and staging and production environments,
/// each with a companion probe and a GitHub deployment environment name.
struct EvidenceWorld {
    var portfolio: Portfolio

    var product: Product { portfolio.products[0] }
    var repo: Repository { product.repositories[0] }
    var checkout: LocalCheckout { product.checkouts[0] }
    var staging: ProductEnvironment { product.environment(tier: .staging)! }
    var production: ProductEnvironment { product.environment(tier: .production)! }
    var stagingProbe: ProbeConfig { staging.probes[0] }
    var productionProbe: ProbeConfig { production.probes[0] }

    init(connected: Bool = true) {
        var product = Product(name: "Acme App")
        var repo = Repository()
        repo.owner = "acme"
        repo.name = "app"
        product.repositories = [repo]
        var checkout = LocalCheckout()
        checkout.name = "app"
        checkout.path = "/nonexistent/acme/app"
        checkout.repositoryID = repo.id
        product.checkouts = [checkout]
        var staging = ProductEnvironment(name: "Staging", tier: .staging)
        var production = ProductEnvironment(name: "Production", tier: .production)
        if connected {
            for (index, name) in ["staging", "production"].enumerated() {
                var probe = ProbeConfig()
                probe.name = "\(name) status"
                probe.kind = .companion
                probe.url = "https://\(name).acme.example/_forgedeck/v1/status"
                if index == 0 {
                    staging.probes = [probe]
                    staging.githubEnvironmentName = name
                } else {
                    production.probes = [probe]
                    production.githubEnvironmentName = name
                }
            }
        }
        product.environments = [ProductEnvironment(name: "Local", tier: .development), staging, production]
        var portfolio = Portfolio()
        portfolio.products = [product]
        self.portfolio = portfolio
    }

    func observation(_ environment: ProductEnvironment, sha: String?, version: String? = nil, source: FactSource = .runtimeProbe,
                     level: EvidenceLevel = .verified, at: Date, ttl: TimeInterval = 900, deployState: String? = nil,
                     problem: ObservationProblem? = nil, health: HealthState = .healthy, instances: [String] = []) -> DeploymentObservation {
        var observation = DeploymentObservation()
        observation.productID = product.id
        observation.environmentID = environment.id
        observation.sha = sha
        observation.version = version
        observation.deployState = deployState
        observation.problem = problem
        observation.health = health
        observation.instanceSHAs = instances
        observation.provenance = Provenance(observedAt: at, source: source, level: level, ttl: ttl)
        return observation
    }

    func remote(head: String, at: Date, runs: [WorkflowRunSummary] = [], deployments: [ReportedDeployment] = []) -> RemoteSnapshot {
        var snapshot = RemoteSnapshot()
        snapshot.headSHA = head
        snapshot.headMessage = "Commit \(head.prefix(7))"
        snapshot.headDate = at
        snapshot.runs = runs
        snapshot.deployments = deployments
        snapshot.provenance = Provenance(observedAt: at, source: .githubAPI, level: .verified, ttl: 900)
        return snapshot
    }

    func gitSnapshot(head: String, at: Date) -> GitSnapshot {
        var git = GitSnapshot()
        git.branch = "main"
        git.headSHA = head
        git.observedAt = at
        return git
    }
}

func workflowRun(id: Int, sha: String, conclusion: String, at: Date, branch: String = "main") -> WorkflowRunSummary {
    var run = WorkflowRunSummary()
    run.id = id
    run.name = "CI"
    run.branch = branch
    run.headSHA = sha
    run.status = "completed"
    run.conclusion = conclusion
    run.createdAt = at
    return run
}

func reportedDeployment(id: Int, environment: String, sha: String, state: String, at: Date) -> ReportedDeployment {
    var deployment = ReportedDeployment()
    deployment.id = id
    deployment.environment = environment
    deployment.sha = sha
    deployment.state = state
    deployment.createdAt = at
    deployment.creator = "ci-bot"
    return deployment
}

// MARK: Secret world

/// A portfolio whose secret values exist only in a memory store, under marker strings
/// that must never show up in anything persisted, printed, or logged.
struct SecretWorld {
    static let devMarker = "S3CR3T-DEV-MARKER-7f3a9c41d2"
    static let prodMarker = "S3CR3T-PROD-MARKER-b81e02c6aa"
    static let prodOnlyMarker = "S3CR3T-PRODONLY-MARKER-55d0e1"
    static let plainMarker = "PLAIN-VALUE-MARKER-0917"
    static let argumentMarker = "RECIPE-ARGUMENT-MARKER-4410"
    static var allSecretMarkers: [String] { [devMarker, prodMarker, prodOnlyMarker] }

    var portfolio: Portfolio
    let secrets: SpySecretStore
    let audit = MemoryAuditSink()

    var product: Product { portfolio.products[0] }
    var local: ProductEnvironment { product.environment(tier: .development)! }
    var production: ProductEnvironment { product.environment(tier: .production)! }

    init(checkoutPath: String = "/nonexistent/acme/api") {
        var product = Product(name: "Acme API")
        var checkout = LocalCheckout()
        checkout.name = "api"
        checkout.path = checkoutPath
        checkout.bookmark = Data("bookmark-bytes".utf8)
        product.checkouts = [checkout]
        let local = ProductEnvironment(name: "Local", tier: .development)
        let production = ProductEnvironment(name: "Production", tier: .production)
        product.environments = [local, production]

        var dev = TerminalProfile()
        dev.name = "dev"
        dev.environmentID = local.id
        dev.checkoutID = checkout.id
        dev.variableAllowlist = ["API_TOKEN", "FEATURE_FLAG"]
        dev.allowedExecutables = ["env", "printenv"]
        var prod = TerminalProfile()
        prod.name = "prod"
        prod.environmentID = production.id
        prod.variableAllowlist = ["API_TOKEN"]
        prod.allowedExecutables = ["env"]
        var leaky = TerminalProfile()
        leaky.name = "leaky"
        leaky.environmentID = local.id
        leaky.variableAllowlist = ["PROD_ONLY_KEY"]
        leaky.allowedExecutables = ["env"]
        product.profiles = [dev, prod, leaky]

        var recipe = ActionRecipe()
        recipe.label = "Run Tests"
        recipe.executable = "/usr/local/bin/npm"
        recipe.arguments = ["test", "--token=\(Self.argumentMarker)"]
        recipe.checkoutID = checkout.id
        recipe.environmentID = local.id
        recipe.variableKeys = ["API_TOKEN"]
        recipe.isApproved = true
        product.recipes = [recipe]

        var other = Product(name: "Other Thing")
        var otherProfile = TerminalProfile()
        otherProfile.name = "otherprof"
        otherProfile.allowedExecutables = ["env"]
        other.environments = [ProductEnvironment(name: "Local", tier: .development)]
        other.profiles = [otherProfile]

        var archived = Product(name: "Old Thing")
        archived.lifecycle = .archived
        var archivedProfile = TerminalProfile()
        archivedProfile.name = "dev"
        archivedProfile.allowedExecutables = ["env"]
        archived.environments = [ProductEnvironment(name: "Local", tier: .development)]
        archived.profiles = [archivedProfile]

        func secret(_ key: String, scope: VariableScope, tiers: [EnvironmentTier], locator: String) -> VariableDefinition {
            var variable = VariableDefinition()
            variable.key = key
            variable.scope = scope
            variable.isSecret = true
            variable.allowedTiers = tiers
            var reference = CredentialReference()
            reference.locator = locator
            variable.credential = reference
            return variable
        }
        var flag = VariableDefinition()
        flag.key = "FEATURE_FLAG"
        flag.scope = .product(product.id)
        flag.plainValue = Self.plainMarker
        flag.allowedTiers = [.development]

        var portfolio = Portfolio()
        portfolio.products = [product, other, archived]
        portfolio.variables = [
            secret("API_TOKEN", scope: .product(product.id), tiers: [.development], locator: "loc-dev"),
            secret("API_TOKEN", scope: .environment(product: product.id, environment: production.id), tiers: [.production], locator: "loc-prod"),
            secret("PROD_ONLY_KEY", scope: .product(product.id), tiers: [.production], locator: "loc-prod-only"),
            flag,
        ]
        var connection = Connection()
        connection.provider = .github
        connection.displayName = "GitHub"
        var reference = CredentialReference()
        reference.locator = "loc-github"
        connection.credential = reference
        portfolio.connections = [connection]
        self.portfolio = portfolio
        secrets = SpySecretStore(["loc-dev": Self.devMarker, "loc-prod": Self.prodMarker,
                                  "loc-prod-only": Self.prodOnlyMarker, "loc-github": Self.prodMarker])
    }

    func exec(authorizer: any Authorizing = FixedAuthorizer(false), audit: (any AuditSink)? = nil) -> ExecService {
        ExecService(credentials: CredentialResolver(keychain: secrets, runner: FakeRunner(result: ProcessResult(exitCode: 1)), environment: [:]),
                    authorizer: authorizer, audit: audit ?? self.audit, baseEnvironment: ["PATH": "/usr/bin:/bin"])
    }

    func request(environment: String = "local", profile: String = "dev", command: [String] = ["env"], product: String? = nil) -> ExecRequest {
        ExecRequest(productSlug: product ?? self.product.slug, environmentName: environment, profileName: profile, command: command)
    }
}

/// Runs a plan and returns the denial, or nil when it was granted.
func denial(_ service: ExecService, _ request: ExecRequest, _ portfolio: Portfolio) async -> ExecDenial? {
    do {
        _ = try await service.plan(request, portfolio: portfolio)
        return nil
    } catch let denial as ExecDenial {
        return denial
    } catch {
        Issue.record("unexpected error \(error)")
        return nil
    }
}

func expectNoMarkers(_ text: String, _ label: String, markers: [String] = SecretWorld.allSecretMarkers,
                     sourceLocation: SourceLocation = #_sourceLocation) {
    for marker in markers {
        #expect(!text.contains(marker), "\(label) contains a secret marker", sourceLocation: sourceLocation)
    }
}
