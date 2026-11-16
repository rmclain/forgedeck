import Foundation

// Finds projects under a folder the user chose. Read-only.
// It never reads .env files, private keys, .npmrc, or anything else that holds secrets.

public struct DiscoveredProject: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isGitRepository: Bool
    public var isWorktree: Bool
    public var mainWorktreePath: String?
    public var remoteURL: String?
    public var repository: RepositoryURL?
    public var metadata: DetectedMetadata
    public var description: String?

    public init(path: String, name: String, isGitRepository: Bool, isWorktree: Bool, mainWorktreePath: String?, remoteURL: String?,
                repository: RepositoryURL?, metadata: DetectedMetadata, description: String?) {
        self.path = path
        self.name = name
        self.isGitRepository = isGitRepository
        self.isWorktree = isWorktree
        self.mainWorktreePath = mainWorktreePath
        self.remoteURL = remoteURL
        self.repository = repository
        self.metadata = metadata
        self.description = description
    }
}

public struct DiscoveryLimits: Sendable {
    public var maxDepth = 4
    public var maxDirectories = 20_000
    public var maxResults = 500
    public init() {}
}

public struct DiscoveryResult: Sendable {
    public var projects: [DiscoveredProject] = []
    public var directoriesVisited = 0
    public var hitLimit = false
    public var cancelled = false
}

public struct ProjectDiscovery: Sendable {
    /// Folders that are never entered: dependency trees, caches, build output.
    public static let skipped: Set<String> = [
        "node_modules", ".venv", "venv", "vendor", "Pods", ".build", "build", "dist", "DerivedData", ".next", ".nuxt",
        "target", ".cache", ".gradle", "__pycache__", ".tox", ".idea", ".terraform", "Library", ".Trash", ".npm", ".cargo",
        ".rustup", "bower_components", ".pnpm-store", "Carthage", ".swiftpm", "coverage", ".turbo", ".parcel-cache",
    ]

    /// Files discovery refuses to open, whatever asks for them.
    public static func isSecretBearing(_ filename: String) -> Bool {
        let name = filename.lowercased()
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return true }
        if [".npmrc", ".netrc", ".pypirc", "credentials", "credentials.json", "secrets.json", "secrets.yml", "secrets.yaml", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", ".htpasswd", "wp-config.php"].contains(name) { return true }
        return [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".mobileprovision"].contains { name.hasSuffix($0) }
    }

    public var limits: DiscoveryLimits

    public init(limits: DiscoveryLimits = DiscoveryLimits()) { self.limits = limits }

    /// Scans one root. A folder with project markers is a project and is not searched
    /// further, except for nested Git repositories one level down (monorepo members stay
    /// part of their parent).
    public func scan(root: URL) async -> DiscoveryResult {
        var result = DiscoveryResult()
        var visited = Set<String>()
        var queue: [(URL, Int)] = [(root.standardizedFileURL, 0)]
        let fm = FileManager.default

        while !queue.isEmpty {
            if Task.isCancelled { result.cancelled = true; break }
            let (directory, depth) = queue.removeFirst()
            // Resolving symlinks and remembering the real path stops loops.
            let real = directory.resolvingSymlinksInPath().path
            guard visited.insert(real).inserted else { continue }
            result.directoriesVisited += 1
            if result.directoriesVisited > limits.maxDirectories || result.projects.count >= limits.maxResults {
                result.hitLimit = true
                break
            }
            if let project = inspect(directory) {
                result.projects.append(project)
                if project.isGitRepository { continue }
            }
            guard depth < limits.maxDepth,
                  let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                             options: [.skipsPackageDescendants]) else { continue }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                guard !name.hasPrefix("."), !Self.skipped.contains(name) else { continue }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                queue.append((child, depth + 1))
            }
            await Task.yield()
        }
        result.projects.sort { $0.path < $1.path }
        return result
    }

    /// Reads one folder. Returns nil when it holds no project markers.
    public func inspect(_ directory: URL) -> DiscoveredProject? {
        let fm = FileManager.default
        let path = directory.path
        let gitPath = (path as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        let hasGit = fm.fileExists(atPath: gitPath, isDirectory: &isDir)
        var isWorktree = false
        var mainWorktree: String?
        var configPath: String?
        if hasGit {
            if isDir.boolValue {
                configPath = (gitPath as NSString).appendingPathComponent("config")
            } else if let pointer = try? String(contentsOfFile: gitPath, encoding: .utf8), pointer.hasPrefix("gitdir:") {
                // A linked worktree or a submodule: .git is a file pointing at the real git dir.
                let target = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                let gitDir = URL(fileURLWithPath: target, relativeTo: directory).standardizedFileURL
                if gitDir.path.contains("/worktrees/") {
                    isWorktree = true
                    let common = gitDir.deletingLastPathComponent().deletingLastPathComponent()
                    mainWorktree = common.lastPathComponent == ".git" ? common.deletingLastPathComponent().path : common.path
                    configPath = common.appending(path: "config").path
                } else {
                    configPath = gitDir.appending(path: "config").path
                }
            }
        }
        let metadata = Self.detectMetadata(in: directory)
        let hasMarkers = !metadata.stack.isEmpty || metadata.hasDockerfile || !metadata.composeServices.isEmpty
        guard hasGit || hasMarkers else { return nil }

        var remote: String?
        if let configPath, let config = try? String(contentsOfFile: configPath, encoding: .utf8) {
            remote = Self.originURL(inGitConfig: config)
        }
        // A token inside a remote URL (https://user:token@host/…) never leaves this function.
        let repository = remote.flatMap(RepositoryURL.parse)
        let safeRemote = remote.map { Redactor().redact($0) }
        return DiscoveredProject(path: path, name: directory.lastPathComponent, isGitRepository: hasGit, isWorktree: isWorktree,
                                 mainWorktreePath: mainWorktree, remoteURL: safeRemote, repository: repository,
                                 metadata: metadata, description: Self.readmeSummary(in: directory))
    }

    public static func originURL(inGitConfig config: String) -> String? {
        var section = ""
        var first: String?
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard section.hasPrefix("[remote "), line.hasPrefix("url") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let url = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if section.contains("\"origin\"") { return url }
            if first == nil { first = url }
        }
        return first
    }

    private static func read(_ name: String, in directory: URL, maxBytes: Int = 200_000) -> String? {
        guard !isSecretBearing(name) else { return nil }
        let url = directory.appending(path: name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func detectMetadata(in directory: URL) -> DetectedMetadata {
        var meta = DetectedMetadata()
        var stack: [String] = []
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: directory.appending(path: name).path) }

        if let text = read("package.json", in: directory),
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            var deps = Set<String>()
            for key in ["dependencies", "devDependencies"] {
                if let dict = json[key] as? [String: Any] { deps.formUnion(dict.keys) }
            }
            let known: [(String, String)] = [("next", "Next.js"), ("@remix-run/react", "Remix"), ("@sveltejs/kit", "SvelteKit"),
                                             ("astro", "Astro"), ("nuxt", "Nuxt"), ("react", "React"), ("vue", "Vue"),
                                             ("express", "Express"), ("fastify", "Fastify"), ("hono", "Hono"),
                                             ("prisma", "Prisma"), ("typescript", "TypeScript")]
            let found = known.filter { deps.contains($0.0) }.map(\.1)
            stack += found.isEmpty ? ["Node.js"] : Array(found.prefix(3))
            let manager = exists("pnpm-lock.yaml") ? "pnpm" : exists("yarn.lock") ? "yarn" : exists("bun.lockb") ? "bun" : "npm"
            if let scripts = json["scripts"] as? [String: Any] {
                if scripts["dev"] != nil { meta.startCommand = [manager, "run", "dev"] }
                else if scripts["start"] != nil { meta.startCommand = [manager, "run", "start"] }
                if scripts["test"] != nil { meta.testCommand = [manager, "test"] }
            }
            if deps.contains("next") || deps.contains("@remix-run/react") { meta.devURL = "http://localhost:3000" }
            else if deps.contains("vite") || deps.contains("@sveltejs/kit") { meta.devURL = "http://localhost:5173" }
            else if deps.contains("astro") { meta.devURL = "http://localhost:4321" }
            meta.suggestedKind = deps.contains("express") || deps.contains("fastify") || deps.contains("hono") ? .backend : .frontend
        }
        if let text = read("composer.json", in: directory) {
            stack.append(text.contains("laravel/framework") ? "Laravel" : "PHP")
            meta.testCommand = meta.testCommand.isEmpty ? ["composer", "test"] : meta.testCommand
            if meta.suggestedKind == .other { meta.suggestedKind = .backend }
        }
        if let text = read("pyproject.toml", in: directory) ?? read("requirements.txt", in: directory) {
            let lower = text.lowercased()
            stack.append(lower.contains("fastapi") ? "FastAPI" : lower.contains("django") ? "Django" : lower.contains("flask") ? "Flask" : "Python")
            if lower.contains("fastapi") { meta.devURL = meta.devURL ?? "http://localhost:8000" }
            if lower.contains("pytest"), meta.testCommand.isEmpty { meta.testCommand = ["python3", "-m", "pytest"] }
            if meta.suggestedKind == .other { meta.suggestedKind = .backend }
        }
        if exists("Cargo.toml") { stack.append("Rust"); if meta.testCommand.isEmpty { meta.testCommand = ["cargo", "test"] } }
        if exists("go.mod") { stack.append("Go"); if meta.testCommand.isEmpty { meta.testCommand = ["go", "test", "./..."] } }
        if exists("Gemfile") { stack.append("Ruby") }
        if exists("Package.swift") {
            stack.append("Swift")
            if meta.testCommand.isEmpty { meta.testCommand = ["swift", "test"] }
        }
        if let entries = try? fm.contentsOfDirectory(atPath: directory.path) {
            if entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
                if !stack.contains("Swift") { stack.append("Swift") }
                stack.append("Xcode")
                meta.suggestedKind = .mobile
            }
            // A WordPress plugin: a top-level PHP file with a "Plugin Name:" header.
            for entry in entries where entry.hasSuffix(".php") && meta.wordpressPluginName == nil {
                if let head = read(entry, in: directory, maxBytes: 8_192),
                   let line = head.split(separator: "\n").first(where: { $0.range(of: "Plugin Name:", options: .caseInsensitive) != nil }),
                   let colon = line.firstIndex(of: ":") {
                    meta.wordpressPluginName = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    stack.append("WordPress")
                    if !stack.contains("PHP") { stack.append("PHP") }
                    meta.suggestedKind = .plugin
                }
            }
            if entries.contains("wp-content") || entries.contains("wp-includes") {
                if !stack.contains("WordPress") { stack.append("WordPress") }
                meta.suggestedKind = .site
            }
        }
        if exists("Dockerfile") { meta.hasDockerfile = true; stack.append("Docker") }
        for name in ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"] {
            if let text = read(name, in: directory) {
                meta.composeServices = composeServices(in: text)
                if !stack.contains("Docker") { stack.append("Docker") }
                break
            }
        }
        var seen = Set<String>()
        meta.stack = stack.filter { seen.insert($0).inserted }
        return meta
    }

    /// Service names from a Compose file: the keys one level under `services:`.
    public static func composeServices(in yaml: String) -> [String] {
        var services: [String] = []
        var inServices = false
        var indent: Int?
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let leading = line.prefix { $0 == " " }.count
            if leading == 0 {
                inServices = trimmed.hasPrefix("services:")
                indent = nil
                continue
            }
            guard inServices else { continue }
            if indent == nil { indent = leading }
            if leading == indent, trimmed.hasSuffix(":"), !trimmed.hasPrefix("-") {
                services.append(String(trimmed.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
        }
        return services
    }

    static func readmeSummary(in directory: URL) -> String? {
        for name in ["README.md", "README", "readme.md", "README.txt"] {
            guard let text = read(name, in: directory, maxBytes: 4_096) else { continue }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("<") || line.hasPrefix("[") || line.hasPrefix("=") || line.hasPrefix("-") { continue }
                return String(line.prefix(140))
            }
        }
        return nil
    }
}

// MARK: Import planning

/// What an import would do, for the review sheet. Nothing is saved until the user approves.
public struct ImportProposal: Sendable, Identifiable, Hashable {
    public enum Action: Sendable, Hashable {
        case createProduct
        /// The repository or the folder already belongs to this product.
        case addCheckout(productID: UUID)
        /// This exact folder is already registered: only its metadata is refreshed.
        case refresh(productID: UUID, checkoutID: UUID)
    }

    public var id: String { project.path }
    public var project: DiscoveredProject
    public var action: Action
    public var isSelected = true

    public init(project: DiscoveredProject, action: Action, isSelected: Bool = true) {
        self.project = project
        self.action = action
        self.isSelected = isSelected
    }
}

public enum ImportPlanner {
    /// Proposes what to do with each discovered project. Running it twice proposes
    /// `.refresh` the second time, so a re-scan never duplicates a product.
    public static func plan(_ projects: [DiscoveredProject], portfolio: Portfolio) -> [ImportProposal] {
        // Linked worktrees follow their main checkout into the same product.
        var plannedByRepo: [String: Int] = [:]
        var proposals: [ImportProposal] = []
        for project in projects {
            if let (product, checkout) = existing(path: project.path, in: portfolio) {
                proposals.append(ImportProposal(project: project, action: .refresh(productID: product.id, checkoutID: checkout.id)))
                continue
            }
            if let repo = project.repository,
               let product = portfolio.products.first(where: { $0.repositories.contains { same($0, repo) } }) {
                proposals.append(ImportProposal(project: project, action: .addCheckout(productID: product.id)))
                continue
            }
            if let main = project.mainWorktreePath, let (product, _) = existing(path: main, in: portfolio) {
                proposals.append(ImportProposal(project: project, action: .addCheckout(productID: product.id)))
                continue
            }
            if let repo = project.repository { plannedByRepo[repo.webURL, default: 0] += 1 }
            proposals.append(ImportProposal(project: project, action: .createProduct))
        }
        return proposals
    }

    static func existing(path: String, in portfolio: Portfolio) -> (Product, LocalCheckout)? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        for product in portfolio.products {
            if let checkout = product.checkouts.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == wanted }) {
                return (product, checkout)
            }
        }
        return nil
    }

    static func same(_ repo: Repository, _ url: RepositoryURL) -> Bool {
        repo.owner.lowercased() == url.owner.lowercased() && repo.name.lowercased() == url.name.lowercased()
    }

    /// Applies approved proposals. User-edited fields (name, tagline, tags, group, favorites) are never overwritten.
    @discardableResult
    public static func apply(_ proposals: [ImportProposal], to portfolio: inout Portfolio, group: String = "Products") -> [UUID] {
        var touched: [UUID] = []
        // Several checkouts of one repository in the same import become one product.
        var createdByRepo: [String: UUID] = [:]
        for proposal in proposals where proposal.isSelected {
            let project = proposal.project
            switch proposal.action {
            case .refresh(let productID, let checkoutID):
                guard let p = portfolio.products.firstIndex(where: { $0.id == productID }),
                      let c = portfolio.products[p].checkouts.firstIndex(where: { $0.id == checkoutID }) else { continue }
                portfolio.products[p].checkouts[c].detected = project.metadata
                portfolio.products[p].checkouts[c].isGitRepository = project.isGitRepository
                portfolio.products[p].checkouts[c].isWorktree = project.isWorktree
                mergeStack(project.metadata.stack, into: &portfolio.products[p])
                touched.append(productID)
            case .addCheckout(let productID):
                guard let p = portfolio.products.firstIndex(where: { $0.id == productID }) else { continue }
                addCheckout(project, to: &portfolio.products[p])
                touched.append(productID)
            case .createProduct:
                if let key = project.repository?.webURL, let existing = createdByRepo[key],
                   let p = portfolio.products.firstIndex(where: { $0.id == existing }) {
                    addCheckout(project, to: &portfolio.products[p])
                    continue
                }
                var product = Product(name: displayName(project), group: group)
                product.slug = Slug.unique(product.name, taken: Set(portfolio.products.map(\.slug)))
                product.tagline = project.description ?? ""
                product.lifecycle = project.isGitRepository ? .active : .idea
                var development = ProductEnvironment(name: "Local", tier: .development)
                if let url = project.metadata.devURL { development.domains = [url] }
                product.environments = [development]
                addCheckout(project, to: &product)
                portfolio.products.append(product)
                if let key = project.repository?.webURL { createdByRepo[key] = product.id }
                touched.append(product.id)
            }
        }
        return touched
    }

    static func displayName(_ project: DiscoveredProject) -> String {
        if let plugin = project.metadata.wordpressPluginName, !plugin.isEmpty { return plugin }
        return project.repository?.name ?? project.name
    }

    static func mergeStack(_ stack: [String], into product: inout Product) {
        for item in stack where !product.stack.contains(item) { product.stack.append(item) }
    }

    static func addCheckout(_ project: DiscoveredProject, to product: inout Product) {
        var repositoryID: UUID?
        if let url = project.repository {
            if let existing = product.repositories.first(where: { same($0, url) }) {
                repositoryID = existing.id
            } else {
                var repo = Repository()
                repo.provider = url.provider
                repo.owner = url.owner
                repo.name = url.name
                repo.webURL = url.webURL
                repo.cloneURL = project.remoteURL ?? url.webURL
                product.repositories.append(repo)
                repositoryID = repo.id
            }
        }
        var componentID: UUID?
        if let repositoryID, let linked = product.repositories.first(where: { $0.id == repositoryID })?.componentID {
            componentID = linked
        } else if project.metadata.suggestedKind != .other || product.components.isEmpty {
            let component = Component(name: project.metadata.wordpressPluginName ?? project.name,
                                      kind: project.metadata.suggestedKind, stack: project.metadata.stack)
            product.components.append(component)
            componentID = component.id
            if let repositoryID, let r = product.repositories.firstIndex(where: { $0.id == repositoryID }) {
                product.repositories[r].componentID = component.id
            }
        }
        var checkout = LocalCheckout()
        checkout.name = project.name
        checkout.path = project.path
        checkout.bookmark = try? URL(fileURLWithPath: project.path).bookmarkData()
        checkout.repositoryID = repositoryID
        checkout.componentID = componentID
        checkout.isGitRepository = project.isGitRepository
        checkout.isWorktree = project.isWorktree
        checkout.mainWorktreePath = project.mainWorktreePath
        checkout.detected = project.metadata
        product.checkouts.append(checkout)
        mergeStack(project.metadata.stack, into: &product)
        suggestRecipes(for: checkout, in: &product)
    }

    /// Detected commands become suggestions. They stay unapproved until the user approves them.
    static func suggestRecipes(for checkout: LocalCheckout, in product: inout Product) {
        func add(_ label: String, _ command: [String], safety: ActionSafety) {
            guard let program = command.first, !product.recipes.contains(where: { $0.label == label && $0.checkoutID == checkout.id }) else { return }
            var recipe = ActionRecipe()
            recipe.label = label
            recipe.executable = program
            recipe.arguments = Array(command.dropFirst())
            recipe.checkoutID = checkout.id
            recipe.environmentID = product.environment(tier: .development)?.id
            recipe.safety = safety
            recipe.isSuggested = true
            recipe.opensInTerminal = label != "Run Tests"
            product.recipes.append(recipe)
        }
        let suffix = product.checkouts.count > 1 ? " · \(checkout.name)" : ""
        if !checkout.detected.testCommand.isEmpty { add("Run Tests\(suffix)", checkout.detected.testCommand, safety: .localWrite) }
        if !checkout.detected.startCommand.isEmpty { add("Start Dev Server\(suffix)", checkout.detected.startCommand, safety: .localWrite) }
        if !checkout.detected.composeServices.isEmpty { add("Docker Compose Up\(suffix)", ["docker", "compose", "up"], safety: .localWrite) }
        MobileRecipes.add(to: &product, checkout: checkout, devices: MobileDevices.cached)
        for recipe in DesktopProject.recipes(for: checkout, environmentID: product.environment(tier: .development)?.id, suffix: suffix)
        where !product.recipes.contains(where: { $0.label == recipe.label && $0.checkoutID == checkout.id }) {
            product.recipes.append(recipe)
        }
    }

    /// Resolves a checkout whose folder moved, using its bookmark. Returns the new path, or nil.
    public static func recoverPath(for checkout: LocalCheckout) -> String? {
        guard let bookmark = checkout.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }
}
