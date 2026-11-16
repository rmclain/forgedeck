import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct CIFailureTests {
    static let ghLog = """
    android-build\tRun build\t\u{FEFF}2026-11-15T21:24:33.5288805Z ##[group]Run node tools/build_app.mjs --release
    android-build\tRun build\t2026-11-15T21:24:33.5289398Z ^[[36;1mnode tools/build_app.mjs --release^[[0m
    android-build\tRun build\t2026-11-15T21:24:33.5343225Z ##[endgroup]
    android-build\tRun build\t2026-11-15T21:24:33.5903318Z BUILD FAILED token=ghp_abcdefghijklmnopqrstuvwxyz0123
    android-build\tRun build\t2026-11-15T21:24:33.5951899Z ##[error]Process completed with exit code 1.
    android-build\tPost cleanup\t2026-11-15T21:24:34.0000000Z Cleaning up orphan processes
    """

    @Test func ghLogsAreCleanedAndGrouped() {
        let sections = CILogDigest.sections(fromGH: Self.ghLog)
        #expect(sections.map(\.step) == ["Run build", "Post cleanup"])
        #expect(sections[0].lines.first == "▸ Run node tools/build_app.mjs --release")
        #expect(sections[0].lines[1] == "node tools/build_app.mjs --release")
        #expect(sections[0].lines.last == "ERROR: Process completed with exit code 1.")
        #expect(!sections[0].lines.contains { $0.contains("2026-11-15T") || $0.contains("endgroup") || $0.contains("\u{FEFF}") })
    }

    @Test func theExcerptCentersOnTheLastErrorAndRedacts() {
        var lines = (0..<200).map { "line \($0)" }
        lines[150] = "ERROR: the real problem"
        let (text, total) = CILogDigest.excerpt([CILogDigest.Section(job: "j", step: "s", lines: lines)])
        #expect(total == 200)
        #expect(text.contains("ERROR: the real problem"))
        #expect(text.contains("line 155"))
        #expect(!text.contains("line 199"))
        #expect(text.contains("earlier lines omitted"))
        let secret = CILogDigest.excerpt(CILogDigest.sections(fromGH: Self.ghLog)).text
        #expect(!secret.contains("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        let huge = (0..<5_000).map { _ in String(repeating: "x", count: 300) }
        #expect(CILogDigest.excerpt([CILogDigest.Section(job: "j", step: "s", lines: huge)]).text.count <= CILogDigest.maxCharacters + 200)
    }

    func run(_ id: Int, _ workflow: String, _ conclusion: String, minutesAgo: Double) -> CIRun {
        CIRun(id: id, workflow: workflow, title: "", status: "completed", conclusion: conclusion, branch: "main", sha: "abc1234",
              event: "push", createdAt: Date.now.addingTimeInterval(-minutesAgo * 60), url: "https://github.com/o/r/actions/runs/\(id)")
    }

    @Test func aFailedDeployIsPreferredThenTheNewestFailure() {
        let runs = [run(1, "CI", "failure", minutesAgo: 5), run(2, "Release", "failure", minutesAgo: 60),
                    run(3, "Deploy to production", "success", minutesAgo: 1), run(4, "Lint", "failure", minutesAgo: 2)]
        #expect(CILogDigest.pick(runs)?.id == 2)
        #expect(CILogDigest.pick(runs, preferDeployments: false)?.id == 4)
        #expect(CILogDigest.pick([run(5, "CI", "success", minutesAgo: 1)]) == nil)
    }

    @Test func theApiLogFollowsTheRedirectWithoutTheToken() async throws {
        let http = MockHTTPClient()
        http.on("/repos/o/r/actions/runs/9/jobs", json: #"{"jobs":[{"id":77,"name":"build","conclusion":"failure","steps":[{"name":"Compile","conclusion":"failure"}]},{"id":78,"name":"lint","conclusion":"success","steps":[]}]}"#)
        http.on("/repos/o/r/actions/jobs/77/logs", .response(HTTPResponse(status: 302, headers: ["Location": "https://pipelines.actions.githubusercontent.com/logs/77?sig=x"])))
        http.on("/logs/77", .response(HTTPResponse(status: 200, body: Data("""
        2026-11-15T10:00:00.0000000Z ##[group]Run swift build
        2026-11-15T10:00:01.0000000Z error: cannot find 'Foo' in scope
        2026-11-15T10:00:02.0000000Z ##[error]Process completed with exit code 1.
        """.utf8))))
        let connector = GitHubConnector(http: http, token: "ghp_secrettokenvalue123456789012345")
        let report = try await connector.report(owner: "o", name: "r", run: run(9, "CI", "failure", minutesAgo: 1))
        #expect(report.failedJobs.map(\.name) == ["build"])
        #expect(report.excerpt.contains("cannot find 'Foo' in scope"))
        let signed = http.requests.first { $0.url?.host == "pipelines.actions.githubusercontent.com" }
        #expect(signed != nil)
        #expect(signed?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aRedirectToAnUnknownHostIsRefused() async {
        let http = MockHTTPClient()
        http.on("/repos/o/r/actions/runs/9/jobs", json: #"{"jobs":[{"id":77,"name":"build","conclusion":"failure","steps":[]}]}"#)
        http.on("/repos/o/r/actions/jobs/77/logs", .response(HTTPResponse(status: 302, headers: ["Location": "https://evil.example/logs"])))
        await #expect(throws: CIError.self) { _ = try await GitHubConnector(http: http, token: "t").report(owner: "o", name: "r", run: run(9, "CI", "failure", minutesAgo: 1)) }
        #expect(!http.requests.contains { $0.url?.host == "evil.example" })
        #expect(!GitHubConnector.isLogHost("evil.example"))
        #expect(GitHubConnector.isLogHost("productionresultssa1.blob.core.windows.net"))
    }

    @Test func theBriefStatesFactsAndLimits() {
        let report = CIFailureReport(repository: "o/r", run: run(9, "Release", "failure", minutesAgo: 1),
                                     jobs: [CIJob(id: 1, name: "mirror", conclusion: "failure", failedSteps: ["Configure SSH"])],
                                     excerpt: "ERROR: The ssh-private-key argument is empty.", totalLines: 168, source: "gh CLI")
        var checkout = LocalCheckout()
        checkout.path = "/code/r"
        var git = GitSnapshot()
        git.branch = "main"
        git.headSHA = "abc1234"
        let brief = CIFixPrompt.brief(report, product: Product(name: "R"), checkout: checkout, git: git)
        #expect(brief.contains("Failed job: mirror, step: Configure SSH"))
        #expect(brief.contains("the same commit as the failed run"))
        #expect(brief.contains("(deploy or release)"))
        #expect(brief.contains("Do not push, tag, deploy"))
        #expect(brief.contains("Do not invent values"))
        let bundle = AgentContextBundle(contextFile: URL(fileURLWithPath: "/ctx/CONTEXT.md"), workingDirectory: "/code/r", readableFolders: ["/ctx"], relatedNames: [], approxTokens: 1)
        let command = CIFixPrompt.command(program: URL(fileURLWithPath: "/bin/claude"), bundle: bundle, brief: URL(fileURLWithPath: "/ctx/ci-failure-9.md"), run: report.run)
        #expect(command.last?.contains("/ctx/ci-failure-9.md") == true)
        #expect(command.contains("--add-dir"))
    }
}
