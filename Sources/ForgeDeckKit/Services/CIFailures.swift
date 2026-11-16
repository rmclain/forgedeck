import Foundation

// Failed GitHub Actions runs: find the run, fetch only the failing part of its log, shrink it to
// what an agent needs, and write a short fix brief. Read-only against GitHub.

public struct CIRun: Sendable, Hashable, Identifiable, Codable {
    public var id: Int
    public var workflow: String
    public var title: String
    public var status: String
    public var conclusion: String
    public var branch: String
    public var sha: String
    public var event: String
    public var createdAt: Date
    public var url: String

    public var failed: Bool { ["failure", "timed_out", "startup_failure"].contains(conclusion) }
    /// A deploy, release, or publish workflow, judged by its name.
    public var isDeployment: Bool {
        let name = workflow.lowercased()
        return ["deploy", "release", "publish", "ship", "production"].contains { name.contains($0) }
    }
}

public struct CIJob: Sendable, Hashable, Codable {
    public var id: Int
    public var name: String
    public var conclusion: String
    public var failedSteps: [String]
}

public struct CIFailureReport: Sendable, Equatable {
    public var repository: String
    public var run: CIRun
    public var jobs: [CIJob]
    /// The cleaned end of the failing steps' output.
    public var excerpt: String
    /// Lines in the failing output before it was shortened.
    public var totalLines: Int
    public var source: String
    public var fetchedAt = Date.now

    public var failedJobs: [CIJob] { jobs.filter { $0.conclusion == "failure" || $0.conclusion == "timed_out" } }
    public var approxTokens: Int { excerpt.utf8.count / 4 }
}

public enum CIError: Error, CustomStringConvertible, Equatable {
    case noRepository
    case noAccess(String)
    case noFailedRun
    case logUnavailable(String)

    public var description: String {
        switch self {
        case .noRepository: "This product has no GitHub repository linked."
        case .noAccess(let why): "GitHub could not be read: \(why) Connect GitHub in Connections, or sign in with `gh auth login`."
        case .noFailedRun: "No failed run in the recent history. Nothing to fix."
        case .logUnavailable(let why): "The log could not be fetched: \(why)"
        }
    }
}

public enum CILogDigest {
    public static let maxCharacters = 12_000
    public static let linesPerStep = 80

    private static let timestamp = try! NSRegularExpression(pattern: #"^\x{FEFF}?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z ?"#)

    /// One log line without its timestamp, color codes, or GitHub's group markers.
    public static func clean(_ line: String) -> String? {
        var text = Toolbox.stripANSI(line).replacingOccurrences(of: "\u{FEFF}", with: "")
        text = timestamp.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        // gh prints escape sequences as ^[ when they are not a terminal's.
        text = text.replacingOccurrences(of: #"\^\[\[[0-9;]*m"#, with: "", options: .regularExpression)
        if text.hasPrefix("##[endgroup]") { return nil }
        if text.hasPrefix("##[group]") { text = "▸ " + text.dropFirst("##[group]".count) }
        if text.hasPrefix("##[error]") { text = "ERROR: " + text.dropFirst("##[error]".count) }
        if text.hasPrefix("##[warning]") { text = "WARNING: " + text.dropFirst("##[warning]".count) }
        return text
    }

    public struct Section: Sendable, Equatable {
        public var job: String
        public var step: String
        public var lines: [String]
    }

    /// Parses `gh run view --log-failed`: `job<TAB>step<TAB>line`.
    public static func sections(fromGH text: String) -> [Section] {
        var sections: [Section] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let line = clean(parts[2]) else { continue }
            if let last = sections.last, last.job == parts[0], last.step == parts[1] {
                sections[sections.count - 1].lines.append(line)
            } else {
                sections.append(Section(job: parts[0], step: parts[1], lines: [line]))
            }
        }
        return sections
    }

    /// Parses a whole job log from the API. Steps start at `##[group]Run …`. Only the steps that
    /// contain an error are kept; without any error marker, the last step is kept.
    public static func sections(fromJobLog text: String, job: String) -> [Section] {
        var steps: [Section] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = timestamp.stringByReplacingMatches(in: String(raw), range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            if stripped.hasPrefix("##[group]Run ") || steps.isEmpty {
                let name = stripped.hasPrefix("##[group]") ? String(stripped.dropFirst("##[group]".count)) : "Set up job"
                steps.append(Section(job: job, step: name, lines: []))
            }
            if let line = clean(String(raw)) { steps[steps.count - 1].lines.append(line) }
        }
        let failing = steps.filter { $0.lines.contains { $0.hasPrefix("ERROR:") } }
        return failing.isEmpty ? Array(steps.suffix(1)) : failing
    }

    /// The end of each failing step, newest output last, within the character budget.
    public static func excerpt(_ sections: [Section], maxCharacters: Int = maxCharacters) -> (text: String, totalLines: Int) {
        let total = sections.reduce(0) { $0 + $1.lines.count }
        var blocks: [String] = []
        let budget = max(1_000, maxCharacters / max(1, sections.count))
        for section in sections {
            var kept: [String] = []
            var used = 0
            // Center on the last error: what led up to it, and a few lines after. Cleanup after it is noise.
            var window = section.lines.suffix(linesPerStep)
            if let last = section.lines.lastIndex(where: { $0.hasPrefix("ERROR:") }) {
                let end = min(section.lines.count, last + 6)
                window = section.lines[max(0, end - linesPerStep)..<end]
            }
            for line in window.reversed() {
                let trimmed = line.count > 400 ? String(line.prefix(397)) + "..." : line
                guard used + trimmed.count + 1 <= budget else { break }
                kept.insert(trimmed, at: 0)
                used += trimmed.count + 1
            }
            let skipped = section.lines.count - kept.count
            blocks.append("### \(section.job) › \(section.step)\n" + (skipped > 0 ? "… \(skipped) earlier lines omitted\n" : "") + kept.joined(separator: "\n"))
        }
        return (Redactor().redact(blocks.joined(separator: "\n\n")), total)
    }

    /// Newest failed deploy-type run, else the newest failed run.
    public static func pick(_ runs: [CIRun], preferDeployments: Bool = true) -> CIRun? {
        let failed = runs.filter { $0.status == "completed" && $0.failed }.sorted { $0.createdAt > $1.createdAt }
        if preferDeployments, let deploy = failed.first(where: \.isDeployment) { return deploy }
        return failed.first
    }
}

/// Reads runs and logs through the `gh` CLI, which keeps its own GitHub sign-in.
public struct GHActionsSource: Sendable {
    public let runner: any ProcessRunning
    public let gh: URL?

    public init(runner: any ProcessRunning = SystemProcessRunner(), gh: URL? = ExecutableLocator.find("gh")) {
        self.runner = runner
        self.gh = gh
    }

    private func call(_ arguments: [String], timeout: TimeInterval = 60) async throws -> String {
        guard let gh else { throw CIError.noAccess("the GitHub CLI (gh) is not installed.") }
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        let result = try await runner.run(ProcessRequest(executable: gh, arguments: arguments, environment: environment,
                                                         timeout: timeout, maxOutputBytes: 4_000_000))
        guard result.ok else {
            let why = result.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(result.exitCode)"
            throw CIError.noAccess(Redactor().redact(why))
        }
        return result.stdout
    }

    public func runs(repository: String, limit: Int = 20) async throws -> [CIRun] {
        let json = try await call(["run", "list", "--repo", repository, "--limit", String(limit), "--json",
                                   "databaseId,workflowName,displayTitle,status,conclusion,headBranch,headSha,event,createdAt,url"])
        guard let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { throw CIError.noAccess("unexpected output from gh.") }
        return items.compactMap { item in
            guard let id = item["databaseId"] as? Int else { return nil }
            return CIRun(id: id, workflow: item["workflowName"] as? String ?? "", title: item["displayTitle"] as? String ?? "",
                         status: item["status"] as? String ?? "", conclusion: item["conclusion"] as? String ?? "",
                         branch: item["headBranch"] as? String ?? "", sha: item["headSha"] as? String ?? "",
                         event: item["event"] as? String ?? "", createdAt: FlexibleDate.parse(item["createdAt"] as? String) ?? .distantPast,
                         url: item["url"] as? String ?? "")
        }
    }

    public func report(repository: String, run: CIRun) async throws -> CIFailureReport {
        let details = try await call(["run", "view", String(run.id), "--repo", repository, "--json", "jobs"])
        var jobs: [CIJob] = []
        if let json = try? JSONSerialization.jsonObject(with: Data(details.utf8)) as? [String: Any], let items = json["jobs"] as? [[String: Any]] {
            jobs = items.map { item in
                let steps = (item["steps"] as? [[String: Any]] ?? []).filter { ($0["conclusion"] as? String) == "failure" }.compactMap { $0["name"] as? String }
                return CIJob(id: item["databaseId"] as? Int ?? 0, name: item["name"] as? String ?? "", conclusion: item["conclusion"] as? String ?? "", failedSteps: steps)
            }
        }
        let log = try await call(["run", "view", String(run.id), "--repo", repository, "--log-failed"], timeout: 120)
        // gh says "UNKNOWN STEP" when it cannot match a log to a step. The job list knows which one failed.
        let sections = CILogDigest.sections(fromGH: log).map { section -> CILogDigest.Section in
            guard section.step == "UNKNOWN STEP", let job = jobs.first(where: { $0.name == section.job || section.job.hasSuffix($0.name) }),
                  job.failedSteps.count == 1 else { return section }
            var named = section
            named.step = job.failedSteps[0]
            return named
        }
        let (excerpt, total) = CILogDigest.excerpt(sections)
        guard !excerpt.isEmpty else { throw CIError.logUnavailable("GitHub returned no log for the failed steps. Logs expire after the repository's retention period.") }
        return CIFailureReport(repository: repository, run: run, jobs: jobs, excerpt: excerpt, totalLines: total, source: "gh CLI")
    }
}

extension GitHubConnector {
    /// Recent workflow runs, newest first.
    public func runs(owner: String, name: String, limit: Int = 20) async -> ConnectorResult<[CIRun]> {
        switch await snapshot(owner: owner, name: name) {
        case .success(let snapshot), .partial(let snapshot, _):
            return .success(snapshot.runs.map { run in
                CIRun(id: run.id, workflow: run.name, title: run.name, status: run.status, conclusion: run.conclusion, branch: run.branch,
                      sha: run.headSHA, event: "", createdAt: run.createdAt, url: run.url)
            })
        case .failure(let problem, let detail, let retry):
            return .failure(problem, detail: detail, retryAfter: retry)
        }
    }

    /// Hosts GitHub sends job logs from. The redirect is followed only to these, and without the token.
    public static func isLogHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host.hasSuffix(".actions.githubusercontent.com") || host.hasSuffix(".blob.core.windows.net") || host == "pipelines.actions.githubusercontent.com"
    }

    /// The failing part of a run, from the API: the jobs, then each failed job's log.
    public func report(owner: String, name: String, run: CIRun) async throws -> CIFailureReport {
        let jobsURL = baseURL.appending(path: "/repos/\(owner)/\(name)/actions/runs/\(run.id)/jobs")
        var request = URLRequest(url: jobsURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Brand.name, forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let response: HTTPResponse
        do { response = try await http.send(request) } catch { throw CIError.noAccess(HTTPFailure.problem(for: error).1) }
        if let (_, detail, _) = HTTPFailure.problem(status: response.status, headers: response.headers) { throw CIError.noAccess(detail) }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], let items = json["jobs"] as? [[String: Any]] else {
            throw CIError.noAccess("GitHub returned an unexpected jobs list.")
        }
        let jobs = items.map { item in
            CIJob(id: item["id"] as? Int ?? 0, name: item["name"] as? String ?? "", conclusion: item["conclusion"] as? String ?? "",
                  failedSteps: (item["steps"] as? [[String: Any]] ?? []).filter { ($0["conclusion"] as? String) == "failure" }.compactMap { $0["name"] as? String })
        }
        var sections: [CILogDigest.Section] = []
        for job in jobs where job.conclusion == "failure" || job.conclusion == "timed_out" {
            var logRequest = URLRequest(url: baseURL.appending(path: "/repos/\(owner)/\(name)/actions/jobs/\(job.id)/logs"))
            logRequest.setValue(Brand.name, forHTTPHeaderField: "User-Agent")
            if let token, !token.isEmpty { logRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            var reply: HTTPResponse
            do { reply = try await http.send(logRequest) } catch { throw CIError.logUnavailable(HTTPFailure.problem(for: error).1) }
            // GitHub answers with a redirect to a short-lived signed URL on its storage host.
            if (300..<400).contains(reply.status) {
                guard let location = reply.headers["location"], let url = URL(string: location), url.scheme == "https",
                      let host = url.host, Self.isLogHost(host) else {
                    throw CIError.logUnavailable("GitHub redirected the log to an unexpected address.")
                }
                var signed = URLRequest(url: url)
                signed.setValue(Brand.name, forHTTPHeaderField: "User-Agent")
                do { reply = try await http.send(signed) } catch { throw CIError.logUnavailable(HTTPFailure.problem(for: error).1) }
            }
            guard reply.status == 200 else {
                throw CIError.logUnavailable(reply.status == 410 || reply.status == 404 ? "the log has expired or was deleted." : "status \(reply.status).")
            }
            sections += CILogDigest.sections(fromJobLog: String(decoding: reply.body, as: UTF8.self), job: job.name)
        }
        let (excerpt, total) = CILogDigest.excerpt(sections)
        guard !excerpt.isEmpty else { throw CIError.logUnavailable("no failed job had a log.") }
        return CIFailureReport(repository: "\(owner)/\(name)", run: run, jobs: jobs, excerpt: excerpt, totalLines: total, source: "GitHub API")
    }
}

public enum CIFixPrompt {
    /// The brief an agent reads. Facts first, then the task and its limits.
    public static func brief(_ report: CIFailureReport, product: Product, checkout: LocalCheckout?, git: GitSnapshot?) -> String {
        var lines = ["# CI failure: \(report.run.workflow) on \(report.repository)", ""]
        lines.append("- Run: \(report.run.url)")
        lines.append("- Workflow: \(report.run.workflow)\(report.run.isDeployment ? " (deploy or release)" : "")")
        lines.append("- Branch: \(report.run.branch), commit \(shortSHA(report.run.sha))\(report.run.title.isEmpty || report.run.title == report.run.workflow ? "" : " (\(report.run.title))")")
        lines.append("- Finished: \(ISO8601DateFormatter().string(from: report.run.createdAt)), conclusion \(report.run.conclusion)")
        for job in report.failedJobs {
            lines.append("- Failed job: \(job.name)\(job.failedSteps.isEmpty ? "" : ", step: \(job.failedSteps.joined(separator: ", "))")")
        }
        if let checkout {
            if let git {
                let here = git.headSHA.map { $0 == report.run.sha ? "the same commit as the failed run" : "commit \(shortSHA($0)), not the failed run's \(shortSHA(report.run.sha))" } ?? "an unknown commit"
                lines.append("- Local checkout: `\(checkout.path)` is on \(git.branch ?? "a detached HEAD"), \(here)\(git.isDirty ? ", with uncommitted changes" : "").")
            } else {
                lines.append("- Local checkout: `\(checkout.path)` (its Git state was not read; check which commit it is on).")
            }
        }
        lines += ["", "## Log excerpt", "",
                  "The end of each failing step: \(report.totalLines) lines cut to about \(report.approxTokens) tokens. Timestamps removed, secrets redacted.",
                  "", "```", report.excerpt, "```", "",
                  "## Task", "",
                  "1. Find the root cause in this repository. Say what it is before changing anything.",
                  "2. Fix it with the smallest change, and run the same command locally if you can.",
                  "3. If the cause is outside the code (a missing secret, a CI setting, a store key, an expired token), say exactly what must be set and where. Do not invent values.",
                  "4. Do not push, tag, deploy, or re-run the workflow. Leave the commit to me."]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the brief next to the product's CONTEXT.md and returns its path.
    public static func write(_ report: CIFailureReport, product: Product, checkout: LocalCheckout?, git: GitSnapshot?, location: ContextLocation) throws -> URL {
        let folder = location.productFolder(product)
        try location.prepare(folder)
        let file = folder.appending(path: "ci-failure-\(report.run.id).md")
        try Data(brief(report, product: product, checkout: checkout, git: git).utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// The first message for the agent: short, pointing at the brief.
    public static func opening(_ file: URL, run: CIRun) -> String {
        "The GitHub Actions run \"\(run.workflow)\" failed. Read \(file.path) for the failing log and the task, then find and fix the cause. Do not push or deploy."
    }

    /// The agent's command with the opening message. Claude Code and Codex take it as their first prompt; OpenCode with --prompt.
    public static func command(program: URL, bundle: AgentContextBundle, brief: URL, run: CIRun, model: String? = nil) -> [String] {
        // Agents without a system-prompt flag get the brief pointer alone: the brief already names the run.
        let hasSystemPrompt = AgentCatalog.spec(program.lastPathComponent)?.systemPromptFlag != nil
        return AgentCatalog.command(program: program, folders: bundle.readableFolders, pointer: hasSystemPrompt ? bundle.pointer : nil,
                                    message: opening(brief, run: run), model: model, workingDirectory: bundle.workingDirectory)
    }
}
