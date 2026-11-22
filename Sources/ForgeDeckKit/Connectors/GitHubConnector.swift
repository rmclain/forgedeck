import Foundation

/// GitHub REST, read-only. Works without a token for public repositories and with a
/// fine-grained read token for private ones. The token only ever travels in the
/// Authorization header to api.github.com.
public struct GitHubConnector: RepositoryProvider {
    public static let provider = ProviderKind.github
    public static let capabilities: [ConnectorCapability] = [.repositories, .branches, .pullRequests, .issues, .workflowRuns, .releases, .reportedDeployments]

    public let http: any HTTPClient
    public let token: String?
    public let baseURL: URL
    public let etags: ETagCache

    public init(http: any HTTPClient = URLSessionHTTPClient(), token: String? = nil,
                baseURL: URL = URL(string: "https://api.github.com")!, etags: ETagCache = ETagCache()) {
        self.http = http
        self.token = token
        self.baseURL = baseURL
        self.etags = etags
    }

    public struct Viewer: Sendable, Equatable {
        public var login: String
        public var scopes: [String]
        public var rateLimitRemaining: Int?
        public var rateLimit: Int?
    }

    public struct RepositoryListing: Sendable, Equatable, Identifiable {
        public var id: Int
        public var owner: String
        public var name: String
        public var isPrivate: Bool
        public var isArchived: Bool
        public var defaultBranch: String
        public var description: String
        public var webURL: String
        public var sshURL: String
        public var pushedAt: Date?
        public var language: String?
    }

    private func get(_ path: String, query: [String: String] = [:]) async -> ConnectorResult<(Data, [String: String])> {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            return .failure(.malformed, "bad path")
        }
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { return .failure(.malformed, "bad path") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Brand.name, forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let cached = await etags.entry(for: url.absoluteString)
        if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let response = try await http.send(request)
            // 304 costs nothing against the rate limit: reuse what was stored.
            if response.status == 304, let cached { return .success((cached.body, response.headers)) }
            if let (problem, detail, retry) = HTTPFailure.problem(status: response.status, headers: response.headers) {
                return .failure(problem, detail: detail, retryAfter: retry)
            }
            if let etag = response.headers["etag"] { await etags.store(etag: etag, body: response.body, for: url.absoluteString) }
            return .success((response.body, response.headers))
        } catch {
            let (problem, detail) = HTTPFailure.problem(for: error)
            return .failure(problem, detail)
        }
    }

    private func object(_ path: String, query: [String: String] = [:]) async -> Fetch<[String: Any]> {
        switch await get(path, query: query) {
        case .success(let (data, _)), .partial(let (data, _), _):
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .fail(.malformed, "GitHub returned something that is not a JSON object.", nil)
            }
            return .ok(json)
        case .failure(let problem, let detail, let retry):
            return .fail(problem, detail, retry)
        }
    }

    private func array(_ path: String, query: [String: String] = [:]) async -> Fetch<[[String: Any]]> {
        switch await get(path, query: query) {
        case .success(let (data, _)), .partial(let (data, _), _):
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .fail(.malformed, "GitHub returned something that is not a JSON list.", nil)
            }
            return .ok(json)
        case .failure(let problem, let detail, let retry):
            return .fail(problem, detail, retry)
        }
    }

    public func viewer() async -> ConnectorResult<Viewer> {
        switch await get("/user") {
        case .success(let (data, headers)), .partial(let (data, headers), _):
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let login = json["login"] as? String else {
                return .failure(.malformed, "GitHub did not return an account.")
            }
            let scopes = (headers["x-oauth-scopes"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return .success(Viewer(login: login, scopes: scopes, rateLimitRemaining: headers["x-ratelimit-remaining"].flatMap(Int.init),
                                   rateLimit: headers["x-ratelimit-limit"].flatMap(Int.init)))
        case .failure(let problem, let detail, let retry):
            return .failure(problem, detail: detail, retryAfter: retry)
        }
    }

    /// Lists repositories page by page until a short page, the limit, or cancellation.
    /// `organization` nil lists the signed-in account's repositories.
    public func repositories(organization: String? = nil, limit: Int = 300) async -> ConnectorResult<[RepositoryListing]> {
        var all: [RepositoryListing] = []
        var page = 1
        let perPage = 100
        while all.count < limit {
            if Task.isCancelled { return .failure(.cancelled, "Cancelled") }
            let path = organization.map { "/orgs/\($0)/repos" } ?? "/user/repos"
            let result = await array(path, query: ["per_page": String(perPage), "page": String(page), "sort": "pushed"])
            switch result {
            case .ok(let items):
                all += items.compactMap(Self.listing)
                if items.count < perPage { return .success(Array(all.prefix(limit))) }
                page += 1
            case .fail(let problem, let detail, let retry):
                // Pages already read are still useful.
                if all.isEmpty { return .failure(problem, detail: detail, retryAfter: retry) }
                return .partial(all, missing: ["pages after \(page - 1): \(problem.title)"])
            }
        }
        return .success(Array(all.prefix(limit)))
    }

    /// One entry of `/repos/{owner}/{repo}/issues`. GitHub lists pull requests there too; those return nil.
    static func issue(_ json: [String: Any]) -> GitHubIssueSummary? {
        guard json["pull_request"] == nil, let number = json["number"] as? Int else { return nil }
        var issue = GitHubIssueSummary()
        issue.number = number
        issue.title = json["title"] as? String ?? ""
        issue.author = (json["user"] as? [String: Any])?["login"] as? String ?? ""
        issue.labels = (json["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        issue.comments = json["comments"] as? Int ?? 0
        issue.createdAt = FlexibleDate.parse(json["created_at"] as? String) ?? .distantPast
        issue.updatedAt = FlexibleDate.parse(json["updated_at"] as? String) ?? .distantPast
        issue.url = json["html_url"] as? String ?? ""
        issue.body = String((json["body"] as? String ?? "").prefix(GitHubIssueSummary.bodyLimit))
        return issue
    }

    static func listing(_ json: [String: Any]) -> RepositoryListing? {
        guard let id = json["id"] as? Int, let name = json["name"] as? String,
              let owner = (json["owner"] as? [String: Any])?["login"] as? String else { return nil }
        return RepositoryListing(id: id, owner: owner, name: name, isPrivate: json["private"] as? Bool ?? false,
                                 isArchived: json["archived"] as? Bool ?? false,
                                 defaultBranch: json["default_branch"] as? String ?? "main",
                                 description: json["description"] as? String ?? "",
                                 webURL: json["html_url"] as? String ?? "https://github.com/\(owner)/\(name)",
                                 sshURL: json["ssh_url"] as? String ?? "git@github.com:\(owner)/\(name).git",
                                 pushedAt: FlexibleDate.parse(json["pushed_at"] as? String), language: json["language"] as? String)
    }

    /// Reads everything ForgeDeck shows for one repository. The repository and its default
    /// branch head are required; pull requests, runs, deployments, and releases are
    /// optional parts and are reported as missing when the token cannot read them.
    public func snapshot(owner: String, name: String, environments: [String] = []) async -> ConnectorResult<RemoteSnapshot> {
        let repoPath = "/repos/\(owner)/\(name)"
        var snapshot = RemoteSnapshot()
        var missing: [String] = []
        var hasIssues = true
        switch await object(repoPath) {
        case .ok(let repo):
            snapshot.defaultBranch = repo["default_branch"] as? String ?? "main"
            hasIssues = repo["has_issues"] as? Bool ?? true
        case .fail(let problem, let detail, let retry):
            return .failure(problem, detail: detail, retryAfter: retry)
        }
        switch await object("\(repoPath)/branches/\(snapshot.defaultBranch)") {
        case .ok(let branch):
            let commit = branch["commit"] as? [String: Any]
            snapshot.headSHA = commit?["sha"] as? String
            let inner = commit?["commit"] as? [String: Any]
            snapshot.headMessage = (inner?["message"] as? String)?.split(separator: "\n").first.map(String.init)
            snapshot.headDate = FlexibleDate.parse((inner?["committer"] as? [String: Any])?["date"] as? String)
            if snapshot.headSHA == nil { return .failure(.malformed, "GitHub returned a branch without a commit.") }
        case .fail(let problem, let detail, let retry):
            return .failure(problem, detail: detail, retryAfter: retry)
        }

        switch await array("\(repoPath)/pulls", query: ["state": "open", "per_page": "20"]) {
        case .ok(let pulls):
            snapshot.pullRequests = pulls.compactMap { json in
                guard let number = json["number"] as? Int else { return nil }
                var pr = PullRequestSummary()
                pr.number = number
                pr.title = json["title"] as? String ?? ""
                pr.author = (json["user"] as? [String: Any])?["login"] as? String ?? ""
                pr.isDraft = json["draft"] as? Bool ?? false
                pr.updatedAt = FlexibleDate.parse(json["updated_at"] as? String) ?? .distantPast
                pr.url = json["html_url"] as? String ?? ""
                return pr
            }
        case .fail(let problem, _, _): missing.append("pull requests (\(problem.title))")
        }

        if hasIssues {
            switch await array("\(repoPath)/issues", query: ["state": "open", "sort": "updated", "per_page": "50"]) {
            case .ok(let items): snapshot.issues = items.compactMap(Self.issue)
            case .fail(let problem, _, _): if problem != .notFound { missing.append("issues (\(problem.title))") }
            }
        }

        switch await object("\(repoPath)/actions/runs", query: ["per_page": "15"]) {
        case .ok(let body):
            snapshot.runs = (body["workflow_runs"] as? [[String: Any]] ?? []).compactMap { json in
                guard let id = json["id"] as? Int else { return nil }
                var run = WorkflowRunSummary()
                run.id = id
                run.name = json["name"] as? String ?? ""
                run.branch = json["head_branch"] as? String ?? ""
                run.headSHA = json["head_sha"] as? String ?? ""
                run.status = json["status"] as? String ?? ""
                run.conclusion = json["conclusion"] as? String ?? ""
                run.createdAt = FlexibleDate.parse(json["created_at"] as? String) ?? .distantPast
                run.url = json["html_url"] as? String ?? ""
                return run
            }
        case .fail(let problem, _, _): missing.append("workflow runs (\(problem.title))")
        }

        switch await array("\(repoPath)/deployments", query: ["per_page": "15"]) {
        case .ok(let deployments):
            var seenEnvironments = Set<String>()
            for json in deployments {
                guard let id = json["id"] as? Int else { continue }
                var deployment = ReportedDeployment()
                deployment.id = id
                deployment.environment = json["environment"] as? String ?? ""
                deployment.sha = json["sha"] as? String ?? ""
                deployment.ref = json["ref"] as? String ?? ""
                deployment.createdAt = FlexibleDate.parse(json["created_at"] as? String) ?? .distantPast
                deployment.creator = (json["creator"] as? [String: Any])?["login"] as? String ?? ""
                // A deployment record has no outcome of its own. Only the newest record per
                // environment needs its status, which keeps this to a few requests.
                if seenEnvironments.insert(deployment.environment).inserted,
                   environments.isEmpty || environments.contains(where: { $0.lowercased() == deployment.environment.lowercased() }) {
                    if case .ok(let statuses) = await array("\(repoPath)/deployments/\(id)/statuses", query: ["per_page": "1"]) {
                        deployment.state = statuses.first?["state"] as? String ?? "pending"
                    } else {
                        deployment.state = "unknown"
                    }
                }
                snapshot.deployments.append(deployment)
            }
        case .fail(let problem, _, _): missing.append("deployments (\(problem.title))")
        }

        switch await object("\(repoPath)/releases/latest") {
        case .ok(let release): snapshot.latestReleaseTag = release["tag_name"] as? String
        case .fail(let problem, _, _): if problem != .notFound { missing.append("releases (\(problem.title))") }
        }

        snapshot.provenance = Provenance(source: .githubAPI, level: .verified, ttl: 900)
        return missing.isEmpty ? .success(snapshot) : .partial(snapshot, missing: missing)
    }
}

/// The outcome of one untyped JSON request, used only inside the connector.
enum Fetch<T> {
    case ok(T)
    case fail(ObservationProblem, String, TimeInterval?)
}


public actor ETagCache {
    public struct Entry: Sendable {
        public var etag: String
        public var body: Data
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 400) { self.capacity = capacity }

    public func entry(for key: String) -> Entry? { entries[key] }

    public func store(etag: String, body: Data, for key: String) {
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(etag: etag, body: body)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }
}
