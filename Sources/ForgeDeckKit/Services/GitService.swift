import Foundation

/// Reads a checkout with the system `git`. Read-only except `fetch`, which the user starts.
public struct GitService: Sendable {
    public let runner: any ProcessRunning
    public let git: URL

    public init(runner: any ProcessRunning = SystemProcessRunner(), git: URL? = nil) {
        self.runner = runner
        self.git = git ?? ExecutableLocator.find("git") ?? URL(fileURLWithPath: "/usr/bin/git")
    }

    /// No prompts, no pager, no optional locks: inspection must never hang or write.
    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        return env
    }

    private func run(_ arguments: [String], in directory: URL, timeout: TimeInterval = 20) async -> ProcessResult? {
        try? await runner.run(ProcessRequest(executable: git, arguments: arguments, workingDirectory: directory,
                                             environment: environment, timeout: timeout))
    }

    public func snapshot(path: String, commitLimit: Int = 8) async -> GitSnapshot {
        var snapshot = GitSnapshot()
        snapshot.observedAt = .now
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            snapshot.available = false
            snapshot.problem = "Folder missing"
            return snapshot
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let inside = await run(["rev-parse", "--is-inside-work-tree"], in: directory), inside.ok,
              inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            snapshot.isRepository = false
            return snapshot
        }
        if let status = await run(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: directory), status.ok {
            Self.parseStatus(status.stdout, into: &snapshot)
        }
        if let stash = await run(["stash", "list", "--format=%H"], in: directory), stash.ok {
            snapshot.stashes = stash.stdout.split(separator: "\n").count
        }
        if let shallow = await run(["rev-parse", "--is-shallow-repository"], in: directory), shallow.ok {
            snapshot.isShallow = shallow.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        if let remotes = await run(["remote", "-v"], in: directory), remotes.ok {
            snapshot.remotes = Self.parseRemotes(remotes.stdout)
        }
        if let worktrees = await run(["worktree", "list", "--porcelain"], in: directory), worktrees.ok {
            snapshot.worktrees = worktrees.stdout.split(separator: "\n")
                .filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst("worktree ".count)) }
        }
        if let dirs = await run(["rev-parse", "--git-dir", "--git-common-dir"], in: directory), dirs.ok {
            let lines = dirs.stdout.split(separator: "\n").map(String.init)
            if lines.count == 2 {
                let gitDir = URL(fileURLWithPath: lines[0], relativeTo: directory).standardizedFileURL.path
                let common = URL(fileURLWithPath: lines[1], relativeTo: directory).standardizedFileURL.path
                snapshot.isWorktree = gitDir != common
                let fetchHead = (common as NSString).appendingPathComponent("FETCH_HEAD")
                snapshot.lastFetch = (try? FileManager.default.attributesOfItem(atPath: fetchHead))?[.modificationDate] as? Date
            }
        }
        if snapshot.headSHA != nil,
           let log = await run(["log", "-n", String(commitLimit), "--format=%H%x1f%an%x1f%aI%x1f%s"], in: directory), log.ok {
            snapshot.recentCommits = Self.parseLog(log.stdout)
        }
        return snapshot
    }

    static func parseStatus(_ text: String, into snapshot: inout GitSnapshot) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.oid ") {
                let oid = String(line.dropFirst("# branch.oid ".count))
                snapshot.headSHA = oid == "(initial)" ? nil : oid
            } else if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                if head == "(detached)" { snapshot.isDetached = true } else { snapshot.branch = head }
            } else if line.hasPrefix("# branch.upstream ") {
                snapshot.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 {
                    snapshot.ahead = Int(parts[0].dropFirst())
                    snapshot.behind = Int(parts[1].dropFirst())
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let fields = line.split(separator: " ", maxSplits: 2)
                guard fields.count > 1 else { continue }
                let xy = Array(fields[1])
                if xy.count == 2 {
                    if xy[0] != "." { snapshot.staged += 1 }
                    if xy[1] != "." { snapshot.unstaged += 1 }
                }
            } else if line.hasPrefix("u ") {
                snapshot.conflicted += 1
            } else if line.hasPrefix("? ") {
                snapshot.untracked += 1
            }
        }
    }

    static func parseRemotes(_ text: String) -> [String: String] {
        var remotes: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2, remotes[String(parts[0])] == nil { remotes[String(parts[0])] = String(parts[1]) }
        }
        return remotes
    }

    static func parseLog(_ text: String) -> [CommitSummary] {
        let formatter = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { return nil }
            return CommitSummary(sha: fields[0], subject: fields[3], author: fields[1],
                                 date: formatter.date(from: fields[2]) ?? .distantPast)
        }
    }

    /// Compares two commits using only what is in the local object database.
    /// A commit that was never fetched gives `.notEnoughHistory`, never a guess.
    public func compare(_ a: String, to b: String, path: String) async -> RevisionComparison {
        guard Self.isRevision(a), Self.isRevision(b) else { return .unknown }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        for sha in [a, b] {
            guard let exists = await run(["cat-file", "-e", "\(sha)^{commit}"], in: directory), exists.ok else {
                return .notEnoughHistory
            }
        }
        guard let count = await run(["rev-list", "--left-right", "--count", "\(a)...\(b)"], in: directory), count.ok else {
            return .notEnoughHistory
        }
        let parts = count.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard parts.count == 2 else { return .unknown }
        switch (parts[0], parts[1]) {
        case (0, 0): return .same
        case (let ahead, 0): return .ahead(ahead)
        case (0, let behind): return .behind(behind)
        case (let ahead, let behind): return .diverged(ahead: ahead, behind: behind)
        }
    }

    /// Only hex object names reach git as revisions, so a value from a remote API can never be read as an option.
    public static func isRevision(_ text: String) -> Bool {
        (4...64).contains(text.count) && text.allSatisfy(\.isHexDigit)
    }

    /// `git fetch` for one checkout. Network, started by the user or the refresh policy.
    public func fetch(path: String) async -> ProcessResult? {
        await run(["fetch", "--quiet", "--prune", "--no-tags"], in: URL(fileURLWithPath: path, isDirectory: true), timeout: 60)
    }

    /// The `origin` URL as configured, before any `insteadOf` rewrite. Nil when the checkout has none.
    public func origin(path: String) async -> String? {
        guard let result = await run(["config", "--get", "remote.origin.url"], in: URL(fileURLWithPath: path, isDirectory: true)), result.ok else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// `git remote set-url origin <url>` for one checkout. A local write the person asks for.
    public func setOrigin(path: String, url: String) async -> Bool {
        guard RepositoryURL.parse(url) != nil, !url.hasPrefix("-") else { return false }
        return await run(["remote", "set-url", "origin", url], in: URL(fileURLWithPath: path, isDirectory: true))?.ok == true
    }

    public enum CloneError: Error, CustomStringConvertible, Equatable {
        case destinationExists(String)
        case invalidURL
        case failed(String)

        public var description: String {
            switch self {
            case .destinationExists(let path): "\(path) already exists. Choose another folder: nothing was overwritten."
            case .invalidURL: "That is not a repository URL."
            case .failed(let why): "Clone failed: \(why)"
            }
        }
    }

    /// Clones into `parent/name`. Refuses when anything is already there.
    public func clone(url: String, into parent: URL, name: String) async throws -> URL {
        guard RepositoryURL.parse(url) != nil, !url.hasPrefix("-") else { throw CloneError.invalidURL }
        let destination = parent.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CloneError.destinationExists(destination.path)
        }
        let result = try await runner.run(ProcessRequest(executable: git, arguments: ["clone", "--", url, destination.path],
                                                         workingDirectory: parent, environment: environment, timeout: 600))
        guard result.ok else { throw CloneError.failed(Redactor().redact(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))) }
        return destination
    }
}

/// Parses repository URLs: https://github.com/o/r(.git), git@github.com:o/r.git, ssh://git@host/o/r.
public struct RepositoryURL: Hashable, Sendable {
    public var host: String
    public var owner: String
    public var name: String

    public var webURL: String { "https://\(host)/\(owner)/\(name)" }
    public var provider: String { host.contains("github") ? "github" : host.contains("gitlab") ? "gitlab" : host.contains("bitbucket") ? "bitbucket" : "git" }

    public static func parse(_ text: String) -> RepositoryURL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("\n") else { return nil }
        var host = "", path = ""
        if let range = trimmed.range(of: "://") {
            let rest = trimmed[range.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        } else if let at = trimmed.firstIndex(of: "@"), let colon = trimmed[at...].firstIndex(of: ":") {
            host = String(trimmed[trimmed.index(after: at)..<colon])
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            // "owner/repo" shorthand means GitHub.
            let parts = trimmed.split(separator: "/")
            guard parts.count == 2 else { return nil }
            host = "github.com"
            path = trimmed
        }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !host.isEmpty else { return nil }
        let valid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let owner = parts[parts.count - 2], name = parts[parts.count - 1]
        guard owner.unicodeScalars.allSatisfy(valid.contains), name.unicodeScalars.allSatisfy(valid.contains),
              host.unicodeScalars.allSatisfy(valid.contains),
              !owner.hasPrefix("-"), !name.hasPrefix("-"), !host.hasPrefix("-") else { return nil }
        return RepositoryURL(host: host.lowercased(), owner: owner, name: name)
    }
}
