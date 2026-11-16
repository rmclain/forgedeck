import Foundation
import Testing
@testable import ForgeDeckKit

/// A fake Local site layout and a plugin checkout, in temporary folders.
struct WordPressWorld {
    let root: URL
    let site: WordPressSite
    let checkout: LocalCheckout

    init(pluginFolder: String = "acme-forms", version: String = "2.1.0") throws {
        root = try makeTempDir("wp world")
        let public_ = root.appending(path: "Local Sites/it's a site/app/public")
        for folder in ["wp-content/plugins/akismet", "wp-content/themes/twentyfive", "wp-includes", "wp-admin"] {
            try FileManager.default.createDirectory(at: public_.appending(path: folder), withIntermediateDirectories: true)
        }
        try write("<?php define('DB_PASSWORD', 'wp-config-secret-marker');", to: public_.appending(path: "wp-config.php"))
        site = WordPressSite(name: "it's a site", root: public_.path)
        let source = root.appending(path: "Projects/\(pluginFolder)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try write("<?php\n/**\n * Plugin Name: Acme Forms\n * Version: \(version)\n */\n", to: source.appending(path: "\(pluginFolder).php"))
        var checkout = LocalCheckout()
        checkout.name = pluginFolder
        checkout.path = source.path
        self.checkout = checkout
    }

    func link(name: String? = nil, subpath: String = "") -> InstallLink {
        var link = InstallLink()
        link.checkoutID = checkout.id
        link.destinationFolder = site.pluginsFolder
        link.linkName = name ?? (checkout.path as NSString).lastPathComponent
        link.sourceSubpath = subpath
        link.kind = .wordpressPlugin
        link.siteName = site.name
        return link
    }

    func cleanUp() { removeTemp(root) }
}

@Suite struct InstallLinkTests {
    @Test func localSitesAreFoundWithoutReadingWpConfig() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        let sites = InstallLinks.findWordPressSites(roots: [world.root.appending(path: "Local Sites").path])
        #expect(sites.map(\.name) == ["it's a site"])
        #expect(sites.first?.root == world.site.root)
        #expect(InstallLinks.findWordPressSites(roots: [world.root.appending(path: "nowhere").path]).isEmpty)
        #expect(ProjectDiscovery.isSecretBearing("wp-config.php"))
    }

    @Test func pluginAndThemeHeadersAreRead() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        #expect(InstallLinks.package(at: world.checkout.path) == WordPressPackage(kind: .wordpressPlugin, name: "Acme Forms", version: "2.1.0"))
        let theme = world.root.appending(path: "theme")
        try FileManager.default.createDirectory(at: theme, withIntermediateDirectories: true)
        try write("/*\nTheme Name: Acme Theme\nVersion: 1.4\n*/", to: theme.appending(path: "style.css"))
        #expect(InstallLinks.package(at: theme.path)?.kind == .wordpressTheme)
        #expect(InstallLinks.package(at: world.site.root) == nil)
    }

    @Test func createLinksAndTheSiteSeesTheCheckout() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        let link = world.link()
        #expect(InstallLinks.state(of: link, checkout: world.checkout) == .notLinked)
        try InstallLinks.create(link, checkout: world.checkout)
        #expect(InstallLinks.state(of: link, checkout: world.checkout) == .linked)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.linkPath)
        #expect(target.hasPrefix("/"))
        // Through the link, the site reads the checkout's files.
        #expect(FileManager.default.fileExists(atPath: (link.linkPath as NSString).appendingPathComponent("acme-forms.php")))
        // Creating again changes nothing.
        try InstallLinks.create(link, checkout: world.checkout)
        #expect(InstallLinks.state(of: link, checkout: world.checkout) == .linked)
    }

    @Test func aCopyInTheWayIsNeverOverwritten() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        let link = world.link()
        try FileManager.default.createDirectory(atPath: link.linkPath, withIntermediateDirectories: true)
        try write("<?php\n/* Plugin Name: Acme Forms\n Version: 1.9.0 */", to: URL(fileURLWithPath: link.linkPath).appending(path: "acme-forms.php"))
        #expect(InstallLinks.state(of: link, checkout: world.checkout) == .blockedByCopy(version: "1.9.0"))
        #expect(throws: InstallLinkError.occupied(link.linkPath)) { try InstallLinks.create(link, checkout: world.checkout) }
        #expect(throws: InstallLinkError.notOurLink(link.linkPath)) { try InstallLinks.remove(link, checkout: world.checkout) }
        #expect(FileManager.default.fileExists(atPath: (link.linkPath as NSString).appendingPathComponent("acme-forms.php")))
    }

    @Test func moveAsideKeepsTheCopyOutsideThePluginsFolder() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        let link = world.link()
        try FileManager.default.createDirectory(atPath: link.linkPath, withIntermediateDirectories: true)
        try write("old copy", to: URL(fileURLWithPath: link.linkPath).appending(path: "marker.txt"))
        let backupFolder = InstallLinks.backupFolder(for: link.destinationFolder)
        #expect(backupFolder == world.site.backupFolder)
        let backup = try InstallLinks.moveAsideAndLink(link, checkout: world.checkout, backupFolder: backupFolder)
        #expect(InstallLinks.state(of: link, checkout: world.checkout) == .linked)
        #expect(try String(contentsOfFile: (backup as NSString).appendingPathComponent("marker.txt"), encoding: .utf8) == "old copy")
        #expect(!backup.contains("/wp-content/plugins/"))
        #expect(throws: InstallLinkError.notACopy) { try InstallLinks.moveAsideAndLink(link, checkout: world.checkout, backupFolder: backupFolder) }
    }

    @Test func removeTouchesOnlyOurOwnLink() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        let link = world.link()
        try InstallLinks.create(link, checkout: world.checkout)
        try InstallLinks.remove(link, checkout: world.checkout)
        #expect(InstallLinks.state(of: link, checkout: world.checkout) == .notLinked)
        // The checkout is untouched.
        #expect(FileManager.default.fileExists(atPath: (world.checkout.path as NSString).appendingPathComponent("acme-forms.php")))
        // A link someone else made to another folder is not ours to remove.
        let other = world.root.appending(path: "Projects/other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.linkPath, withDestinationPath: other.path)
        #expect(InstallLinks.state(of: link, checkout: world.checkout) == .pointsElsewhere(target: other.path))
        #expect(throws: InstallLinkError.notOurLink(link.linkPath)) { try InstallLinks.remove(link, checkout: world.checkout) }
        #expect(FileManager.default.fileExists(atPath: other.path))
        // Removing a link that is not there is fine.
        try FileManager.default.removeItem(atPath: link.linkPath)
        try InstallLinks.remove(link, checkout: world.checkout)
    }

    @Test func brokenAndMissingStatesAreReported() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        let link = world.link()
        try FileManager.default.createSymbolicLink(atPath: link.linkPath, withDestinationPath: "/nonexistent/forgedeck/plugin")
        #expect(InstallLinks.state(of: link, checkout: world.checkout) == .broken(target: "/nonexistent/forgedeck/plugin"))
        var missingSite = link
        missingSite.destinationFolder = world.root.appending(path: "gone").path
        #expect(InstallLinks.state(of: missingSite, checkout: world.checkout) == .destinationMissing)
        #expect(InstallLinks.state(of: world.link(subpath: "build"), checkout: world.checkout) == .sourceMissing)
    }

    @Test func aBuildSubfolderCanBeLinked() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        let build = URL(fileURLWithPath: world.checkout.path).appending(path: "build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let link = world.link(name: "acme-forms", subpath: "build")
        try InstallLinks.create(link, checkout: world.checkout)
        #expect(InstallLinks.state(of: link, checkout: world.checkout) == .linked)
        #expect(InstallLinks.standardized(try FileManager.default.destinationOfSymbolicLink(atPath: link.linkPath)) == InstallLinks.standardized(build.path))
    }

    @Test func namesThatEscapeTheFolderAreRefused() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        for bad in ["", "..", "../wp-admin", "a/b", "-rf", "x;y"] {
            #expect(!InstallLinks.isValidName(bad), "\(bad)")
            #expect(throws: InstallLinkError.invalidName) { try InstallLinks.create(world.link(name: bad), checkout: world.checkout) }
        }
        #expect(InstallLinks.isValidName("acme-forms"))
        #expect(InstallLinks.isValidName("Acme Forms 2"))
    }

    @Test func suggestionsPutSitesWithAnOldCopyFirstAndAdoptHandMadeLinks() throws {
        let world = try WordPressWorld()
        defer { world.cleanUp() }
        let second = world.root.appending(path: "Local Sites/another/app/public")
        for folder in ["wp-content/plugins", "wp-content/themes", "wp-includes"] {
            try FileManager.default.createDirectory(at: second.appending(path: folder), withIntermediateDirectories: true)
        }
        let copy = second.appending(path: "wp-content/plugins/acme-forms")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try write("<?php /* Plugin Name: Acme Forms\n Version: 1.0.0 */", to: copy.appending(path: "acme-forms.php"))
        let sites = InstallLinks.findWordPressSites(roots: [world.root.appending(path: "Local Sites").path])
        let suggestions = InstallLinks.suggestions(for: world.checkout, existing: [], sites: sites)
        #expect(suggestions.map(\.site.name) == ["another", "it's a site"])
        #expect(suggestions.first?.hasCopy == true)
        #expect(suggestions.first?.copyVersion == "1.0.0")

        try FileManager.default.createSymbolicLink(atPath: (world.site.pluginsFolder as NSString).appendingPathComponent("acme-forms"), withDestinationPath: world.checkout.path)
        let adopted = InstallLinks.existingLinks(into: world.checkout, sites: sites)
        #expect(adopted.count == 1)
        #expect(adopted.first?.siteName == "it's a site")
        #expect(InstallLinks.state(of: adopted[0], checkout: world.checkout) == .linked)
        #expect(InstallLinks.suggestions(for: world.checkout, existing: adopted, sites: sites).map(\.site.name) == ["another"])
    }

    @Test func migrationAddsInstallLinksAndRepairDropsOrphans() throws {
        let v3 = #"{"schemaVersion":3,"products":[{"id":"6E6B4B9C-1D2B-4D59-9A2E-1C1F8E4A1B01","slug":"a","name":"A","tagline":"","notes":"","group":"G","tags":[],"stack":[],"links":[],"isFavorite":false,"lifecycle":"active","hue":1,"monogram":"A","createdAt":"2026-11-01T00:00:00Z","isDemo":false,"components":[],"repositories":[],"checkouts":[],"environments":[],"recipes":[],"profiles":[],"contextLinks":[]}],"organizations":[],"connections":[],"variables":[],"settings":{}}"#
        let migrated = try JSONSerialization.jsonObject(with: PortfolioMigrator.migrate(Data(v3.utf8))) as! [String: Any]
        #expect(migrated["schemaVersion"] as? Int == 4)
        #expect(((migrated["products"] as! [[String: Any]])[0]["installLinks"] as? [Any])?.isEmpty == true)
        var portfolio = Portfolio()
        var product = Product(name: "A")
        var orphan = InstallLink()
        orphan.checkoutID = UUID()
        orphan.linkName = "x"
        product.installLinks = [orphan]
        portfolio.products = [product]
        #expect(!IntegrityChecker.problems(in: portfolio).isEmpty)
        #expect(IntegrityChecker.repair(portfolio).products[0].installLinks.isEmpty)
    }
}
