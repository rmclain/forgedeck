import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ForgeRemoteTests {
    private func product(_ name: String, slug: String, path: String?, demo: Bool = false, lifecycle: Lifecycle = .active) -> Product {
        var product = Product(name: name)
        product.slug = slug
        product.isDemo = demo
        product.lifecycle = lifecycle
        if let path {
            var checkout = LocalCheckout()
            checkout.name = name
            checkout.path = path
            product.checkouts = [checkout]
        }
        return product
    }

    private var portfolio: Portfolio {
        var portfolio = Portfolio()
        portfolio.products = [
            product("Zeta Site", slug: "zeta", path: "/tmp/fd-remote/zeta"),
            product("Alpha API", slug: "alpha", path: "/tmp/fd-remote/alpha"),
            product("Demo Thing", slug: "demo-thing", path: "/tmp/fd-remote/demo", demo: true),
            product("Old Thing", slug: "old", path: "/tmp/fd-remote/old", lifecycle: .archived),
            product("Cloud Only", slug: "cloud", path: nil),
        ]
        return portfolio
    }

    @Test func onlyRealActiveProductsWithAFolderAreReachable() {
        #expect(ForgeRemote.products(in: portfolio).map(\.slug) == ["alpha", "zeta"])
    }

    @Test func theCommandIsAServerThatAsksBeforeChangesByDefault() {
        let argv = ForgeRemote.command(program: URL(fileURLWithPath: "/usr/local/bin/claude"), settings: ForgeRemoteSettings())
        #expect(argv == ["/usr/local/bin/claude", "remote-control", "--name", "Forge Session", "--remote-control-session-name-prefix", "Forge",
                         "--permission-mode", "default", "--spawn", "same-dir"])
        #expect(!argv.contains("bypassPermissions"))
    }

    @Test func anUnknownModeFallsBackToAskingAndANameIsTrimmed() {
        var settings = ForgeRemoteSettings()
        settings.permissionMode = "bypassPermissions"
        settings.name = "  \n  "
        #expect(settings.mode == .ask)
        #expect(ForgeRemote.sessionName(settings) == "Forge Session")
        settings.name = "Mac Studio\nForge"
        #expect(ForgeRemote.sessionName(settings) == "Mac StudioForge")
        #expect(!ForgeRemoteSettings.Mode.allCases.map(\.rawValue).contains("bypassPermissions"))
    }

    @Test func theBriefingIsShortAndSendsTheAgentToTheSkill() {
        let context = ContextLocation(root: URL(fileURLWithPath: "/tmp/fd-remote/context"))
        let text = ForgeRemoteWorkspace.briefing(portfolio: portfolio, context: context, cli: "/Users/me/.local/bin/forgedeck", machine: "Studio")
        #expect(text.contains("`forgedeck` skill"))
        #expect(text.contains("(2 on this Mac)"))
        #expect(text.contains("One product per session"))
        #expect(!text.contains("/tmp/fd-remote/alpha"))
        #expect(text.count < 1_000)
    }

    @Test func theSkillRoutesByTaskThroughTheCLIAndNeverReplacesAForeignSkill() throws {
        let text = ForgeDeckSkill.text(cli: "/Users/me/.local/bin/forgedeck")
        #expect(text.hasPrefix("---\nname: forgedeck\ndescription: "))
        #expect(text.contains("`/Users/me/.local/bin/forgedeck context <slug> --write`"))
        #expect(text.contains("status <slug> --json"))
        #expect(text.contains("ci <slug> --brief"))
        #expect(ForgeDeckSkill.text(cli: "/Apps/My Forge/forgedeck").contains("`\"/Apps/My Forge/forgedeck\" list`"))

        let skills = FileManager.default.temporaryDirectory.appending(path: "fd-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: skills) }
        #expect(try ForgeDeckSkill.install(in: skills, cli: "forgedeck"))
        #expect(try !ForgeDeckSkill.install(in: skills, cli: "forgedeck"))
        #expect(ForgeDeckSkill.isInstalled(in: skills))
        try ForgeDeckSkill.remove(from: skills)
        #expect(!ForgeDeckSkill.isInstalled(in: skills))

        let foreign = skills.appending(path: "forgedeck")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try "---\nname: forgedeck\n---\nmine".write(to: foreign.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try ForgeDeckSkill.install(in: skills, cli: "forgedeck") }
        try ForgeDeckSkill.remove(from: skills)
        #expect(FileManager.default.fileExists(atPath: foreign.appending(path: "SKILL.md").path))
    }

    @Test func folderAccessCoversEveryProductFolderAndTheContextFolder() throws {
        let context = ContextLocation(root: URL(fileURLWithPath: "/tmp/fd-remote/context"))
        let data = try ForgeRemoteWorkspace.settings(portfolio: portfolio, context: context)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let folders = (object["permissions"] as? [String: Any])?["additionalDirectories"] as? [String]
        #expect(folders == ["/tmp/fd-remote/alpha", "/tmp/fd-remote/zeta", "/tmp/fd-remote/context"])
    }

    @Test func writingTwiceReportsNoChangeAndOldSettingsStillLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fd-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = ForgeRemoteWorkspace(folder: folder)
        let context = ContextLocation(root: folder.appending(path: "context"))
        #expect(try workspace.write(portfolio: portfolio, context: context, cli: nil, machine: "Studio"))
        #expect(try !workspace.write(portfolio: portfolio, context: context, cli: nil, machine: "Studio"))
        #expect(FileManager.default.fileExists(atPath: workspace.settingsFile.path))
        #expect(ForgeDeckSkill.isInstalled(in: workspace.skillsFolder))

        let old = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings()))
        #expect(old.remote == nil)
        let partial = try JSONDecoder().decode(ForgeRemoteSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(partial.enabled && partial.keepAwake && partial.mode == .ask && partial.name == "Forge Session")
    }
}

@Suite struct PipeReadTests {
    /// A process that floods its pipe and exits at once used to crash the app: a queued read hit a pipe that had just
    /// been made non-blocking, and `availableData` raised an exception.
    @Test func manyFastProcessesWithLotsOfOutputNeverCrashAndLoseNothing() async throws {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "300000", "/dev/zero"], timeout: 20)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<40 { group.addTask { try await SystemProcessRunner().run(request).stdout.utf8.count } }
            for try await count in group { #expect(count == 300_000) }
        }
    }
}
