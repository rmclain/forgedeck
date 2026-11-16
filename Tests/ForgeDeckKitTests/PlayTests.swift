import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct OrganizeTests {
    func portfolio() -> (Portfolio, UUID, UUID) {
        var portfolio = Portfolio()
        let a = Product(name: "Alpha", group: "Clients")
        let b = Product(name: "Beta", group: "Internal")
        portfolio.products = [a, b]
        return (portfolio, a.id, b.id)
    }

    @Test func renamingAGroupMovesEveryProductInItAndCanMerge() {
        var (portfolio, a, b) = portfolio()
        let r6 = portfolio.renameGroup("Clients", to: "  Client Work ")
        #expect(r6 == 1)
        #expect(portfolio.product(id: a)?.group == "Client Work")
        let r7 = portfolio.renameGroup("Internal", to: "Client Work")
        #expect(r7 == 1)
        #expect(portfolio.groups == ["Client Work"])
        #expect(portfolio.product(id: b)?.group == "Client Work")
        let r8 = portfolio.renameGroup("Client Work", to: "   ")
        #expect(r8 == 0)
    }

    @Test func movingAProductChangesOnlyItsGroup() {
        var (portfolio, a, b) = portfolio()
        let r1 = portfolio.move(a, toGroup: "Internal")
        #expect(r1)
        let r2 = portfolio.move(a, toGroup: "Internal")
        #expect(!r2)
        let r3 = portfolio.move(UUID(), toGroup: "Internal")
        #expect(!r3)
        #expect(portfolio.product(id: b)?.group == "Internal")
        #expect(portfolio.groups == ["Internal"])
    }

    @Test func renamingAProductKeepsItsCLIName() {
        var (portfolio, a, _) = portfolio()
        let r4 = portfolio.rename(a, to: "Alpha Mobile")
        #expect(r4)
        #expect(portfolio.product(id: a)?.name == "Alpha Mobile")
        #expect(portfolio.product(id: a)?.slug == "alpha")
        #expect(portfolio.product(id: a)?.monogram == Monogram.make("Alpha Mobile"))
        let r5 = portfolio.rename(a, to: "")
        #expect(!r5)
    }
}

@Suite struct EditorTargetTests {
    @Test func vsCodeFamilyEditorsUseTheirCLIAndAWorkspaceFile() throws {
        let root = try makeTempDir("editor")
        defer { removeTemp(root) }
        let app = root.appending(path: "Cursor.app")
        let cli = app.appending(path: "Contents/Resources/app/bin/cursor")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("#!/bin/sh\n", to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let project = root.appending(path: "proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var target = EditorTarget.resolve(folder: project.path, bundleID: "com.todesktop.230313mzl4w4u92", appURL: app)
        #expect(target.path == project.path)
        #expect(target.cli?.path == cli.path)
        try write("{}", to: project.appending(path: "proj.code-workspace"))
        target = EditorTarget.resolve(folder: project.path, bundleID: "com.todesktop.230313mzl4w4u92", appURL: app)
        #expect(target.path.hasSuffix("proj.code-workspace"))
        // Two workspaces: the folder, since there is no telling which one is meant.
        try write("{}", to: project.appending(path: "other.code-workspace"))
        #expect(EditorTarget.resolve(folder: project.path, bundleID: "com.microsoft.VSCode", appURL: nil).path == project.path)
    }

    @Test func xcodeOpensTheProjectOrThePackage() throws {
        let root = try makeTempDir("xcode")
        defer { removeTemp(root) }
        try write("// swift-tools-version: 6.0", to: root.appending(path: "Package.swift"))
        #expect(EditorTarget.resolve(folder: root.path, bundleID: "com.apple.dt.Xcode", appURL: nil).path.hasSuffix("Package.swift"))
        try FileManager.default.createDirectory(at: root.appending(path: "App.xcodeproj"), withIntermediateDirectories: true)
        let target = EditorTarget.resolve(folder: root.path, bundleID: "com.apple.dt.Xcode", appURL: nil)
        #expect(target.path.hasSuffix("App.xcodeproj"))
        #expect(target.cli == nil)
    }
}

@Suite struct PlayTests {
    func project(_ files: [String: String]) throws -> URL {
        let root = try makeTempDir("play")
        for (name, text) in files {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(text, to: url)
        }
        return root
    }

    @Test func devServerAddressesComeFromFlagsThenFrameworkDefaults() throws {
        let vite = try project(["package.json": #"{"scripts":{"dev":"vite"},"devDependencies":{"vite":"5"}}"#])
        let next = try project(["package.json": #"{"scripts":{"dev":"next dev -p 4000"},"dependencies":{"next":"15"}}"#])
        let config = try project(["package.json": #"{"scripts":{"dev":"vite"}}"#, "vite.config.ts": "export default { server: { port: 5200 } }"])
        let bare = try project(["package.json": #"{"scripts":{"dev":"node server.js"}}"#])
        defer { [vite, next, config, bare].forEach(removeTemp) }
        #expect(DevServer.guessURL(folder: vite.path, command: ["npm", "run", "dev"]) == "http://localhost:5173")
        #expect(DevServer.guessURL(folder: next.path, command: ["npm", "run", "dev"]) == "http://localhost:4000")
        #expect(DevServer.guessURL(folder: config.path, command: ["npm", "run", "dev"]) == "http://localhost:5200")
        #expect(DevServer.guessURL(folder: bare.path, command: ["npm", "run", "dev"]) == nil)
        #expect(DevServer.port(in: "PORT=8081 node x") == 8081)
        #expect(DevServer.port(in: "serve --port=9000") == 9000)
    }

    @Test func localSitesAreReadAndMatchAPluginInside() {
        let json = #"""
        {"a":{"name":"shopsite","path":"~/Local Sites/shopsite","domain":"shopsite.local"},
         "b":{"name":"bad","path":"/x","domain":"evil.com/\"; rm"}}
        """#
        let sites = LocalSite.parse(Data(json.utf8), home: "/Users/me")
        #expect(sites.count == 1)
        #expect(sites[0].contains("/Users/me/Local Sites/shopsite/app/public/wp-content/plugins/x"))
        #expect(!sites[0].contains("/Users/me/Local Sites/shopsite-two/app"))
        #expect(sites[0].url(admin: true) == "http://shopsite.local/wp-admin/")
    }

    @Test func playPrefersTheSimulatorThenTheDevServerThenTheSite() throws {
        let root = try project(["package.json": #"{"scripts":{"dev":"vite"},"devDependencies":{"vite":"5"}}"#])
        defer { removeTemp(root) }
        var product = Product(name: "Shop")
        var checkout = LocalCheckout()
        checkout.path = root.path
        checkout.name = "shop"
        product.checkouts = [checkout]
        var dev = ActionRecipe(); dev.label = "Start Dev Server"; dev.setSteps([["npm", "run", "dev"]]); dev.checkoutID = checkout.id
        var tests = ActionRecipe(); tests.label = "Run Tests"; tests.setSteps([["npm", "test"]])
        var phone = ActionRecipe(); phone.label = "Build and Run on iPhone 17 Pro Simulator"; phone.setSteps([["npx", "cap", "run", "ios"]])
        product.recipes = [tests, dev, phone]
        let options = PlayPlanner.options(for: product, localSites: [])
        #expect(options.map(\.kind) == [.mobile, .web])
        #expect(options[0].title == "Run on iPhone 17 Pro Simulator")
        #expect(options[1].url == "http://localhost:5173")
        #expect(options[1].recipeID == dev.id)
        product.isDemo = true
        #expect(PlayPlanner.options(for: product, localSites: []).isEmpty)
        #expect(PlayPlanner.options(for: product, localSites: [], allowDemo: true).count == 2)
    }

    @Test func aWordPressPluginOpensItsLocalSiteAdmin() {
        var product = Product(name: "Plugin")
        var checkout = LocalCheckout()
        checkout.path = "/Users/me/Local Sites/shopsite/app/public/wp-content/plugins/plugin"
        product.checkouts = [checkout]
        let options = PlayPlanner.options(for: product, localSites: [LocalSite(name: "t", path: "/Users/me/Local Sites/shopsite", domain: "shopsite.local")])
        #expect(options.count == 1)
        #expect(options[0].kind == .site)
        #expect(options[0].url == "http://shopsite.local/wp-admin/")
        #expect(options[0].recipeID == nil && options[0].suggestion == nil)
    }

    @Test func desktopAppsGetAnUnapprovedLaunchSuggestion() throws {
        let swift = try project(["Package.swift": "let p = Package(targets: [.executableTarget(name: \"App\")])"])
        let mac = try project(["Package.swift": "executableTarget", "build.sh": "if [[ $1 == --open ]]; then open; fi"])
        let tauri = try project(["package.json": #"{"devDependencies":{"@tauri-apps/cli":"2"}}"#])
        let web = try project(["package.json": #"{"scripts":{"dev":"vite"}}"#])
        defer { [swift, mac, tauri, web].forEach(removeTemp) }
        func labels(_ url: URL) -> [[String]] {
            var checkout = LocalCheckout(); checkout.path = url.path
            return DesktopProject.recipes(for: checkout, environmentID: nil).map(\.steps).flatMap { $0 }
        }
        #expect(labels(swift) == [["swift", "run"]])
        #expect(labels(mac) == [["zsh", "./build.sh", "--open"]])
        #expect(labels(tauri) == [["npx", "tauri", "dev"]])
        #expect(labels(web).isEmpty)
        var checkout = LocalCheckout(); checkout.path = swift.path
        let recipe = try #require(DesktopProject.recipes(for: checkout, environmentID: nil).first)
        #expect(!recipe.isApproved && recipe.isSuggested)
        var product = Product(name: "Mac")
        product.checkouts = [checkout]
        let options = PlayPlanner.options(for: product, localSites: [])
        #expect(options.first?.kind == .desktop)
        #expect(options.first?.suggestion?.label == "Run App")
    }

    @Test func onlyLocalAddressesCountAsDevelopmentURLs() {
        #expect(PlayPlanner.localURL("http://localhost:3000") != nil)
        #expect(PlayPlanner.localURL("http://shop.test/") != nil)
        #expect(PlayPlanner.localURL("https://shop.example.com") == nil)
        #expect(PlayPlanner.localURL("file:///etc/passwd") == nil)
    }
}
