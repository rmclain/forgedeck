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

    @Test func theBriefingListsEachProductOnceWithItsContextFileAndTheOneProductRule() {
        let context = ContextLocation(root: URL(fileURLWithPath: "/tmp/fd-remote/context"))
        let text = ForgeRemoteWorkspace.briefing(portfolio: portfolio, context: context, cli: "/Users/me/.local/bin/forgedeck", machine: "Studio")
        #expect(text.contains("| Alpha API | `alpha` |"))
        #expect(text.contains("`/tmp/fd-remote/context/zeta/CONTEXT.md`"))
        #expect(!text.contains("Demo Thing"))
        #expect(!text.contains("Old Thing"))
        #expect(!text.contains("Cloud Only"))
        #expect(text.contains("One product per session"))
        #expect(text.contains("/Users/me/.local/bin/forgedeck exec"))
        #expect(text.range(of: "Alpha API")!.lowerBound < text.range(of: "Zeta Site")!.lowerBound)
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

        let old = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings()))
        #expect(old.remote == nil)
        let partial = try JSONDecoder().decode(ForgeRemoteSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(partial.enabled && partial.keepAwake && partial.mode == .ask && partial.name == "Forge Session")
    }
}
