import Foundation

// MARK: Editor targets

/// What an editor opens for a checkout, and how.
public struct EditorTarget: Sendable, Equatable {
    /// The file or folder handed to the editor: a workspace file when the project has one, else the folder.
    public var path: String
    /// The editor's own command line tool inside its app bundle. It opens the folder in its own window,
    /// or brings forward the window that already has it, instead of adding it to the last window.
    public var cli: URL?

    /// Command line tools that VS Code-family editors ship inside the app bundle.
    static let bundledCLIs: [String: String] = [
        "com.microsoft.VSCode": "Contents/Resources/app/bin/code",
        "com.microsoft.VSCodeInsiders": "Contents/Resources/app/bin/code-insiders",
        "com.todesktop.230313mzl4w4u92": "Contents/Resources/app/bin/cursor",
        "com.exafunction.windsurf": "Contents/Resources/app/bin/windsurf",
        "com.vscodium": "Contents/Resources/app/bin/codium",
        "dev.zed.Zed": "Contents/MacOS/cli",
    ]

    public static func resolve(folder: String, bundleID: String, appURL: URL?) -> EditorTarget {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        func join(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }
        var path = folder
        if bundleID == "com.apple.dt.Xcode" {
            // Xcode opens a workspace, a project, or a package. A plain folder opens as loose files.
            if let project = MobileRecipes.inspect(folder)?.xcodeProject { path = join(project) }
            else if entries.contains("Package.swift") { path = join("Package.swift") }
        } else if bundledCLIs[bundleID] != nil {
            // One workspace file at the top means the project is meant to be opened through it.
            let workspaces = entries.filter { $0.hasSuffix(".code-workspace") }
            if workspaces.count == 1 { path = join(workspaces[0]) }
        }
        var cli: URL?
        if let appURL, let relative = bundledCLIs[bundleID] {
            let candidate = appURL.appending(path: relative)
            if fm.isExecutableFile(atPath: candidate.path) { cli = candidate }
        }
        return EditorTarget(path: path, cli: cli)
    }
}

// MARK: Groups

extension Portfolio {
    /// Renames a sidebar group. Renaming onto an existing group merges the two. Returns how many products moved.
    @discardableResult
    public mutating func renameGroup(_ old: String, to new: String) -> Int {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return 0 }
        var moved = 0
        for index in products.indices where products[index].group == old {
            products[index].group = name
            moved += 1
        }
        return moved
    }

    /// Moves a product to a group, new or existing. Returns false when nothing changed.
    @discardableResult
    public mutating func move(_ productID: UUID, toGroup group: String) -> Bool {
        let name = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = products.firstIndex(where: { $0.id == productID }), products[index].group != name else { return false }
        products[index].group = name
        return true
    }

    /// Changes the name shown everywhere. The CLI name (slug) stays, so scripts keep working.
    @discardableResult
    public mutating func rename(_ productID: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = products.firstIndex(where: { $0.id == productID }), products[index].name != trimmed else { return false }
        products[index].name = trimmed
        products[index].monogram = Monogram.make(trimmed)
        return true
    }
}

// MARK: Play

/// One way to launch what a product builds: a mobile app, a desktop app, a web app, or a site.
public struct PlayOption: Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, Comparable {
        case mobile, desktop, web, site
        public var title: String {
            switch self {
            case .mobile: "Mobile app"
            case .desktop: "Desktop app"
            case .web: "Web app"
            case .site: "Site"
            }
        }
        var rank: Int { switch self { case .mobile: 0; case .desktop: 1; case .web: 2; case .site: 3 } }
        public static func < (a: Kind, b: Kind) -> Bool { a.rank < b.rank }
    }

    public var id: String { recipeID?.uuidString ?? suggestion?.label ?? url ?? title }
    public var kind: Kind
    public var title: String
    /// An existing recipe to run. It runs only once approved.
    public var recipeID: UUID?
    /// A recipe Play would add, unapproved, when chosen.
    public var suggestion: ActionRecipe?
    /// A page to open: right away when there is nothing to run, or once the dev server answers.
    public var url: String?
    /// Set up on purpose (run setup), so it comes before anything detected.
    public var isSetUp = false
}

public enum PlayPlanner {
    /// Every launch option for a product, best first. The first one is what the Play button does.
    /// `allowDemo` lists them for a demo product too, so its page can show a disabled Play button.
    public static func options(for product: Product, localSites: [LocalSite] = LocalSite.load(), allowDemo: Bool = false) -> [PlayOption] {
        guard !product.isDemo || allowDemo, !product.isArchived else { return [] }
        var out: [PlayOption] = []
        let developmentURL = product.environment(tier: .development)?.domains.lazy.compactMap { localURL($0.contains("://") ? $0 : "http://" + $0) }.first
        for recipe in product.recipes where recipe.executor == .local || (recipe.executor == .openURL && recipe.play != nil) {
            let label = recipe.label
            if let kind = recipe.play {
                // A command run setup saved: it says what it launches and which page to open.
                out.append(PlayOption(kind: kind, title: label, recipeID: recipe.id,
                                      url: recipe.executor == .openURL ? nil : recipe.url.flatMap(localURL), isSetUp: true))
                continue
            }
            let checkout = product.checkout(id: recipe.checkoutID) ?? product.primaryCheckout
            if label.hasPrefix("Build and Run on") {
                out.append(PlayOption(kind: .mobile, title: label.replacingOccurrences(of: "Build and Run on", with: "Run on"), recipeID: recipe.id))
            } else if label.hasPrefix("Run Desktop App") || label.hasPrefix("Build and Open App") || label.hasPrefix("Run App") {
                out.append(PlayOption(kind: .desktop, title: label, recipeID: recipe.id))
            } else if label.hasPrefix("Start Dev Server") {
                let isDesktop = checkout.map { DesktopProject.inspect($0.path)?.isElectron == true } ?? false
                let url = developmentURL ?? checkout.flatMap { DevServer.guessURL(folder: $0.path, command: recipe.steps.last ?? []) }
                out.append(PlayOption(kind: isDesktop ? .desktop : .web, title: isDesktop ? "Run Desktop App" + suffix(label) : "Start and Open" + suffix(label),
                                      recipeID: recipe.id, url: isDesktop ? nil : url))
            }
        }
        // Launch recipes the detector would suggest today but the product does not have yet.
        for checkout in product.checkouts {
            for recipe in DesktopProject.recipes(for: checkout, environmentID: product.environment(tier: .development)?.id, suffix: product.checkouts.count > 1 ? " · \(checkout.name)" : "")
            where !product.recipes.contains(where: { $0.label == recipe.label && $0.checkoutID == checkout.id }) {
                out.append(PlayOption(kind: .desktop, title: recipe.label, suggestion: recipe))
            }
        }
        // A WordPress plugin or theme inside a Local site: open that site's admin.
        for checkout in product.checkouts {
            if let site = localSites.first(where: { $0.contains(checkout.path) }) {
                let isPlugin = checkout.path.contains("/wp-content/")
                out.append(PlayOption(kind: .site, title: "Open \(site.domain)\(isPlugin ? " Admin" : "")", url: site.url(admin: isPlugin)))
            }
        }
        if !out.contains(where: { $0.kind == .site }), let developmentURL, !out.contains(where: { $0.url == developmentURL }) {
            out.append(PlayOption(kind: .site, title: "Open Local Site", url: developmentURL))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.enumerated()
            .sorted {
                if $0.element.isSetUp != $1.element.isSetUp { return $0.element.isSetUp }
                // What run setup saved keeps the order it was proposed in.
                if $0.element.isSetUp || $0.element.kind == $1.element.kind { return $0.offset < $1.offset }
                return $0.element.kind < $1.element.kind
            }
            .map(\.element)
    }

    private static func suffix(_ label: String) -> String {
        label.range(of: " · ").map { String(label[$0.lowerBound...]) } ?? ""
    }

    /// Only loopback and .local/.test hosts: Play opens what runs on this Mac.
    static func localURL(_ text: String) -> String? {
        guard let url = URL(string: text), let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".test") || host.hasSuffix(".localhost")
        return local ? text : nil
    }
}

// MARK: Dev servers

public enum DevServer {
    /// The address a dev server listens on, from the script's flags or the framework's default.
    public static func guessURL(folder: String, command: [String]) -> String? {
        let fm = FileManager.default
        func read(_ name: String) -> String? {
            fm.contents(atPath: (folder as NSString).appendingPathComponent(name)).flatMap { String(data: $0, encoding: .utf8) }
        }
        var script = command.joined(separator: " ")
        var dependencies = ""
        if let data = read("package.json")?.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // `npm run dev` -> the text of the dev script.
            if let scripts = json["scripts"] as? [String: Any], let index = command.firstIndex(of: "run"), index + 1 < command.count,
               let body = scripts[command[index + 1]] as? String { script = body }
            for key in ["dependencies", "devDependencies"] {
                if let found = json[key] as? [String: Any] { dependencies += " " + found.keys.joined(separator: " ") }
            }
        }
        if let port = port(in: script) { return "http://localhost:\(port)" }
        let words = Set(dependencies.split(separator: " ").map(String.init))
        let configs = ["vite.config.ts", "vite.config.js", "vite.config.mjs"].compactMap(read).joined(separator: "\n")
        if !configs.isEmpty, let port = configPort(configs) { return "http://localhost:\(port)" }
        if script.contains("artisan serve") { return "http://localhost:8000" }
        if script.contains("manage.py runserver") || script.contains("uvicorn") { return "http://localhost:8000" }
        if words.contains("next") || script.contains("next dev") { return "http://localhost:3000" }
        if words.contains("astro") { return "http://localhost:4321" }
        if words.contains("@sveltejs/kit") || words.contains("vite") || script.contains("vite") { return "http://localhost:5173" }
        if words.contains("@angular/core") { return "http://localhost:4200" }
        if words.contains("react-scripts") || words.contains("express") || words.contains("nuxt") { return "http://localhost:3000" }
        if script.contains("flask") { return "http://localhost:5000" }
        return nil
    }

    /// `--port 8080`, `--port=8080`, `-p 8080`, or `PORT=8080`.
    static func port(in script: String) -> Int? {
        let patterns = [#"--port[= ](\d{2,5})"#, #"(?:^|\s)-p\s+(\d{2,5})"#, #"PORT=(\d{2,5})"#]
        for pattern in patterns {
            if let match = script.range(of: pattern, options: .regularExpression) {
                let digits = script[match].filter(\.isNumber)
                if let value = Int(digits), (1...65535).contains(value) { return value }
            }
        }
        return nil
    }

    static func configPort(_ text: String) -> Int? {
        guard let match = text.range(of: #"port\s*:\s*(\d{2,5})"#, options: .regularExpression) else { return nil }
        return Int(text[match].filter(\.isNumber))
    }
}

// MARK: Desktop apps

public enum DesktopProject {
    public struct Project: Sendable, Equatable {
        public var isElectron = false
        public var isTauri = false
        public var scripts: Set<String> = []
        /// A Swift package with an executable target.
        public var isSwiftExecutable = false
        /// A build script that takes --open, like the one in Mac app templates.
        public var hasBuildOpen = false
    }

    public static func inspect(_ path: String) -> Project? {
        let fm = FileManager.default
        func read(_ name: String) -> String? {
            fm.contents(atPath: (path as NSString).appendingPathComponent(name)).flatMap { String(data: $0, encoding: .utf8) }
        }
        var project = Project()
        if let data = read("package.json")?.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var names = Set<String>()
            for key in ["dependencies", "devDependencies"] { names.formUnion(((json[key] as? [String: Any]) ?? [:]).keys) }
            project.isElectron = names.contains("electron")
            project.isTauri = names.contains("@tauri-apps/cli") || fm.fileExists(atPath: (path as NSString).appendingPathComponent("src-tauri"))
            project.scripts = Set(((json["scripts"] as? [String: Any]) ?? [:]).keys)
        }
        if let manifest = read("Package.swift") { project.isSwiftExecutable = manifest.contains("executableTarget") }
        if let build = read("build.sh") { project.hasBuildOpen = build.contains("--open") }
        let any = project.isElectron || project.isTauri || project.isSwiftExecutable || project.hasBuildOpen
        return any ? project : nil
    }

    /// Unapproved launch recipes for desktop apps. Electron apps usually start through their dev script.
    public static func recipes(for checkout: LocalCheckout, environmentID: UUID?, suffix: String = "") -> [ActionRecipe] {
        guard let project = inspect(checkout.path) else { return [] }
        func recipe(_ label: String, _ steps: [[String]]) -> ActionRecipe {
            var recipe = ActionRecipe()
            recipe.label = label + suffix
            recipe.setSteps(steps)
            recipe.checkoutID = checkout.id
            recipe.environmentID = environmentID
            recipe.safety = .localWrite
            recipe.isSuggested = true
            recipe.opensInTerminal = true
            return recipe
        }
        if project.hasBuildOpen { return [recipe("Build and Open App", [["zsh", "./build.sh", "--open"]])] }
        if project.isTauri { return [recipe("Run Desktop App", [["npx", "tauri", "dev"]])] }
        if project.isSwiftExecutable { return [recipe("Run App", [["swift", "run"]])] }
        if project.isElectron, project.scripts.contains("start"), !project.scripts.contains("dev") {
            return [recipe("Run Desktop App", [["npm", "run", "start"]])]
        }
        return []
    }
}

// MARK: Local (WordPress) sites

/// A site made with Local by WP Engine, read from its sites.json. Read only.
public struct LocalSite: Sendable, Equatable {
    public var name: String
    public var path: String
    public var domain: String

    public init(name: String, path: String, domain: String) {
        self.name = name
        self.path = path
        self.domain = domain
    }

    public func contains(_ folder: String) -> Bool {
        let base = path.hasSuffix("/") ? path : path + "/"
        return folder.hasPrefix(base)
    }

    public func url(admin: Bool) -> String { "http://\(domain)/" + (admin ? "wp-admin/" : "") }

    public static var defaultFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support/Local/sites.json")
    }

    public static func parse(_ data: Data, home: String = NSHomeDirectory()) -> [LocalSite] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.values.compactMap { value -> LocalSite? in
            guard let site = value as? [String: Any], let path = site["path"] as? String, let domain = site["domain"] as? String,
                  !domain.isEmpty, domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
            let expanded = path.hasPrefix("~") ? home + path.dropFirst() : path
            return LocalSite(name: site["name"] as? String ?? domain, path: expanded, domain: domain)
        }
        .sorted { $0.path.count > $1.path.count }
    }

    public static func load(from file: URL = defaultFile) -> [LocalSite] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return parse(data)
    }
}
