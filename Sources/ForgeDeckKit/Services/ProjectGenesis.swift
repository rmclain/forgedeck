import Foundation

// Project Genesis: start a new product from an idea.
//
// ForgeDeck does the parts that must be exact itself: it checks the destination, makes the folder, runs `git init`,
// runs a starter's generator from a fixed argument list, and registers the product. Nothing comes from agent output
// there. The agent does the parts that need judgment, through the same .forgedeck files the other setup flows use:
//
//   1. Plan. The agent writes `.forgedeck/blueprint.json`: the stack it recommends and why, alternatives, structure,
//      tools, build steps, the production plan, and the variables the project will need (names only). It builds nothing.
//   2. Approve. The person reviews the blueprint in ForgeDeck, picks the stack, and approves. The approval lives on the
//      product (`Product.genesis`), never in a file the agent writes.
//   3. Build. The agent scaffolds, proves it builds and runs, and reports each step's real result in the blueprint.
//      It proposes run commands, environments, and skills in run.json, environments.json, and skills.json, which the
//      person reviews with the existing sheets. A planned production host stays Planned: it is never shown as live.

/// What ForgeDeck remembers about a product it started. Stored on the product, so it survives a restart and an agent
/// cannot change it.
public struct GenesisRecord: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// The agent is writing the blueprint.
        case planning
        /// A starter's generator or the agent is building.
        case building
        /// The person closed the setup checklist.
        case finished
    }

    /// The idea in the person's words.
    public var idea: String
    /// The stack the person asked for, if any.
    public var preference: String
    /// The starter ForgeDeck ran, by id. nil when the agent plans the stack.
    public var starter: String?
    public var usesAgent: Bool
    public var phase: Phase
    public var createdAt: Date
    /// Set when the person approves a blueprint.
    public var approvedStack: String?
    public var approvedAt: Date?
    /// The blueprint's summary and structure at approval, for the agent's context.
    public var architecture: String?
    /// The production plan at approval, e.g. "Vercel, app.example.com". Planned: nothing is deployed.
    public var plannedProduction: String?
    /// The starter generator's exit code. nil while it runs or when there is none.
    public var scaffoldExit: Int32?
    public var finishedAt: Date?

    public init(idea: String, preference: String = "", starter: String? = nil, usesAgent: Bool, phase: Phase, createdAt: Date = .now) {
        self.idea = idea
        self.preference = preference
        self.starter = starter
        self.usesAgent = usesAgent
        self.phase = phase
        self.createdAt = createdAt
    }
}

// MARK: Starters

/// A known way to start a project: a generator run from a fixed argument list, the files ForgeDeck writes when there
/// is no generator, and the commands it proposes for Play and Actions. Picking one skips the agent's planning.
public struct GenesisStarter: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    /// The program the generator needs, checked before it is offered.
    public var tool: String?
    /// Run in the new folder, in order. `{slug}` and `{module}` are replaced. Empty: ForgeDeck writes the files itself.
    public var scaffold: [[String]]
    public var stack: [String]
    public var gitignore: [String]
    /// Files ForgeDeck writes when there is no generator, relative path to contents. `{name}`, `{slug}`, `{idea}`.
    public var files: [String: String]
    /// Proposed in `.forgedeck/run.json` once the folder is ready. The person reviews them.
    public var commands: [ProposedRun]

    public static let all: [GenesisStarter] = [
        GenesisStarter(id: "nextjs", title: "Next.js", summary: "React web app with server routes, TypeScript, and the App Router",
                       tool: "npx", scaffold: [["npx", "--yes", "create-next-app@latest", ".", "--yes"]],
                       stack: ["Next.js", "React", "TypeScript"], gitignore: [], files: [:],
                       commands: [ProposedRun(label: "Start Dev Server", kind: "web", steps: [["npm", "run", "dev"]], url: "http://localhost:3000", note: "create-next-app"),
                                  ProposedRun(label: "Build", steps: [["npm", "run", "build"]], terminal: false),
                                  ProposedRun(label: "Lint", steps: [["npm", "run", "lint"]], terminal: false)]),
        GenesisStarter(id: "vite-react", title: "Vite + React", summary: "Single-page web app with React and TypeScript",
                       tool: "npm", scaffold: [["npm", "create", "--yes", "vite@latest", ".", "--", "--template", "react-ts"], ["npm", "install"]],
                       stack: ["Vite", "React", "TypeScript"], gitignore: [], files: [:],
                       commands: [ProposedRun(label: "Start Dev Server", kind: "web", steps: [["npm", "run", "dev"]], url: "http://localhost:5173", note: "create-vite"),
                                  ProposedRun(label: "Build", steps: [["npm", "run", "build"]], terminal: false)]),
        GenesisStarter(id: "fastapi", title: "FastAPI", summary: "Python API with uv, FastAPI, and a test setup",
                       tool: "uv", scaffold: [["uv", "init", "--app", "--name", "{slug}", "."], ["uv", "add", "fastapi[standard]"], ["uv", "add", "--dev", "pytest"]],
                       stack: ["Python", "FastAPI", "uv"], gitignore: [], files: [:],
                       commands: [ProposedRun(label: "Start API", kind: "web", steps: [["uv", "run", "fastapi", "dev", "main.py"]], url: "http://127.0.0.1:8000/docs",
                                              note: "Add `app = FastAPI()` to main.py first"),
                                  ProposedRun(label: "Run Tests", steps: [["uv", "run", "pytest"]], terminal: false)]),
        GenesisStarter(id: "python", title: "Python", summary: "Python package or script, managed with uv",
                       tool: "uv", scaffold: [["uv", "init", "--name", "{slug}", "."]],
                       stack: ["Python", "uv"], gitignore: [], files: [:],
                       commands: [ProposedRun(label: "Run", steps: [["uv", "run", "main.py"]], terminal: false)]),
        GenesisStarter(id: "swift", title: "Swift Package", summary: "Swift command line tool or library, built with SwiftPM",
                       tool: "swift", scaffold: [["swift", "package", "init", "--type", "executable", "--name", "{module}"]],
                       stack: ["Swift", "SwiftPM"], gitignore: [], files: [:],
                       commands: [ProposedRun(label: "Run", steps: [["swift", "run"]], terminal: false),
                                  ProposedRun(label: "Run Tests", steps: [["swift", "test"]], terminal: false)]),
        GenesisStarter(id: "node", title: "Node.js", summary: "Node.js package or service with an empty package.json",
                       tool: "npm", scaffold: [["npm", "init", "--yes"]],
                       stack: ["Node.js"], gitignore: ["node_modules/"], files: [:],
                       commands: [ProposedRun(label: "Run Tests", steps: [["npm", "test"]], terminal: false)]),
        GenesisStarter(id: "go", title: "Go", summary: "Go module for a service or command line tool",
                       tool: "go", scaffold: [["go", "mod", "init", "{slug}"]],
                       stack: ["Go"], gitignore: [], files: ["main.go": "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"{name}\")\n}\n"],
                       commands: [ProposedRun(label: "Run", steps: [["go", "run", "."]], terminal: false),
                                  ProposedRun(label: "Run Tests", steps: [["go", "test", "./..."]], terminal: false)]),
        GenesisStarter(id: "rust", title: "Rust", summary: "Rust binary crate, built with Cargo",
                       tool: "cargo", scaffold: [["cargo", "init", "--name", "{module}"]],
                       stack: ["Rust", "Cargo"], gitignore: [], files: [:],
                       commands: [ProposedRun(label: "Run", steps: [["cargo", "run"]], terminal: false),
                                  ProposedRun(label: "Run Tests", steps: [["cargo", "test"]], terminal: false)]),
        GenesisStarter(id: "wordpress-plugin", title: "WordPress Plugin", summary: "A plugin folder with its main file and header",
                       tool: nil, scaffold: [], stack: ["WordPress", "PHP"], gitignore: ["vendor/", "node_modules/"],
                       files: ["{slug}.php": """
                       <?php
                       /**
                        * Plugin Name: {name}
                        * Description: {idea}
                        * Version: 0.1.0
                        * Requires PHP: 8.1
                        * Text Domain: {slug}
                        */

                       if ( ! defined( 'ABSPATH' ) ) {
                       \texit;
                       }

                       """],
                       commands: []),
        GenesisStarter(id: "empty", title: "Empty Folder", summary: "A README and a .gitignore, nothing else",
                       tool: nil, scaffold: [], stack: [], gitignore: [], files: [:], commands: []),
    ]

    public static func find(_ id: String?) -> GenesisStarter? { all.first { $0.id == id } }

    /// The generator's argument lists with the placeholders filled in.
    public func scaffoldCommands(slug: String, module: String) -> [[String]] {
        scaffold.map { step in step.map { $0.replacingOccurrences(of: "{slug}", with: slug).replacingOccurrences(of: "{module}", with: module) } }
    }

    /// A generator that refuses a folder with files in it gets the folder before anything else is written.
    public var needsEmptyFolder: Bool { !scaffold.isEmpty }
}

// MARK: Destination

public struct GenesisDestination: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Nothing is there; the folder is made.
        case new
        /// A folder with nothing in it.
        case emptyFolder
        /// A folder with this many items. Used only when the person chose to set up there.
        case notEmpty(Int)
    }

    public var path: String
    public var state: State?
    /// Block creating.
    public var problems: [String]
    /// Shown, do not block.
    public var warnings: [String]
    public var canCreate: Bool { problems.isEmpty && state != nil }
}

public struct GenesisRequest: Sendable, Equatable {
    public var name: String
    public var idea: String
    public var parent: String
    public var folder: String
    public var preference: String
    public var starter: GenesisStarter?
    public var useExistingFolder: Bool
    public var initializeGit: Bool
    public var group: String

    public init(name: String, idea: String, parent: String, folder: String, preference: String = "", starter: GenesisStarter? = nil,
                useExistingFolder: Bool = false, initializeGit: Bool = true, group: String = "Products") {
        self.name = name
        self.idea = idea
        self.parent = parent
        self.folder = folder
        self.preference = preference
        self.starter = starter
        self.useExistingFolder = useExistingFolder
        self.initializeGit = initializeGit
        self.group = group
    }

    public var usesAgent: Bool { starter == nil }
    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var slug: String { ProjectGenesis.folderName(for: name) }
}

public struct GenesisCreation: Sendable, Equatable {
    public var path: String
    public var createdFolder: Bool
    public var gitInitialized: Bool
    /// Relative paths ForgeDeck wrote.
    public var wroteFiles: [String]
    /// What went wrong without stopping the creation, like Git not being installed.
    public var notes: [String]
}

public enum GenesisError: Error, Equatable, CustomStringConvertible {
    case invalid([String])
    case filesystem(String)

    public var description: String {
        switch self {
        case .invalid(let problems): problems.joined(separator: " ")
        case .filesystem(let message): message
        }
    }
}

public enum ProjectGenesis {
    /// Folders ForgeDeck never creates a project in, even when they are writable.
    static let systemRoots = ["/System", "/Library", "/bin", "/sbin", "/usr", "/private/etc", "/private/var", "/etc", "/var", "/Applications", "/Volumes/Recovery"]
    static let ignoredEntries: Set<String> = [".DS_Store", ".localized"]

    /// The default folder name for a project name: lowercase words joined by dashes.
    public static func folderName(for name: String) -> String {
        let slug = Slug.make(name)
        return slug.isEmpty ? "new-project" : String(slug.prefix(64))
    }

    /// A name a Swift or Rust module accepts: letters, digits, and underscores, not starting with a digit.
    public static func moduleName(for name: String) -> String {
        var words = name.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if words.isEmpty { words = ["App"] }
        var module = words.joined()
        if module.first?.isNumber == true { module = "App" + module }
        return String(module.prefix(64))
    }

    // MARK: Checking the destination

    public static func check(_ request: GenesisRequest, existing: [Product], fileManager: FileManager = .default) -> GenesisDestination {
        var problems: [String] = []
        var warnings: [String] = []
        let name = request.trimmedName
        if name.isEmpty { problems.append("Give the project a name.") }
        if name.count > 60 || name.contains(where: \.isNewline) { problems.append("Keep the name to one line of 60 characters or fewer.") }

        let folder = request.folder.trimmingCharacters(in: .whitespaces)
        if folder.isEmpty {
            problems.append("Give the folder a name.")
        } else if folder.contains("/") || folder.contains(":") || folder == "." || folder == ".." || folder.hasPrefix(".")
                    || folder.count > 100 || folder.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            problems.append("The folder name can't contain / or :, start with a dot, or be longer than 100 characters.")
        }

        let parentInput = (request.parent as NSString).expandingTildeInPath
        guard parentInput.hasPrefix("/") else {
            return GenesisDestination(path: "", state: nil, problems: problems + ["Choose where the project folder goes."], warnings: warnings)
        }
        let parent = URL(fileURLWithPath: parentInput).resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: parent, isDirectory: &isDirectory) || !isDirectory.boolValue {
            problems.append("\(home(parent)) doesn't exist or isn't a folder.")
        } else if !fileManager.isWritableFile(atPath: parent) {
            problems.append("You can't write to \(home(parent)). Choose a folder you own.")
        }
        let userTemporary = parent.hasPrefix("/private/var/folders/") || parent.hasPrefix("/var/folders/")
        if systemRoots.contains(where: { parent == $0 || parent.hasPrefix($0 + "/") }) && !userTemporary {
            problems.append("\(parent) is a system folder. Choose a folder in your home folder.")
        }

        let path = folder.isEmpty ? parent : (parent as NSString).appendingPathComponent(folder)
        var state: GenesisDestination.State? = nil
        if !folder.isEmpty && problems.isEmpty {
            if let type = (try? fileManager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType {
                if type == .typeSymbolicLink {
                    problems.append("\(folder) is a link to another folder. Choose another name.")
                } else if type != .typeDirectory {
                    problems.append("A file named \(folder) is already there. Choose another name.")
                } else {
                    let items = ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).filter { !ignoredEntries.contains($0) }
                    if items.isEmpty {
                        state = .emptyFolder
                    } else if request.useExistingFolder {
                        state = .notEmpty(items.count)
                        if request.starter?.needsEmptyFolder == true {
                            problems.append("The \(request.starter!.title) generator needs an empty folder, and \(folder) has \(items.count) item\(items.count == 1 ? "" : "s").")
                        } else {
                            warnings.append("\(folder) already has \(items.count) item\(items.count == 1 ? "" : "s"). Nothing in it is changed or overwritten; new files are only added.")
                        }
                    } else {
                        problems.append("\(folder) already exists and has \(items.count) item\(items.count == 1 ? "" : "s"). Choose another name, or set up in the existing folder.")
                    }
                }
            } else {
                state = .new
            }
        }

        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for product in existing {
            for checkout in product.checkouts {
                let other = URL(fileURLWithPath: checkout.path).standardizedFileURL.path
                if other == standardized {
                    problems.append("\(home(standardized)) already belongs to \(product.name). Open it instead.")
                } else if standardized.hasPrefix(other + "/") {
                    warnings.append("This is inside \(product.name)'s folder.")
                }
            }
        }
        if !name.isEmpty, existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            warnings.append("Another product is already called \(name).")
        }
        return GenesisDestination(path: standardized, state: problems.isEmpty ? state : nil, problems: problems, warnings: warnings)
    }

    // MARK: Creating

    /// Makes the folder, writes the starter's files when it has no generator, and runs `git init`. Checks the
    /// destination again first. When a step fails, a folder this call made is removed again, as long as it holds only
    /// what this call wrote. A starter's generator is not run here: it runs in a terminal the person can see.
    public static func create(_ request: GenesisRequest, existing: [Product], runner: ProcessRunning,
                              git: URL? = ExecutableLocator.find("git"), fileManager: FileManager = .default) async throws -> GenesisCreation {
        let destination = check(request, existing: existing, fileManager: fileManager)
        guard destination.canCreate, let state = destination.state else { throw GenesisError.invalid(destination.problems) }
        let root = URL(fileURLWithPath: destination.path, isDirectory: true)
        var created = false
        var wrote: [String] = []
        do {
            if state == .new {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
                created = true
            }
            // A generator wants the folder to itself; its own README and .gitignore come with it.
            if request.starter?.needsEmptyFolder != true {
                for (relative, contents) in starterFiles(request) {
                    let url = root.appending(path: relative)
                    guard !fileManager.fileExists(atPath: url.path) else { continue }
                    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
                    wrote.append(relative)
                }
            }
        } catch {
            if created { removeIfOnlyOurs(root, wrote: wrote, fileManager: fileManager) }
            throw GenesisError.filesystem("Could not create \(home(root.path)): \(error.localizedDescription)")
        }

        var notes: [String] = []
        var gitReady = fileManager.fileExists(atPath: root.appending(path: ".git").path)
        if request.initializeGit && !gitReady {
            if let git {
                let result = try? await runner.run(ProcessRequest(executable: git, arguments: ["init", "--initial-branch=main"], workingDirectory: root, timeout: 20))
                if result?.ok == true {
                    gitReady = true
                } else {
                    notes.append("Git could not create a repository: \(result.map { $0.stderr.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "it did not start").")
                }
            } else {
                notes.append("Git is not installed, so there is no repository yet. Install the Xcode command line tools, then run git init.")
            }
        }
        return GenesisCreation(path: root.path, createdFolder: created, gitInitialized: gitReady, wroteFiles: wrote.sorted(), notes: notes)
    }

    /// README, .gitignore, and the starter's own files, with placeholders filled in.
    public static func starterFiles(_ request: GenesisRequest) -> [String: String] {
        let name = request.trimmedName
        let idea = request.idea.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = idea.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var files: [String: String] = [:]
        files["README.md"] = "# \(name)\n" + (idea.isEmpty ? "" : "\n\(idea)\n")
        var ignore = [".DS_Store", ".env", ".env.*", "!.env.example"]
        ignore += request.starter?.gitignore ?? []
        files[".gitignore"] = ignore.joined(separator: "\n") + "\n"
        for (path, contents) in request.starter?.files ?? [:] {
            func fill(_ text: String) -> String {
                text.replacingOccurrences(of: "{name}", with: name).replacingOccurrences(of: "{slug}", with: request.slug)
                    .replacingOccurrences(of: "{idea}", with: firstLine.replacingOccurrences(of: "*/", with: "* /"))
            }
            files[fill(path)] = fill(contents)
        }
        return files
    }

    static func removeIfOnlyOurs(_ root: URL, wrote: [String], fileManager: FileManager) {
        let allowed = Set(wrote.map { $0.split(separator: "/").first.map(String.init) ?? $0 }).union(ignoredEntries)
        let items = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        guard items.allSatisfy(allowed.contains) else { return }
        try? fileManager.removeItem(at: root)
    }

    /// The product record for a new project, before it joins the portfolio.
    public static func product(for request: GenesisRequest, creation: GenesisCreation, existing: [Product], now: Date = .now) -> Product {
        var product = Product(name: request.trimmedName, group: request.group.isEmpty ? "Products" : request.group)
        product.slug = Slug.unique(product.name, taken: Set(existing.map(\.slug)))
        let idea = request.idea.trimmingCharacters(in: .whitespacesAndNewlines)
        product.tagline = String((idea.split(whereSeparator: \.isNewline).first.map(String.init) ?? "").prefix(140))
        product.lifecycle = .idea
        product.stack = request.starter?.stack ?? []
        product.environments = [ProductEnvironment(name: "Local", tier: .development)]
        var checkout = LocalCheckout()
        checkout.name = URL(fileURLWithPath: creation.path).lastPathComponent
        checkout.path = creation.path
        checkout.isGitRepository = creation.gitInitialized
        checkout.addedAt = now
        product.checkouts = [checkout]
        var record = GenesisRecord(idea: idea, preference: request.preference.trimmingCharacters(in: .whitespacesAndNewlines),
                                   starter: request.starter?.id, usesAgent: request.usesAgent,
                                   phase: request.usesAgent ? .planning : .building, createdAt: now)
        if let starter = request.starter, !starter.needsEmptyFolder { record.scaffoldExit = 0 }
        product.genesis = record
        return product
    }

    /// The starter's commands as a run.json proposal, for the existing Run Setup review.
    public static func runFile(for starter: GenesisStarter) -> Data? {
        guard !starter.commands.isEmpty else { return nil }
        struct File: Encodable { var commands: [ProposedRun] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(File(commands: starter.commands))
    }

    /// Writes the starter's run.json unless one is already there.
    @discardableResult
    public static func writeRunFile(for starter: GenesisStarter, in folder: String, fileManager: FileManager = .default) -> Bool {
        guard let data = runFile(for: starter) else { return false }
        let url = URL(fileURLWithPath: folder).appending(path: RunSetup.relativePath)
        guard !fileManager.fileExists(atPath: url.path) else { return false }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .withoutOverwriting)) != nil
    }

    // MARK: Tools

    /// Programs a recommendation can count on, checked on this Mac.
    public static let knownTools = ["git", "gh", "node", "npm", "npx", "pnpm", "yarn", "bun", "deno", "python3", "uv", "pipx", "swift", "xcodebuild",
                                    "go", "cargo", "php", "composer", "wp", "ruby", "java", "flutter", "docker", "psql", "vercel", "flyctl", "wrangler"]

    public static func installedTools(find: (String) -> URL? = { ExecutableLocator.find($0) }) -> [String] {
        knownTools.filter { find($0) != nil }
    }

    static func home(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: Blueprint

/// The agent's plan, in `.forgedeck/blueprint.json`. Untrusted: every field is checked before it is shown, and nothing
/// in it runs. Approval is stored on the product, not in this file.
public struct Blueprint: Codable, Hashable, Sendable {
    public struct Stack: Codable, Hashable, Sendable {
        public var name: String
        public var why: String?
        public var parts: [String]?
        public init(name: String, why: String? = nil, parts: [String]? = nil) {
            self.name = name
            self.why = why
            self.parts = parts
        }
    }

    public struct Folder: Codable, Hashable, Sendable {
        public var path: String
        public var purpose: String?
        public init(path: String, purpose: String? = nil) {
            self.path = path
            self.purpose = purpose
        }
    }

    public struct Tool: Codable, Hashable, Sendable {
        public var name: String
        public var why: String?
        public var installed: Bool?
        public init(name: String, why: String? = nil, installed: Bool? = nil) {
            self.name = name
            self.why = why
            self.installed = installed
        }
    }

    public struct Step: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Sendable { case pending, running, done, failed, skipped }
        public var title: String
        public var status: String?
        public var detail: String?
        public init(title: String, status: String? = nil, detail: String? = nil) {
            self.title = title
            self.status = status
            self.detail = detail
        }
        public var state: Status { Status(rawValue: (status ?? "pending").lowercased()) ?? .pending }
    }

    public struct Production: Codable, Hashable, Sendable {
        /// Where it will run: Vercel, Fly.io, a VPS, the App Store.
        public var host: String?
        /// The planned domain. Planned: it may not exist.
        public var domain: String?
        public var staging: Bool?
        /// The path that will name the running version, like /api/version.
        public var versionPath: String?
        /// The path that will answer when it is up, like /api/health.
        public var healthPath: String?
        /// node, python, php, wordpress, or none: the ForgeDeck companion that fits.
        public var companion: String?
        public var note: String?
        public init(host: String? = nil, domain: String? = nil, staging: Bool? = nil, versionPath: String? = nil, healthPath: String? = nil,
                    companion: String? = nil, note: String? = nil) {
            self.host = host
            self.domain = domain
            self.staging = staging
            self.versionPath = versionPath
            self.healthPath = healthPath
            self.companion = companion
            self.note = note
        }
    }

    public struct Variable: Codable, Hashable, Sendable {
        public var name: String
        public var why: String?
        public var secret: Bool?
        /// development, staging, production.
        public var environments: [String]?
        public init(name: String, why: String? = nil, secret: Bool? = nil, environments: [String]? = nil) {
            self.name = name
            self.why = why
            self.secret = secret
            self.environments = environments
        }
    }

    public var summary: String
    public var stack: Stack
    public var alternatives: [Stack]?
    public var structure: [Folder]?
    public var tools: [Tool]?
    public var steps: [Step]?
    public var production: Production?
    public var variables: [Variable]?
    public var questions: [String]?

    public init(summary: String, stack: Stack, alternatives: [Stack]? = nil, structure: [Folder]? = nil, tools: [Tool]? = nil, steps: [Step]? = nil,
                production: Production? = nil, variables: [Variable]? = nil, questions: [String]? = nil) {
        self.summary = summary
        self.stack = stack
        self.alternatives = alternatives
        self.structure = structure
        self.tools = tools
        self.steps = steps
        self.production = production
        self.variables = variables
        self.questions = questions
    }

    public var stepCounts: (done: Int, failed: Int, total: Int) {
        let steps = steps ?? []
        return (steps.filter { $0.state == .done || $0.state == .skipped }.count, steps.filter { $0.state == .failed }.count, steps.count)
    }

    /// One line for the product's notes and the agent's context: "Vercel, app.example.com, with staging".
    public var productionLine: String? {
        guard let production else { return nil }
        let parts = [production.host, production.domain].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ") + (production.staging == true ? ", with staging" : "")
    }
}

/// The blueprint as read from a checkout.
public struct BlueprintFile: Sendable, Hashable {
    public var blueprint: Blueprint?
    /// Block approving.
    public var problems: [String]
    public var warnings: [String]
    public var modified: Date?

    public init(blueprint: Blueprint?, problems: [String] = [], warnings: [String] = [], modified: Date? = nil) {
        self.blueprint = blueprint
        self.problems = problems
        self.warnings = warnings
        self.modified = modified
    }

    public var isApprovable: Bool { blueprint != nil && problems.isEmpty }
}

public enum BlueprintCheck {
    public static let relativePath = ".forgedeck/blueprint.json"
    static let maxBytes = 64 * 1024
    static let tiers: Set<String> = ["development", "local", "staging", "production", "preview"]
    static let companions: Set<String> = ["node", "python", "php", "wordpress", "none"]

    public static func read(_ product: Product) -> BlueprintFile? {
        guard let checkout = product.primaryCheckout else { return nil }
        return read(folder: checkout.path)
    }

    public static func read(folder: String) -> BlueprintFile? {
        let url = URL(fileURLWithPath: folder).appending(path: relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = attributes[.modificationDate] as? Date
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { return BlueprintFile(blueprint: nil, problems: ["\(relativePath) is not a regular file."]) }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxBytes else { return BlueprintFile(blueprint: nil, problems: ["\(relativePath) is larger than 64 KB."]) }
        guard let data = try? Data(contentsOf: url) else { return BlueprintFile(blueprint: nil, problems: ["\(relativePath) could not be read."]) }
        var file = parse(data)
        file.modified = modified
        return file
    }

    public static func parse(_ data: Data) -> BlueprintFile {
        let blueprint: Blueprint
        do {
            blueprint = try JSONDecoder().decode(Blueprint.self, from: data)
        } catch {
            return BlueprintFile(blueprint: nil, problems: ["\(relativePath) is not valid: it needs at least {\"summary\": \"…\", \"stack\": {\"name\": \"…\"}}. See `\(Brand.cliName) help`."])
        }
        let (problems, warnings) = check(blueprint)
        return BlueprintFile(blueprint: blueprint, problems: problems, warnings: warnings)
    }

    public static func check(_ blueprint: Blueprint) -> (problems: [String], warnings: [String]) {
        var problems: [String] = []
        var warnings: [String] = []
        func text(_ value: String?, _ label: String, max: Int, required: Bool = false) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if required && trimmed.isEmpty { problems.append("\(label) is empty.") }
            if trimmed.count > max { problems.append("\(label) is longer than \(max) characters.") }
            if !trimmed.isEmpty, Redactor.looksLikeSecret(trimmed) { problems.append("\(label) looks like it holds a secret value. Use names only.") }
        }
        text(blueprint.summary, "The summary", max: 1200, required: true)
        let stacks = [blueprint.stack] + (blueprint.alternatives ?? [])
        if (blueprint.alternatives ?? []).count > 4 { problems.append("List at most 4 alternatives.") }
        for (index, stack) in stacks.enumerated() {
            let label = index == 0 ? "The stack" : "Alternative \(index)"
            text(stack.name, "\(label)'s name", max: 80, required: true)
            text(stack.why, "\(label)'s reason", max: 600)
            if (stack.parts ?? []).count > 12 { problems.append("\(label) lists more than 12 parts.") }
            for part in stack.parts ?? [] { text(part, "A part of \(label.lowercased())", max: 40, required: true) }
        }
        if (blueprint.structure ?? []).count > 30 { problems.append("The structure lists more than 30 folders.") }
        for folder in blueprint.structure ?? [] {
            let path = folder.path.trimmingCharacters(in: .whitespaces)
            if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") || path.split(separator: "/").contains("..") || path.count > 120 {
                problems.append("Structure path \"\(path)\" must be relative to the project folder, without ..")
            }
            text(folder.purpose, "The purpose of \(path)", max: 200)
        }
        if (blueprint.tools ?? []).count > 20 { problems.append("List at most 20 tools.") }
        for tool in blueprint.tools ?? [] { text(tool.name, "A tool name", max: 40, required: true); text(tool.why, "Why \(tool.name)", max: 200) }
        if (blueprint.steps ?? []).count > 30 { problems.append("List at most 30 steps.") }
        for step in blueprint.steps ?? [] {
            text(step.title, "A step title", max: 120, required: true)
            text(step.detail, "The detail of \"\(step.title)\"", max: 600)
            if let status = step.status, Blueprint.Step.Status(rawValue: status.lowercased()) == nil {
                problems.append("Step \"\(step.title)\" has status \"\(status)\". Use pending, running, done, failed, or skipped.")
            }
        }
        if let production = blueprint.production {
            text(production.host, "The production host", max: 80)
            text(production.note, "The production note", max: 400)
            if let domain = production.domain?.trimmingCharacters(in: .whitespaces), !domain.isEmpty, !isHostname(domain) {
                problems.append("The production domain \"\(domain)\" should be a host name like app.example.com, without https://.")
            }
            for (label, path) in [("versionPath", production.versionPath), ("healthPath", production.healthPath)] {
                if let path, !path.isEmpty, !path.hasPrefix("/") || path.count > 120 || path.contains(" ") {
                    problems.append("production.\(label) should be a path like /api/health.")
                }
            }
            if let companion = production.companion?.lowercased(), !companions.contains(companion) {
                warnings.append("Unknown companion \"\(companion)\". \(Brand.name) has node, python, php, and wordpress.")
            }
        }
        if (blueprint.variables ?? []).count > 40 { problems.append("List at most 40 variables.") }
        var names = Set<String>()
        for variable in blueprint.variables ?? [] {
            if !RunSetup.isValidVariable(variable.name) { problems.append("\"\(variable.name)\" is not a valid variable name. Use letters, digits, and _.") }
            if !names.insert(variable.name).inserted { warnings.append("\(variable.name) is listed twice.") }
            text(variable.why, "Why \(variable.name)", max: 200)
            for tier in variable.environments ?? [] where !tiers.contains(tier.lowercased()) {
                problems.append("\(variable.name) names environment \"\(tier)\". Use development, staging, or production.")
            }
        }
        if (blueprint.questions ?? []).count > 6 { warnings.append("More than 6 open questions. Only the first 6 are shown.") }
        for question in blueprint.questions ?? [] { text(question, "A question", max: 300) }
        return (problems, warnings)
    }

    static func isHostname(_ text: String) -> Bool {
        let labels = text.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, text.count <= 253 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0 == "-" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
        }
    }

    /// The variable tiers a blueprint variable may resolve into.
    public static func tiers(_ variable: Blueprint.Variable) -> [EnvironmentTier] {
        let named = (variable.environments ?? []).compactMap { name -> EnvironmentTier? in
            switch name.lowercased() {
            case "development", "local": .development
            case "staging": .staging
            case "production": .production
            default: nil
            }
        }
        return named.isEmpty ? [.development] : Array(Set(named)).sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: Checklist

/// Where a new project stands, worked out from what ForgeDeck can see. The setup card shows it.
public struct GenesisChecklist: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case done, working, needsYou, attention, pending, optional
    }

    public enum Item: String, Sendable, CaseIterable {
        case folder, plan, build, commands, environments, skills, github
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var item: Item
        public var state: State
        public var title: String
        public var detail: String
        public var id: Item { item }
    }

    public var rows: [Row]

    /// The row that wants something next: the first that needs the person, then the first still open.
    public var next: Row? {
        rows.first { $0.state == .needsYou || $0.state == .attention } ?? rows.first { $0.state == .working || $0.state == .pending }
    }

    public var isComplete: Bool { rows.allSatisfy { $0.state == .done || $0.state == .optional } }

    public struct Inputs: Sendable, Equatable {
        public var agentName = "The agent"
        public var blueprint: BlueprintFile?
        public var scaffoldRunning = false
        public var agentRunning = false
        public var runToReview = 0
        public var environmentsToReview = 0
        public var skillsToReview = 0
        public init() {}
    }

    public static func make(_ product: Product, inputs: Inputs) -> GenesisChecklist {
        guard let genesis = product.genesis else { return GenesisChecklist(rows: []) }
        let agent = inputs.agentName
        var rows: [Row] = []
        let checkout = product.primaryCheckout
        rows.append(Row(item: .folder, state: checkout == nil ? .attention : .done, title: "Folder and Git",
                        detail: checkout.map { "\(ProjectGenesis.home($0.path))" + ($0.isGitRepository ? " · Git repository" : " · no Git repository") }
                            ?? "The folder is not linked. Add it under Settings."))

        let starter = GenesisStarter.find(genesis.starter)
        if genesis.usesAgent {
            if let approved = genesis.approvedStack {
                rows.append(Row(item: .plan, state: .done, title: "Plan", detail: "Approved: \(approved)"))
            } else if let file = inputs.blueprint {
                if file.isApprovable {
                    rows.append(Row(item: .plan, state: .needsYou, title: "Plan", detail: "\(agent) recommends \(file.blueprint!.stack.name). Review the blueprint."))
                } else {
                    rows.append(Row(item: .plan, state: .attention, title: "Plan",
                                    detail: file.problems.first.map { "The blueprint has a problem: \($0)" } ?? "The blueprint could not be read."))
                }
            } else {
                rows.append(Row(item: .plan, state: inputs.agentRunning ? .working : .attention, title: "Plan",
                                detail: inputs.agentRunning ? "\(agent) is researching the stack and writing the blueprint."
                                    : "No blueprint yet, and \(agent) is not running here. Start it again to continue."))
            }
        } else {
            rows.append(Row(item: .plan, state: .done, title: "Plan", detail: "Starter: \(starter?.title ?? "chosen by you")"))
        }

        if genesis.usesAgent {
            if genesis.approvedStack == nil {
                rows.append(Row(item: .build, state: .pending, title: "Build", detail: "Starts when you approve the plan."))
            } else {
                let counts = inputs.blueprint?.blueprint?.stepCounts ?? (done: 0, failed: 0, total: 0)
                let running = inputs.blueprint?.blueprint?.steps?.first { $0.state == .running }
                if counts.failed > 0 {
                    rows.append(Row(item: .build, state: .attention, title: "Build", detail: "\(counts.failed) step\(counts.failed == 1 ? "" : "s") failed, as \(agent) reports."))
                } else if counts.total > 0 && counts.done == counts.total {
                    rows.append(Row(item: .build, state: .done, title: "Build", detail: "All \(counts.total) steps reported done by \(agent)."))
                } else {
                    let progress = counts.total > 0 ? "\(counts.done) of \(counts.total) steps" : "Building"
                    rows.append(Row(item: .build, state: inputs.agentRunning ? .working : .attention, title: "Build",
                                    detail: inputs.agentRunning ? "\(progress)\(running.map { ": \($0.title)" } ?? "")"
                                        : "\(progress), and \(agent) is not running here. Start it again to continue."))
                }
            }
        } else if let starter, starter.needsEmptyFolder {
            if inputs.scaffoldRunning {
                rows.append(Row(item: .build, state: .working, title: "Build", detail: "The \(starter.title) generator is running in the terminal."))
            } else if let exit = genesis.scaffoldExit {
                rows.append(exit == 0 ? Row(item: .build, state: .done, title: "Build", detail: "The \(starter.title) generator finished.")
                            : Row(item: .build, state: .attention, title: "Build", detail: "The \(starter.title) generator stopped with code \(exit). Run it again."))
            } else {
                rows.append(Row(item: .build, state: .attention, title: "Build", detail: "The \(starter.title) generator did not finish. Run it again."))
            }
        } else {
            rows.append(Row(item: .build, state: .done, title: "Build", detail: "README and .gitignore written."))
        }

        let recipes = product.recipes.filter { $0.executor != .ssh }.count
        rows.append(inputs.runToReview > 0
                    ? Row(item: .commands, state: .needsYou, title: "Run and test", detail: "\(inputs.runToReview) command\(inputs.runToReview == 1 ? "" : "s") to review for Play and Actions.")
                    : recipes > 0 ? Row(item: .commands, state: .done, title: "Run and test", detail: "\(recipes) command\(recipes == 1 ? "" : "s") saved. Press Play to start it.")
                    : Row(item: .commands, state: .pending, title: "Run and test", detail: "No commands yet. \(agent) can work them out."))

        let production = product.environment(tier: .production)
        let planned = genesis.plannedProduction.map { "Planned: \($0). Not deployed, so it shows Unknown until a check answers." }
        rows.append(inputs.environmentsToReview > 0
                    ? Row(item: .environments, state: .needsYou, title: "Environments", detail: "\(inputs.environmentsToReview) proposed environment\(inputs.environmentsToReview == 1 ? "" : "s") to review.")
                    : production != nil ? Row(item: .environments, state: .done, title: "Environments",
                                              detail: production!.probes.isEmpty ? (planned ?? "Production added. Connect a status endpoint once it is deployed.") : "Production has checks.")
                    : Row(item: .environments, state: .optional, title: "Environments", detail: planned ?? "Local only. Add production when it is deployed."))

        let chosenSkills = (product.agentSkills ?? []).filter { !$0.isDismissed }.count
        rows.append(inputs.skillsToReview > 0
                    ? Row(item: .skills, state: .needsYou, title: "Skills", detail: "\(inputs.skillsToReview) suggestion\(inputs.skillsToReview == 1 ? "" : "s") from \(agent) to install or dismiss.")
                    : chosenSkills > 0 ? Row(item: .skills, state: .done, title: "Skills", detail: "\(chosenSkills) chosen for \(product.name).")
                    : Row(item: .skills, state: .optional, title: "Skills", detail: "None chosen. \(agent) can suggest some."))
        if let repository = product.repositories.first {
            rows.append(Row(item: .github, state: .done, title: "GitHub", detail: repository.fullName))
        } else {
            rows.append(Row(item: .github, state: .optional, title: "GitHub",
                            detail: product.primaryCheckout?.isGitRepository == true ? "Local only. Create a private repository when you want one." : "Needs a Git repository first."))
        }
        return GenesisChecklist(rows: rows)
    }
}

/// Creating the GitHub repository for a new project: a remote write the person confirms with press and hold.
public enum GenesisGitHub {
    /// `gh repo create` for the checkout, private, with origin set. It pushes nothing.
    public static func createArguments(name: String, folder: String, isPrivate: Bool = true) -> [String] {
        ["repo", "create", name, isPrivate ? "--private" : "--public", "--source", folder, "--remote", "origin"]
    }

    /// The repository URL `gh` prints, when it printed one.
    public static func createdURL(_ output: String) -> RepositoryURL? {
        output.split(whereSeparator: \.isWhitespace).lazy.compactMap { word in
            word.hasPrefix("https://github.com/") ? RepositoryURL.parse(String(word)) : nil
        }.first
    }
}

// MARK: Prompts

public enum GenesisPrompt {
    static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    }

    /// Planning only: research and write the blueprint, then wait.
    public static func plan(_ product: Product, folder: String, tools: [String], cli: String) -> String {
        let tool = cli.contains(" ") ? "\"\(cli)\"" : cli
        let genesis = product.genesis
        let idea = genesis?.idea.isEmpty == false ? genesis!.idea : product.tagline
        let preference = genesis?.preference ?? ""
        let git = product.primaryCheckout?.isGitRepository == true
        return """
        Help me start a new project, \(product.name). \(Brand.name) made the folder \(folder)\(git ? " with an empty Git repository" : ""). Nothing is built yet.

        The idea, in my words:
        \(quoted(idea.isEmpty ? "(no description: ask me what it is for)" : idea))

        \(preference.isEmpty ? "I have no stack in mind: recommend one." : "I would like to use: \(preference). Use it unless it clearly can't do the job, and say why if so.")
        Tools on this Mac: \(tools.isEmpty ? "none detected" : tools.joined(separator: ", ")).

        This step is planning only. Do not create project files, install anything, or run a generator yet.

        1. Understand what I want to build. If something essential is unclear (who it is for, web or native, the integrations it must have), \
        ask me up to three short questions first, then wait for my answers.
        2. Research the foundation: the frameworks that fit, their current stable versions, and each one's official generator. \
        Check the web for versions; don't rely on memory. Prefer mainstream choices with good docs, tools already on this Mac, \
        and the fewest moving parts that do the job. Consider testing, where it will run in production, and how \(Brand.name) can \
        see the deployed version (a version endpoint and a health endpoint).
        3. Write `\(BlueprintCheck.relativePath)` in the folder:
           {"summary": "two or three sentences: what it is and the architecture",
            "stack": {"name": "Next.js + PostgreSQL", "why": "the reasons, for this project", "parts": ["Next.js", "PostgreSQL", "Prisma", "Stripe"]},
            "alternatives": [{"name": "…", "why": "when it would be the better choice", "parts": ["…"]}],
            "structure": [{"path": "app/", "purpose": "routes and pages"}],
            "tools": [{"name": "node", "why": "runs the dev server", "installed": true}],
            "steps": [{"title": "Generate the app with create-next-app", "status": "pending"}],
            "production": {"host": "Vercel", "domain": "app.example.com", "staging": true, "versionPath": "/api/version", "healthPath": "/api/health",
                           "companion": "node", "note": "why this host"},
            "variables": [{"name": "DATABASE_URL", "why": "Postgres connection", "secret": true, "environments": ["development", "production"]}],
            "questions": ["Anything you need me to decide"]}
           - 1 to 3 alternatives. steps: the build steps you will take after I approve, 4 to 12, all "pending".
           - production is a plan: nothing is deployed and the domain may not exist. Leave out what you don't know.
           - variables are names and what they are for. Never a value, a key, or a token, anywhere in the file.
        4. Run `\(tool) blueprint check \(product.slug)` and fix every problem it prints.
        5. Tell me your recommendation in a few lines, then tell me to review the blueprint in \(Brand.name) (on \(product.name)'s Overview). \
        Then wait: don't build until \(Brand.name) or I tell you the plan is approved and which stack I chose.

        After I approve, build it like this:

        \(buildSteps(product, cli: cli))
        """
    }

    /// The build steps, shared by the plan prompt (so the agent knows what follows approval) and the build prompt.
    public static func buildSteps(_ product: Product, cli: String) -> String {
        let tool = cli.contains(" ") ? "\"\(cli)\"" : cli
        let git = product.primaryCheckout?.isGitRepository == true
        return """
        A. Build it one step at a time, following the steps in `\(BlueprintCheck.relativePath)`. Before a step, set its "status" to "running"; \
        after it, set "done" with a short "detail", "failed" with what went wrong, or "skipped" with why. \(Brand.name) shows these as you go. \
        Never mark a step done that didn't succeed. If I chose an alternative stack, first update the summary, stack, and steps to match it.
           - Use the official generator. If it insists on an empty folder, generate into a new temporary folder and move the files in; keep .forgedeck and .git.
           - Add a README that says how to run, test, and build it, a .gitignore that covers .env files, and a .env.example with variable names only. \
        Never write a secret value into any file. Ask me before installing anything outside this folder.
           - If the blueprint names a version or health endpoint, add it: a route that returns the version (or commit) and one that answers 200 when it is up.
        B. Prove it works: run the build and the tests, start it and check that it answers, then stop what you started. Put the real result in the step's detail.
        C. Write `\(RunSetup.relativePath)` with how to start, test, and build it on this Mac (format: SETTING UP RUN in `\(tool) help`), \
        then run `\(tool) run check \(product.slug)` and fix what it prints.
        D. Only if an environment already exists and answers today, propose it in `\(EnvironmentProposals.relativePath)` and run `\(tool) env check \(product.slug)`. \
        Don't propose environments that aren't deployed yet: the blueprint's production section records the plan.
        E. Suggest 3 to 6 skills for working on this project in `\(SkillSuggestions.relativePath)` (format: SUGGESTING SKILLS in `\(tool) help`) \
        and run `\(tool) skills check \(product.slug)`. Suggest only; install nothing.
        F. \(git ? "Commit the result to the local Git repository with a short message." : "There is no Git repository; don't create one.") \
        Don't create a GitHub repository, push, deploy, or sign up for any service.
        G. Tell me in a few lines what you built and how to run it, then tell me to finish in \(Brand.name): \(product.name) › Overview › Project setup.
        """
    }

    /// After approval, for a new session: the agent in the planning session already has these steps.
    public static func build(_ product: Product, stack: String, note: String?, cli: String, resuming: Bool = false) -> String {
        let opening = resuming
            ? "Continue building \(product.name). Read `\(BlueprintCheck.relativePath)`: steps marked done are finished; start at the first that isn't."
            : "The blueprint for \(product.name) in `\(BlueprintCheck.relativePath)` is approved. Build it with: \(stack)."
        return opening + (note.map { "\nMy note: \($0)" } ?? "") + "\n\n" + buildSteps(product, cli: cli)
    }

    /// The one line sent to the agent that wrote the blueprint, in its own terminal, when the person approves.
    public static func approvalMessage(stack: String, note: String?) -> String {
        let clean = { (text: String) in text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        return "\(Brand.name): the blueprint is approved. Build it with: \(clean(stack))."
            + (note.map { " My note: \(clean($0))" } ?? "")
            + " Follow build steps A to G from my first message."
    }

    /// The brief added to the agent's context for a product ForgeDeck started.
    public static func contextLines(_ genesis: GenesisRecord) -> [String] {
        var lines = ["Project brief (from \(Brand.name)'s project setup):"]
        if !genesis.idea.isEmpty { lines.append(quoted(genesis.idea)) }
        if let stack = genesis.approvedStack ?? GenesisStarter.find(genesis.starter)?.title { lines.append("- Stack chosen: \(stack)") }
        if let architecture = genesis.architecture, !architecture.isEmpty { lines.append("- Architecture: \(architecture)") }
        if let production = genesis.plannedProduction { lines.append("- Production plan: \(production). Planned only; not deployed unless an environment says otherwise.") }
        return lines
    }
}
