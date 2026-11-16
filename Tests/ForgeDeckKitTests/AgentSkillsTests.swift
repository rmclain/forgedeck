import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct AgentSkillsTests {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func skillFile(_ name: String, _ description: String = "Does a thing.") -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n"
    }

    /// A repository shaped like the real ones: one copy per agent, a plain skills/ folder, a template, and a test fixture.
    private func makeRepository() throws -> URL {
        let root = try makeTempDir("skills-repo")
        try write(skillFile("impeccable", "Claude copy"), to: root.appending(path: ".claude/skills/impeccable/SKILL.md"))
        try write("claude", to: root.appending(path: ".claude/skills/impeccable/reference/a.md"))
        try write(skillFile("impeccable", "Agents copy"), to: root.appending(path: ".agents/skills/impeccable/SKILL.md"))
        try write(skillFile("impeccable", "Cursor copy"), to: root.appending(path: ".cursor/skills/impeccable/SKILL.md"))
        try write(skillFile("pdf"), to: root.appending(path: "skills/pdf/SKILL.md"))
        try write(skillFile("starter"), to: root.appending(path: "template/SKILL.md"))
        try write(skillFile("fixture"), to: root.appending(path: "tests/oracle/.claude/skills/fixture/SKILL.md"))
        try write(skillFile("x"), to: root.appending(path: "node_modules/pkg/skills/x/SKILL.md"))
        return root
    }

    @Test func repositoryNamesAreParsedFromCommonForms() {
        #expect(AgentSkills.parseRepository("pbakaus/impeccable") == "pbakaus/impeccable")
        #expect(AgentSkills.parseRepository("https://github.com/obra/superpowers") == "obra/superpowers")
        #expect(AgentSkills.parseRepository("github.com/anthropics/skills/tree/main/skills/pdf") == "anthropics/skills")
        #expect(AgentSkills.parseRepository("https://github.com/heygen-com/hyperframes.git ") == "heygen-com/hyperframes")
        #expect(AgentSkills.parseRepository("git@github.com:openai/skills.git") == "openai/skills")
        #expect(AgentSkills.parseRepository("https://gitlab.com/a/b") == nil)
        #expect(AgentSkills.parseRepository("owner/repo; rm -rf ~") == nil)
        #expect(AgentSkills.parseRepository("../etc") == nil)
        #expect(AgentSkills.parseRepository("-x/y") == nil)
    }

    @Test func npxSkillsCommandsAreReadNotRun() throws {
        let plain = try #require(AgentSkills.parseSource("npx skills add vercel-labs/agent-skills"))
        #expect(plain == AgentSkills.Source(repository: "vercel-labs/agent-skills", fromCommand: true))

        let named = try #require(AgentSkills.parseSource("npx -y skills@latest add vercel-labs/agent-skills --skill web-design-guidelines react-best-practices -a claude-code -g"))
        #expect(named.skills == ["web-design-guidelines", "react-best-practices"] && named.targets == [.claude])

        let pinned = try #require(AgentSkills.parseSource("bunx skills add owner/repo@v1.2.3 -s my-skill -a codex"))
        #expect(pinned.repository == "owner/repo" && pinned.ref == "v1.2.3" && pinned.skills == ["my-skill"] && pinned.targets == [.agents])

        let tree = try #require(AgentSkills.parseSource("pnpm dlx skills add https://github.com/vercel-labs/agent-skills/tree/main/skills/web-design-guidelines"))
        #expect(tree.ref == "main" && tree.skills == ["web-design-guidelines"])

        let all = try #require(AgentSkills.parseSource("npx skills add anthropics/skills --skill '*' --all"))
        #expect(all.skills == nil && all.targets == Set(SkillTarget.allCases))

        let use = try #require(AgentSkills.parseSource("npx skills use vercel-labs/agent-skills@web-design-guidelines --agent claude-code"))
        #expect(use.ref == nil && use.skills == ["web-design-guidelines"])

        #expect(AgentSkills.parseSource("npx skills add git@github.com:obra/superpowers.git")?.repository == "obra/superpowers")
        #expect(AgentSkills.parseSource("pbakaus/impeccable") == AgentSkills.Source(repository: "pbakaus/impeccable"))
        // Not GitHub, not a skills command, or a ref that could be read as a git option.
        #expect(AgentSkills.parseSource("npx skills add https://gitlab.com/org/repo") == nil)
        #expect(AgentSkills.parseSource("npx create-react-app owner/repo") == nil)
        #expect(AgentSkills.parseSource("npx skills add owner/repo@--upload-pack=x") == nil)
        #expect(AgentSkills.parseSource("npx skills add owner/repo; rm -rf ~") == nil)
    }

    @Test func aRefIsFetchedOnItsOwn() async throws {
        let runner = FakeRunner { request in
            request.arguments.last == "HEAD" ? ProcessResult(exitCode: 0, stdout: "abc123\n") : ProcessResult(exitCode: 0)
        }
        let commit = try await AgentSkills.fetch("owner/repo", ref: "v1.2.3", into: URL(fileURLWithPath: "/tmp/skills-x"), runner: runner)
        #expect(commit == "abc123")
        let calls = runner.requests.map(\.arguments)
        #expect(calls[0] == ["init", "--quiet", "/tmp/skills-x"])
        #expect(calls[1] == ["-C", "/tmp/skills-x", "fetch", "--depth", "1", "--no-tags", "--quiet", "https://github.com/owner/repo.git", "v1.2.3"])
        #expect(calls[2].suffix(2) == ["--quiet", "FETCH_HEAD"])
        await #expect(throws: SkillError.self) { try await AgentSkills.fetch("owner/repo", ref: "-x", into: URL(fileURLWithPath: "/tmp/y"), runner: runner) }
    }

    @Test func catalogRepositoriesAreValid() {
        let ids = AgentSkills.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        for repository in AgentSkills.catalog {
            #expect(UpdateChecker.isValidRepository(repository.id), "\(repository.id)")
            #expect(!repository.summary.isEmpty && !repository.knownSkills.isEmpty, "\(repository.id)")
            #expect(repository.knownSkills.allSatisfy(AgentSkills.isSafeName), "\(repository.id)")
        }
    }

    @Test func discoveryGroupsCopiesAndSkipsFixtures() throws {
        let root = try makeRepository()
        defer { removeTemp(root) }
        let found = AgentSkills.discover(in: root)
        #expect(found.map(\.name) == ["impeccable", "pdf", "starter"])
        let impeccable = try #require(found.first { $0.name == "impeccable" })
        #expect(impeccable.sources.count == 3)
        #expect(impeccable.recommended)
        #expect(impeccable.source(for: .claude) == ".claude/skills/impeccable")
        #expect(impeccable.source(for: .agents) == ".agents/skills/impeccable")
        #expect(found.first { $0.name == "pdf" }?.source(for: .claude) == "skills/pdf")
        #expect(impeccable.answers(to: "impeccable") && !impeccable.answers(to: "pdf"))
        #expect(found.first { $0.name == "starter" }?.recommended == false, "a template outside skills/ is not picked by default")
    }

    @Test func frontMatterReadsPlainQuotedAndFoldedValues() {
        #expect(AgentSkills.frontmatter("---\nname: a\ndescription: \"Quoted: yes\"\n---").description == "Quoted: yes")
        let folded = AgentSkills.frontmatter("---\nname: b\ndescription: >\n  First line\n  second line\nlicense: MIT\n---\n")
        #expect(folded.name == "b" && folded.description == "First line second line")
        #expect(AgentSkills.frontmatter("# no front matter").name == nil)
    }

    @Test func unsafeNamesAreRejected() {
        for bad in ["", ".hidden", "../up", "a/b", "a b", "na;me", String(repeating: "a", count: 65)] {
            #expect(!AgentSkills.isSafeName(bad), "\(bad)")
        }
        #expect(AgentSkills.isSafeName("react-best-practices"))
    }

    @Test func installCopiesTheRightCopyAndWritesAReceipt() throws {
        let root = try makeRepository()
        let home = try makeTempDir("skills-home")
        defer { removeTemp(root); removeTemp(home) }
        let impeccable = try #require(AgentSkills.discover(in: root).first { $0.name == "impeccable" })
        let result = try AgentSkills.install(impeccable, from: root, repository: "pbakaus/impeccable", commit: "abc", target: .claude, home: home)
        #expect(result == .installed)
        let folder = home.appending(path: ".claude/skills/impeccable")
        #expect(try String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8).contains("Claude copy"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "reference/a.md").path))
        #expect(AgentSkills.receipt(in: folder)?.repository == "pbakaus/impeccable")
        #expect(AgentSkills.installed(home: home).map(\.id) == ["claude/impeccable"])

        // Installing again replaces only ForgeDeck's own copy; the old one goes to discard.
        var discarded: [String] = []
        let again = try AgentSkills.install(impeccable, from: root, repository: "pbakaus/impeccable", commit: "def", target: .claude, home: home) {
            discarded.append($0.lastPathComponent)
            try FileManager.default.removeItem(at: $0)
        }
        #expect(again == .updated && discarded == ["impeccable"])
        #expect(AgentSkills.receipt(in: folder)?.commit == "def")
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".claude/skills/.impeccable.forgedeck-new").path))
    }

    @Test func aSkillInstalledSomeOtherWayIsNeverReplacedOrRemoved() throws {
        let root = try makeRepository()
        let home = try makeTempDir("skills-home")
        defer { removeTemp(root); removeTemp(home) }
        try write("mine", to: home.appending(path: ".claude/skills/pdf/SKILL.md"))
        let pdf = try #require(AgentSkills.discover(in: root).first { $0.name == "pdf" })
        #expect(AgentSkills.state(of: "pdf", target: .claude, home: home) == .foreign)
        #expect(try AgentSkills.install(pdf, from: root, repository: "anthropics/skills", commit: "1", target: .claude, home: home) == .keptExisting)
        #expect(try String(contentsOf: home.appending(path: ".claude/skills/pdf/SKILL.md"), encoding: .utf8) == "mine")
        #expect(throws: SkillError.notOurs("pdf")) { try AgentSkills.remove("pdf", target: .claude, home: home) { _ in } }
    }

    @Test func aLinkOutOfTheSkillFolderIsRefused() throws {
        let root = try makeRepository()
        let home = try makeTempDir("skills-home")
        defer { removeTemp(root); removeTemp(home) }
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "skills/pdf/secrets").path, withDestinationPath: NSHomeDirectory() + "/.ssh")
        let pdf = try #require(AgentSkills.discover(in: root).first { $0.name == "pdf" })
        #expect(throws: SkillError.unsafeLink("secrets")) {
            try AgentSkills.install(pdf, from: root, repository: "anthropics/skills", commit: "1", target: .claude, home: home)
        }
        #expect(AgentSkills.state(of: "pdf", target: .claude, home: home) == .new)
    }

    @Test func removeSendsOnlyOurSkillToTheTrash() throws {
        let root = try makeRepository()
        let home = try makeTempDir("skills-home")
        defer { removeTemp(root); removeTemp(home) }
        let pdf = try #require(AgentSkills.discover(in: root).first { $0.name == "pdf" })
        try AgentSkills.install(pdf, from: root, repository: "anthropics/skills", commit: "1", target: .agents, home: home)
        var discarded: [URL] = []
        try AgentSkills.remove("pdf", target: .agents, home: home) { discarded.append($0) }
        #expect(discarded.map(\.lastPathComponent) == ["pdf"])
    }

    @Test func cloneIsShallowAndCannotPrompt() {
        let request = AgentSkills.cloneRequest("pbakaus/impeccable", into: URL(fileURLWithPath: "/tmp/x"), git: URL(fileURLWithPath: "/usr/bin/git"))
        #expect(request.arguments == ["clone", "--depth", "1", "--single-branch", "--no-tags", "--quiet", "https://github.com/pbakaus/impeccable.git", "/tmp/x"])
        #expect(request.environment?["GIT_TERMINAL_PROMPT"] == "0")
        #expect(request.stdin == Data())
    }
}
