import Foundation
import Testing
@testable import ForgeDeckKit

// Real temporary repositories, built with /usr/bin/git. Nothing leaves the temp folder.

@Suite struct GitSnapshotTests {
    let service = GitService(git: URL(fileURLWithPath: "/usr/bin/git"))

    @Test func cleanRepository() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "repo"))
        let head = try repo.head()
        let snapshot = await service.snapshot(path: repo.path)
        #expect(snapshot.available && snapshot.isRepository)
        #expect(snapshot.branch == "main")
        #expect(!snapshot.isDetached)
        #expect(snapshot.headSHA == head)
        #expect(!snapshot.isDirty)
        #expect(snapshot.stashes == 0)
        #expect(!snapshot.isShallow && !snapshot.isWorktree)
        #expect(snapshot.upstream == nil && snapshot.ahead == nil && snapshot.behind == nil)
        #expect(snapshot.recentCommits.map(\.subject) == ["initial"])
        #expect(snapshot.recentCommits.first?.author == "Test Author")
        #expect(snapshot.summary == "main · clean")
    }

    @Test func stagedUnstagedAndUntrackedAreCountedSeparately() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "repo"))
        try repo.commit(file: "tracked.txt", content: "one\n", message: "add tracked")
        try write("changed\n", to: repo.url.appending(path: "tracked.txt"))        // unstaged
        try write("new\n", to: repo.url.appending(path: "staged.txt"))
        try git(["add", "staged.txt"], in: repo.url)                              // staged
        try write("x\n", to: repo.url.appending(path: "untracked one.txt"))        // untracked
        try write("y\n", to: repo.url.appending(path: "untracked-two.txt"))

        let snapshot = await service.snapshot(path: repo.path)
        #expect(snapshot.staged == 1)
        #expect(snapshot.unstaged == 1)
        #expect(snapshot.untracked == 2)
        #expect(snapshot.conflicted == 0)
        #expect(snapshot.isDirty)
        #expect(snapshot.changeCount == 4)
        #expect(snapshot.summary == "main · 4 uncommitted")
    }

    @Test func aFreshRepositoryWithoutCommits() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        try git(["init", "-q", "-b", "main"], in: root)
        let snapshot = await service.snapshot(path: root.path)
        #expect(snapshot.isRepository)
        #expect(snapshot.headSHA == nil)
        #expect(snapshot.branch == "main")
        #expect(snapshot.recentCommits.isEmpty)
    }

    @Test func mergeConflictIsReported() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "repo"))
        try repo.commit(file: "file.txt", content: "base\n", message: "base")
        try git(["checkout", "-q", "-b", "feature"], in: repo.url)
        try repo.commit(file: "file.txt", content: "feature\n", message: "feature change")
        try git(["checkout", "-q", "main"], in: repo.url)
        try repo.commit(file: "file.txt", content: "main\n", message: "main change")
        let merge = try runTool("/usr/bin/git", ["merge", "feature"], cwd: repo.url, environment: gitTestEnvironment)
        #expect(merge.code != 0)

        let snapshot = await service.snapshot(path: repo.path)
        #expect(snapshot.conflicted == 1)
        #expect(snapshot.isDirty)
        #expect(snapshot.summary == "main · 1 conflicted")
    }

    @Test func detachedHead() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "repo"))
        let first = try repo.head()
        try repo.commit(file: "b.txt", content: "b\n", message: "second")
        try git(["checkout", "-q", "--detach", first], in: repo.url)

        let snapshot = await service.snapshot(path: repo.path)
        #expect(snapshot.isDetached)
        #expect(snapshot.branch == nil)
        #expect(snapshot.headSHA == first)
        #expect(snapshot.summary == "detached \(first.prefix(7)) · clean")
    }

    @Test func stashesAreCounted() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "repo"))
        for index in 1...2 {
            try write("change \(index)\n", to: repo.url.appending(path: "README.md"))
            try git(["stash", "push", "-q", "-m", "wip \(index)"], in: repo.url)
        }
        let snapshot = await service.snapshot(path: repo.path)
        #expect(snapshot.stashes == 2)
        #expect(!snapshot.isDirty)
    }

    @Test func linkedWorktreeIsDetectedBySnapshotAndDiscovery() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "main-checkout"))
        let worktree = root.appending(path: "linked-wt")
        try git(["worktree", "add", "-q", "-b", "feature", worktree.path], in: repo.url)

        let linked = await service.snapshot(path: worktree.path)
        #expect(linked.isRepository)
        #expect(linked.isWorktree)
        #expect(linked.branch == "feature")
        #expect(linked.worktrees.count == 2)
        let main = await service.snapshot(path: repo.path)
        #expect(!main.isWorktree)
        #expect(main.worktrees.count == 2)

        let project = try #require(ProjectDiscovery().inspect(worktree))
        #expect(project.isGitRepository)
        #expect(project.isWorktree)
        let mainPath = try #require(project.mainWorktreePath)
        #expect(realPath(mainPath) == realPath(repo.path))
        let mainProject = try #require(ProjectDiscovery().inspect(repo.url))
        #expect(!mainProject.isWorktree)
        #expect(mainProject.mainWorktreePath == nil)
    }

    @Test func missingFolderIsUnavailable() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let snapshot = await service.snapshot(path: root.appending(path: "gone").path)
        #expect(!snapshot.available)
        #expect(snapshot.problem == "Folder missing")
        #expect(snapshot.summary == "Folder missing")
        // A file where a folder was expected is not a checkout either.
        try write("x", to: root.appending(path: "file"))
        #expect(await service.snapshot(path: root.appending(path: "file").path).available == false)
    }

    @Test func folderThatIsNotARepository() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        try write("hello", to: root.appending(path: "notes.txt"))
        let snapshot = await service.snapshot(path: root.path)
        #expect(snapshot.available)
        #expect(!snapshot.isRepository)
        #expect(snapshot.headSHA == nil)
        #expect(snapshot.summary == "Not a Git repository")
    }

    @Test func hostilePathCharactersAreJustAPath() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let name = "my proj's ünïcødé 日本 $(touch INJECTED) `touch INJECTED2`; touch INJECTED3 & x"
        let repo = try TestRepo.create(at: root.appending(path: name))
        try write("dirty\n", to: repo.url.appending(path: "it's a file $(x).txt"))

        let head = try repo.head()
        let snapshot = await service.snapshot(path: repo.path)
        #expect(snapshot.available && snapshot.isRepository)
        #expect(snapshot.branch == "main")
        #expect(snapshot.headSHA == head)
        #expect(snapshot.untracked == 1)
        #expect(snapshot.recentCommits.count == 1)
        let comparison = await service.compare(head, to: head, path: repo.path)
        #expect(comparison == .same)
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.contains("INJECTED") && !$0.contains(name) }
        #expect(leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo.url.appending(path: "INJECTED").path))
    }

    @Test func shallowCloneIsFlagged() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let source = try TestRepo.create(at: root.appending(path: "source"))
        try source.commit(file: "a.txt", content: "a\n", message: "second")
        try source.commit(file: "b.txt", content: "b\n", message: "third")
        try git(["clone", "-q", "--depth", "1", "file://\(source.path)", root.appending(path: "shallow").path], in: root)

        let shallow = await service.snapshot(path: root.appending(path: "shallow").path)
        #expect(shallow.isShallow)
        #expect(shallow.recentCommits.count == 1)
        #expect(shallow.remotes["origin"] == "file://\(source.path)")
        #expect(await service.snapshot(path: source.path).isShallow == false)
    }

    @Test func aheadAndBehindAgainstAnUpstream() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let bare = root.appending(path: "remote.git")
        try git(["init", "-q", "--bare", "-b", "main", bare.path], in: root)
        let seed = try TestRepo.create(at: root.appending(path: "seed"))
        try git(["remote", "add", "origin", bare.path], in: seed.url)
        try git(["push", "-q", "-u", "origin", "main"], in: seed.url)
        try git(["clone", "-q", bare.path, root.appending(path: "work").path], in: root)
        let work = TestRepo(url: root.appending(path: "work"))

        var snapshot = await service.snapshot(path: work.path)
        #expect(snapshot.upstream == "origin/main")
        #expect(snapshot.ahead == 0 && snapshot.behind == 0)

        try work.commit(file: "local1.txt", content: "1\n", message: "local one")
        try work.commit(file: "local2.txt", content: "2\n", message: "local two")
        snapshot = await service.snapshot(path: work.path)
        #expect(snapshot.ahead == 2 && snapshot.behind == 0)
        #expect(snapshot.summary == "main · 2 ahead")

        try seed.commit(file: "remote.txt", content: "r\n", message: "remote one")
        try git(["push", "-q", "origin", "main"], in: seed.url)
        #expect(await service.fetch(path: work.path)?.ok == true)
        snapshot = await service.snapshot(path: work.path)
        #expect(snapshot.ahead == 2 && snapshot.behind == 1)
        #expect(snapshot.summary == "main · 2 ahead, 1 behind")
        #expect(snapshot.lastFetch != nil)
    }
}

@Suite struct GitCompareTests {
    let service = GitService(git: URL(fileURLWithPath: "/usr/bin/git"))

    @Test func sameAheadBehindAndDiverged() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "repo"))
        let base = try repo.head()
        let second = try repo.commit(file: "a.txt", content: "a\n", message: "second")
        let third = try repo.commit(file: "b.txt", content: "b\n", message: "third")
        try git(["checkout", "-q", "-b", "side", base], in: repo.url)
        let side = try repo.commit(file: "side.txt", content: "s\n", message: "side")

        #expect(await service.compare(third, to: third, path: repo.path) == .same)
        #expect(await service.compare(third, to: base, path: repo.path) == .ahead(2))
        #expect(await service.compare(base, to: third, path: repo.path) == .behind(2))
        #expect(await service.compare(second, to: third, path: repo.path) == .behind(1))
        #expect(await service.compare(third, to: side, path: repo.path) == .diverged(ahead: 2, behind: 1))
        // Abbreviated object names work too.
        #expect(await service.compare(String(third.prefix(10)), to: String(base.prefix(10)), path: repo.path) == .ahead(2))
    }

    @Test func aCommitThatWasNeverFetchedIsNotEnoughHistory() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "repo"))
        let head = try repo.head()
        let unknown = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        #expect(await service.compare(head, to: unknown, path: repo.path) == .notEnoughHistory)
        #expect(await service.compare(unknown, to: head, path: repo.path) == .notEnoughHistory)
    }

    @Test func aShallowCloneCannotCountPastItsBoundary() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let source = try TestRepo.create(at: root.appending(path: "source"))
        let first = try source.head()
        let last = try source.commit(file: "a.txt", content: "a\n", message: "second")
        try git(["clone", "-q", "--depth", "1", "file://\(source.path)", root.appending(path: "shallow").path], in: root)
        let comparison = await service.compare(last, to: first, path: root.appending(path: "shallow").path)
        #expect(comparison == .notEnoughHistory)
    }

    @Test func optionLookingRevisionsNeverReachGit() async throws {
        let root = try makeTempDir("git")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "repo"))
        let head = try repo.head()
        let runner = FakeRunner(result: ProcessResult(exitCode: 0, stdout: "0\t0\n"))
        let spied = GitService(runner: runner, git: URL(fileURLWithPath: "/usr/bin/git"))
        for hostile in ["--upload-pack=x", "-h", "HEAD", "main", "HEAD~1", "abc", "$(id)", "abcd;rm", "", String(repeating: "a", count: 65)] {
            #expect(await spied.compare(hostile, to: head, path: repo.path) == .unknown, "\(hostile)")
            #expect(await spied.compare(head, to: hostile, path: repo.path) == .unknown, "\(hostile)")
        }
        #expect(runner.requests.isEmpty)
        #expect(!GitService.isRevision("--upload-pack=x"))
        #expect(GitService.isRevision(head))
        #expect(GitService.isRevision("ABCDEF12"))
    }

    @Test func compareInAMissingFolderIsUnknown() async {
        let comparison = await service.compare(shaA, to: shaB, path: "/nonexistent/forgedeck-tests/\(UUID().uuidString)")
        #expect(comparison == .unknown)
    }
}

@Suite struct GitCloneTests {
    let service = GitService(git: URL(fileURLWithPath: "/usr/bin/git"))

    /// A bare repository at <root>/acme/widget.git with one commit.
    private func makeBareRemote(in root: URL) throws -> URL {
        let bare = root.appending(path: "acme/widget.git")
        try FileManager.default.createDirectory(at: bare.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", "-b", "main", bare.path], in: root)
        let seed = try TestRepo.create(at: root.appending(path: "seed"))
        try git(["push", "-q", bare.path, "main"], in: seed.url)
        return bare
    }

    @Test func cloneIntoAnExistingFolderIsRefusedAndLeavesItUntouched() async throws {
        let root = try makeTempDir("clone")
        defer { removeTemp(root) }
        let bare = try makeBareRemote(in: root)
        let parent = root.appending(path: "code")
        let existing = parent.appending(path: "widget")
        try write("precious", to: existing.appending(path: "keep.txt"))

        await #expect(throws: GitService.CloneError.destinationExists(existing.path)) {
            _ = try await service.clone(url: "file://localhost\(bare.path)", into: parent, name: "widget")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path) == ["keep.txt"])
        #expect(try String(contentsOf: existing.appending(path: "keep.txt"), encoding: .utf8) == "precious")
    }

    @Test func anExistingFileAlsoBlocksTheClone() async throws {
        let root = try makeTempDir("clone")
        defer { removeTemp(root) }
        let bare = try makeBareRemote(in: root)
        try write("a file", to: root.appending(path: "code/widget"))
        await #expect(throws: GitService.CloneError.self) {
            _ = try await service.clone(url: "file://localhost\(bare.path)", into: root.appending(path: "code"), name: "widget")
        }
        #expect(try String(contentsOf: root.appending(path: "code/widget"), encoding: .utf8) == "a file")
    }

    @Test func cloneFromALocalBareRepositoryWorks() async throws {
        let root = try makeTempDir("clone")
        defer { removeTemp(root) }
        let bare = try makeBareRemote(in: root)
        let parent = root.appending(path: "code")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let destination = try await service.clone(url: "file://localhost\(bare.path)", into: parent, name: "widget copy")
        #expect(destination.path == parent.appending(path: "widget copy").path)
        let snapshot = await service.snapshot(path: destination.path)
        #expect(snapshot.isRepository)
        #expect(snapshot.branch == "main")
        #expect(snapshot.recentCommits.map(\.subject) == ["initial"])
        #expect(snapshot.upstream == "origin/main")
    }

    @Test func invalidOrOptionLookingURLsAreRejectedBeforeGitRuns() async throws {
        let root = try makeTempDir("clone")
        defer { removeTemp(root) }
        let runner = FakeRunner(result: ProcessResult(exitCode: 0))
        let spied = GitService(runner: runner, git: URL(fileURLWithPath: "/usr/bin/git"))
        for url in ["--upload-pack=touch /tmp/x", "-oProxyCommand=x", "", "not a url", "-x/y"] {
            await #expect(throws: GitService.CloneError.invalidURL, "\(url)") {
                _ = try await spied.clone(url: url, into: root, name: "x")
            }
        }
        #expect(runner.requests.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func cloneArgumentsEndOptionParsingBeforeTheURL() async throws {
        let root = try makeTempDir("clone")
        defer { removeTemp(root) }
        let runner = FakeRunner(result: ProcessResult(exitCode: 0))
        let spied = GitService(runner: runner, git: URL(fileURLWithPath: "/usr/bin/git"))
        _ = try await spied.clone(url: "https://github.com/acme/widget.git", into: root, name: "widget")
        let arguments = try #require(runner.requests.first?.arguments)
        #expect(arguments == ["clone", "--", "https://github.com/acme/widget.git", root.appending(path: "widget").path])
        #expect(runner.requests.first?.environment?["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test func aFailedCloneReportsARedactedReason() async throws {
        let root = try makeTempDir("clone")
        defer { removeTemp(root) }
        let token = "ghp_" + String(repeating: "a1B2", count: 8)
        let runner = FakeRunner(result: ProcessResult(exitCode: 128, stderr: "fatal: unable to access 'https://user:\(token)@github.com/acme/widget.git/'\n"))
        let spied = GitService(runner: runner, git: URL(fileURLWithPath: "/usr/bin/git"))
        do {
            _ = try await spied.clone(url: "https://github.com/acme/widget.git", into: root, name: "widget")
            Issue.record("the clone should have failed")
        } catch let error as GitService.CloneError {
            guard case .failed(let reason) = error else { Issue.record("wrong error \(error)"); return }
            #expect(!reason.contains(token))
            #expect(reason.contains("unable to access"))
        }
    }
}

@Suite struct RepositoryURLTests {
    @Test func httpsForms() {
        let plain = RepositoryURL.parse("https://github.com/acme/widget")
        #expect(plain == RepositoryURL(host: "github.com", owner: "acme", name: "widget"))
        #expect(RepositoryURL.parse("https://github.com/acme/widget.git") == plain)
        #expect(RepositoryURL.parse("https://GitHub.com/acme/widget/") == plain)
        #expect(RepositoryURL.parse("  https://github.com/acme/widget\n") == plain)
        #expect(plain?.webURL == "https://github.com/acme/widget")
        #expect(plain?.provider == "github")
    }

    /// BUG (GitService.swift, RepositoryURL.parse): ".git" is stripped before trailing slashes, so
    /// "https://github.com/acme/widget.git/" (the form git itself prints in error messages) yields the
    /// repository name "widget.git". Fix: strip trailing slashes first, then the ".git" suffix.
    @Test func dotGitFollowedByASlashIsStillStripped() {
        #expect(RepositoryURL.parse("https://github.com/acme/widget.git/")?.name == "widget")
    }

    @Test func scpStyleAndSSHForms() {
        #expect(RepositoryURL.parse("git@github.com:acme/widget.git") == RepositoryURL(host: "github.com", owner: "acme", name: "widget"))
        #expect(RepositoryURL.parse("ssh://git@gitlab.example.com/acme/widget") == RepositoryURL(host: "gitlab.example.com", owner: "acme", name: "widget"))
        #expect(RepositoryURL.parse("ssh://git@host.example:2222/acme/widget.git") == RepositoryURL(host: "host.example", owner: "acme", name: "widget"))
        #expect(RepositoryURL.parse("ssh://git@gitlab.example.com/acme/widget")?.provider == "gitlab")
        #expect(RepositoryURL.parse("git@bitbucket.org:team/thing.git")?.provider == "bitbucket")
    }

    @Test func ownerSlashRepoShorthandMeansGitHub() {
        #expect(RepositoryURL.parse("acme/widget") == RepositoryURL(host: "github.com", owner: "acme", name: "widget"))
        #expect(RepositoryURL.parse("acme/widget.js")?.name == "widget.js")
    }

    @Test func credentialsInTheURLDoNotBecomeTheHost() {
        let parsed = RepositoryURL.parse("https://user:ghp_xxxxxxxxxxxxxxxxxxxxxxxx@github.com/o/r.git")
        #expect(parsed == RepositoryURL(host: "github.com", owner: "o", name: "r"))
        #expect(parsed?.webURL == "https://github.com/o/r")
    }

    @Test func garbageIsRejected() {
        for text in ["", "   ", "widget", "not a url", "https://github.com", "https://github.com/onlyowner", "a/b/c",
                     "https://github.com/ac me/widget", "acme/wid$get", "acme/$(id)", "acme/wid;get", "git@github.com:acme",
                     "https:///acme/widget", "acme/widget\nrm -rf"] {
            #expect(RepositoryURL.parse(text) == nil, "\(text)")
        }
    }

    @Test func optionLookingInputIsRejected() {
        for text in ["--upload-pack=x", "-oProxyCommand=evil", "--upload-pack=touch /tmp/x", "-oProxyCommand=x/y"] {
            #expect(RepositoryURL.parse(text) == nil, "\(text)")
        }
    }

    /// BUG (GitService.swift, RepositoryURL.parse): "-x/y" passes the owner/repo shorthand because "-" is in the
    /// allowed character set, so a value that starts with a dash parses as owner "-x". `GitService.clone` guards
    /// against it separately and passes "--", so nothing runs, but every other caller of `parse` gets a
    /// repository whose owner looks like an option. Fix: reject an owner, name, or host that starts with "-".
    @Test func aLeadingDashIsNeverAnOwner() {
        #expect(RepositoryURL.parse("-x/y") == nil)
        #expect(RepositoryURL.parse("--flag/repo") == nil)
    }
}
