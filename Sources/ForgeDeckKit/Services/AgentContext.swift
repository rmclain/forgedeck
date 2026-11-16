import Foundation

// Context for AI coding agents that work across several repositories.
//
// Three layers, cheapest first:
//   1. Live access. Related checkouts are passed to Claude Code with --add-dir, so the agent
//      reads current files itself when it needs them. Nothing is copied and nothing goes stale.
//   2. A map. One CONTEXT.md per product: a short brief of this product and each related one
//      (stack, components, Git state, top-level tree, and graphify's GRAPH_REPORT.md when a
//      graph already exists in that checkout).
//   3. A compressed pack, built only when the user asks: `repomix --compress`, cached per
//      commit, stored outside every repository. CONTEXT.md points to it; the agent opens it
//      only when it needs code detail.
//
// Everything is written under the ForgeDeck data folder with 0600 files in a 0700 folder.
// No repository is modified. Nothing is sent anywhere by ForgeDeck: the agent decides what to read.

public struct ContextLocation: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }
    public init(store: StoreLocation) { root = store.directory.appending(path: "context", directoryHint: .isDirectory) }

    public func productFolder(_ product: Product) -> URL { root.appending(path: product.slug, directoryHint: .isDirectory) }
    public func contextFile(_ product: Product) -> URL { productFolder(product).appending(path: "CONTEXT.md") }
    public var packsFolder: URL { root.appending(path: "packs", directoryHint: .isDirectory) }
    public func pack(_ checkout: LocalCheckout) -> URL { packsFolder.appending(path: "\(checkout.id.uuidString).md") }
    public func map(_ checkout: LocalCheckout) -> URL { packsFolder.appending(path: "\(checkout.id.uuidString).map.md") }
    public func packInfo(_ checkout: LocalCheckout) -> URL { packsFolder.appending(path: "\(checkout.id.uuidString).json") }

    func prepare(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}

/// What was packed, and from which commit.
public struct PackInfo: Codable, Sendable, Equatable {
    public var checkoutID: UUID
    public var commit: String?
    public var wasDirty: Bool
    public var builtAt: Date
    public var bytes: Int
    public var tool: String
    /// False when the pack was too large to be useful: only the map was kept.
    public var packKept = true

    /// Roughly four characters per token for code.
    public var approxTokens: Int { bytes / 4 }

    /// A pack is current while the checkout is on the same commit with the same clean/dirty state.
    /// Uncommitted edits made after a dirty build are not detectable here: a dirty pack is always stale.
    public func isCurrent(for git: GitSnapshot?) -> Bool {
        guard let git, let head = git.headSHA, let commit else { return false }
        return head == commit && !wasDirty && !git.isDirty
    }
}

public enum PackError: Error, CustomStringConvertible, Equatable {
    case toolMissing
    case folderMissing(String)
    case failed(String)
    case tooLarge(Int)

    public var description: String {
        switch self {
        case .toolMissing: "repomix needs Node.js. Install Node (it brings npx) or `npm install -g repomix`."
        case .folderMissing(let path): "The checkout is not at \(path)."
        case .failed(let why): "repomix failed: \(why)"
        case .tooLarge(let bytes): "The pack was \(bytes / 1_000_000) MB, over the 8 MB limit. Narrow it with a .repomixignore file in the repository."
        }
    }
}

public struct PackBuilder: Sendable {
    /// Pinned, so a new release never runs without a deliberate update.
    public static let repomixVersion = "1.19.0"
    public static let maxBytes = 8_000_000
    /// Never packed, whatever the repository's own ignore files say.
    public static let alwaysIgnored = ["**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/*.p12", "**/*.pfx", "**/id_rsa*", "**/id_ed25519*",
                                       "**/.npmrc", "**/.netrc", "**/wp-config.php", "**/secrets.*", "**/credentials*", "**/graphify-out/**",
                                       // Earlier packs and minified bundles: copies of code, not code.
                                       "**/repomix-output*", "**/repo.xml", "**/*.min.js", "**/*.min.css", "**/*.map"]

    public let runner: any ProcessRunning
    public let location: ContextLocation

    public init(runner: any ProcessRunning = SystemProcessRunner(), location: ContextLocation) {
        self.runner = runner
        self.location = location
    }

    /// The program and arguments, without a shell. `repomix` on the PATH wins over `npx`.
    public static func command(output: URL, repomix: URL?, npx: URL?) -> (URL, [String])? {
        let options = ["--compress", "--style", "markdown", "--output", output.path, "--quiet",
                       "--no-git-sort-by-changes", "--ignore", alwaysIgnored.joined(separator: ",")]
        if let repomix { return (repomix, options) }
        if let npx { return (npx, ["--yes", "repomix@\(repomixVersion)"] + options) }
        return nil
    }

    public func info(_ checkout: LocalCheckout) -> PackInfo? {
        guard let data = FileManager.default.contents(atPath: location.packInfo(checkout).path) else { return nil }
        return try? JSONCoding.decoder().decode(PackInfo.self, from: data)
    }

    /// Builds the pack for one checkout. repomix runs its own secret scan and leaves out files it flags;
    /// the result also passes through ForgeDeck's redactor before it is kept.
    public func build(_ checkout: LocalCheckout, git: GitSnapshot?) async throws -> PackInfo {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: checkout.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PackError.folderMissing(checkout.path)
        }
        try location.prepare(location.packsFolder)
        let output = location.packsFolder.appending(path: "\(checkout.id.uuidString).building.md")
        try? FileManager.default.removeItem(at: output)
        guard let (program, arguments) = Self.command(output: output, repomix: ExecutableLocator.find("repomix"), npx: ExecutableLocator.find("npx")) else {
            throw PackError.toolMissing
        }
        var environment = ProcessInfo.processInfo.environment
        // npx and node live next to each other; a GUI app's PATH often lacks Homebrew.
        environment["PATH"] = ([program.deletingLastPathComponent().path] + ExecutableLocator.searchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        let result = try await runner.run(ProcessRequest(executable: program, arguments: arguments,
                                                         workingDirectory: URL(fileURLWithPath: checkout.path, isDirectory: true),
                                                         environment: environment, timeout: 300, maxOutputBytes: 200_000))
        guard result.ok, let data = FileManager.default.contents(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            let why = result.timedOut ? "it ran longer than 5 minutes" : (result.stderr + result.stdout).split(separator: "\n").last.map(String.init) ?? "exit \(result.exitCode)"
            throw PackError.failed(Redactor().redact(why))
        }
        try? FileManager.default.removeItem(at: output)
        // An oversized pack is of no use to an agent. The ranked map built from it still is.
        let keep = data.count <= Self.maxBytes
        let raw = String(decoding: data, as: UTF8.self)
        let final = location.pack(checkout)
        var keptBytes = data.count
        if keep {
            let text = Redactor().redact(raw)
            keptBytes = text.utf8.count
            try Data(text.utf8).write(to: final, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: final.path)
        } else {
            try? FileManager.default.removeItem(at: final)
        }
        let map = location.map(checkout)
        try Data(Redactor().redact(RepoMap.make(fromPack: raw)).utf8).write(to: map, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: map.path)
        let info = PackInfo(checkoutID: checkout.id, commit: git?.headSHA, wasDirty: git?.isDirty ?? true, builtAt: .now,
                            bytes: keptBytes, tool: "repomix \(Self.repomixVersion) --compress", packKept: keep)
        let infoURL = location.packInfo(checkout)
        try JSONCoding.encoder().encode(info).write(to: infoURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: infoURL.path)
        return info
    }

    public func remove(_ checkout: LocalCheckout) {
        try? FileManager.default.removeItem(at: location.pack(checkout))
        try? FileManager.default.removeItem(at: location.packInfo(checkout))
        try? FileManager.default.removeItem(at: location.map(checkout))
    }
}

/// A ranked outline of a repository that fits a token budget: the files other files depend on
/// most, with their type and function signatures. Built from a repomix compressed pack, so it
/// needs no parser of its own. The same idea as aider's repo map, without tree-sitter.
public enum RepoMap {
    public static let defaultBudgetTokens = 1_500
    static let perFile = 10

    struct File {
        var path: String
        var declarations: [String]
        var names: Set<String>
        var score = 0
    }

    static let declaration = try! NSRegularExpression(pattern:
        #"^\s*(?:@\w+\s+)*(?:(?:public|private|internal|fileprivate|open|export|default|async|static|final|abstract|override|nonisolated|mutating|pub(?:\(crate\))?)\s+)*(class|struct|enum|protocol|extension|actor|interface|trait|impl|type|func|fn|def|function|module|object|record)\b\s*([A-Za-z_][A-Za-z0-9_]*)?"#)

    /// Parses a repomix markdown pack: `## File: <path>` followed by a fenced block.
    static func files(in pack: String) -> [File] {
        var files: [File] = []
        var current: File?
        var inFence = false
        var source = false
        for raw in pack.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("## File: ") {
                if let current { files.append(current) }
                current = File(path: String(line.dropFirst("## File: ".count)), declarations: [], names: [])
                source = isSource(current!.path)
                inFence = false
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("```") { inFence.toggle(); continue }
            // Data files can be megabytes: skip them before any regex runs.
            guard inFence, source, line.utf8.count < 400 else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = declaration.firstMatch(in: line, range: range) else { continue }
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("{") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
            if text.count > 110 { text = String(text.prefix(107)) + "..." }
            current!.declarations.append(text)
            if let nameRange = Range(match.range(at: 2), in: line) {
                let name = String(line[nameRange])
                if name.count >= 4, !genericNames.contains(name.lowercased()) { current!.names.insert(name) }
            }
        }
        if let current { files.append(current) }
        return files.filter { !$0.declarations.isEmpty && isSource($0.path) }
    }

    /// Names too common to say that one file depends on another.
    static let genericNames: Set<String> = ["init", "main", "load", "save", "start", "stop", "step", "update", "render", "draw", "reset",
                                            "get", "set", "run", "test", "setup", "apply", "emit", "handle", "create", "make", "build",
                                            "value", "data", "item", "list", "view", "body", "description", "equals", "hash", "tostring",
                                            "configure", "layout", "close", "open", "read", "write", "parse", "format", "default", "plugin"]

    /// Every identifier in a text, for whole-word matching.
    static func identifiers(_ text: String) -> Set<String> {
        var words = Set<String>()
        let utf8 = text.utf8
        var start: String.UTF8View.Index?
        func isWord(_ byte: UInt8) -> Bool {
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
        }
        var index = utf8.startIndex
        while index < utf8.endIndex {
            let byte = utf8[index]
            if isWord(byte) {
                if start == nil { start = index }
            } else if let begin = start {
                if utf8.distance(from: begin, to: index) >= 4, let word = String(utf8[begin..<index]) { words.insert(word) }
                start = nil
            }
            index = utf8.index(after: index)
        }
        if let begin = start, utf8.distance(from: begin, to: utf8.endIndex) >= 4, let word = String(utf8[begin...]) { words.insert(word) }
        return words
    }

    /// Text and data formats can contain code-looking lines (an old pack, a fixture) but are not source.
    static let nonSource: Set<String> = ["xml", "json", "md", "markdown", "txt", "html", "htm", "csv", "lock", "svg", "yml", "yaml", "toml", "plist", "storyboard", "xib", "log"]

    static func isSource(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        return !nonSource.contains(ext) && !name.hasPrefix("repomix-output") && !name.contains(".min.")
    }

    /// Ranks files by how many other files mention the types they declare, then fills the budget.
    public static func make(fromPack pack: String, budgetTokens: Int = defaultBudgetTokens) -> String {
        var files = files(in: pack)
        guard !files.isEmpty else { return "" }
        let bodies = Dictionary(pack.components(separatedBy: "\n## File: ").dropFirst().compactMap { chunk -> (String, String)? in
            guard let newline = chunk.firstIndex(of: "\n") else { return nil }
            let path = String(chunk[..<newline])
            return isSource(path) ? (path, String(chunk[newline...])) : nil
        }, uniquingKeysWith: { a, _ in a })
        // A name declared in many files says nothing about which one is used.
        var declaredIn: [String: Int] = [:]
        for file in files { for name in file.names { declaredIn[name, default: 0] += 1 } }
        let words = Dictionary(bodies.filter { isSource($0.key) }.map { ($0.key, identifiers($0.value)) }, uniquingKeysWith: { a, _ in a })
        for index in files.indices {
            let names = files[index].names.filter { (declaredIn[$0] ?? 0) <= 2 }
            guard !names.isEmpty else { continue }
            for (path, used) in words where path != files[index].path {
                if !names.isDisjoint(with: used) { files[index].score += 1 }
            }
        }
        files.sort { ($0.score, $0.declarations.count) > ($1.score, $1.declarations.count) }
        var out: [String] = []
        var used = 0
        let budget = budgetTokens * 4
        let typeKeywords = ["class ", "struct ", "enum ", "protocol ", "interface ", "trait ", "actor ", "extension ", "object ", "record "]
        func rank(_ line: String) -> Int {
            if typeKeywords.contains(where: { line.contains($0) }) { return 0 }
            if line.hasPrefix("public ") || line.hasPrefix("export ") || line.hasPrefix("pub ") || line.hasPrefix("open ") { return 1 }
            if line.hasPrefix("private ") || line.hasPrefix("fileprivate ") { return 3 }
            return 2
        }
        for file in files {
            let header = "\(file.path)\(file.score > 0 ? "  (used by \(file.score))" : "")"
            guard used + header.count + 8 < budget else { break }
            out.append(header + (file.declarations.count > perFile ? "  [\(file.declarations.count - perFile) more]" : ""))
            used += header.count + 1
            // The ten most telling lines per file, in file order: types first, then public API.
            let picked = Set(file.declarations.indices.sorted { (rank(file.declarations[$0]), $0) < (rank(file.declarations[$1]), $1) }.prefix(perFile))
            let shownLines = file.declarations.indices.filter(picked.contains).map { file.declarations[$0] }
            for line in shownLines {
                guard used + line.count + 3 < budget else { break }
                out.append("  " + line)
                used += line.count + 3
            }
        }
        let shown = Set(out.filter { !$0.hasPrefix("  ") }.map { $0.components(separatedBy: "  ").first ?? $0 })
        let left = files.count - shown.count
        if left > 0 { out.append("… \(left) more files with declarations: see the full pack") }
        return out.joined(separator: "\n")
    }
}

public enum RepoBrief {
    public static let maxGraphReportBytes = 16_000
    /// Only the summary and the community list go into CONTEXT.md. The agent queries the graph for the rest.
    public static let maxGraphSummaryLines = 36

    /// The top two levels of a checkout, without dependency or build folders. Names only.
    public static func tree(_ path: String, maxEntries: Int = 80) -> [String] {
        let fm = FileManager.default
        var lines: [String] = []
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { !ProjectDiscovery.skipped.contains($0.lastPathComponent) && !ProjectDiscovery.isSecretBearing($0.lastPathComponent) && $0.lastPathComponent != "graphify-out" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for child in children(URL(fileURLWithPath: path, isDirectory: true)) {
            guard lines.count < maxEntries else { lines.append("…"); break }
            if isDirectory(child) {
                let inner = children(child)
                lines.append("\(child.lastPathComponent)/" + (inner.isEmpty ? "" : "  (\(inner.count) entries)"))
                for grandchild in inner.prefix(8) where lines.count < maxEntries {
                    lines.append("  \(grandchild.lastPathComponent)\(isDirectory(grandchild) ? "/" : "")")
                }
                if inner.count > 8 { lines.append("  …") }
            } else {
                lines.append(child.lastPathComponent)
            }
        }
        return lines
    }

    /// graphify's report, when that checkout already has a graph. ForgeDeck never builds one.
    public static func graphReport(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).appending(path: "graphify-out/GRAPH_REPORT.md")
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: maxGraphReportBytes) else { return nil }
        try? handle.close()
        var lines: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            // Stop at the first section after the summary and the community hubs.
            if line.hasPrefix("## "), !["## Corpus Check", "## Summary", "## Community Hubs (Navigation)"].contains(line) { break }
            if line.hasPrefix("# ") { continue }
            lines.append(line)
            if lines.count >= maxGraphSummaryLines { lines.append("…"); break }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : Redactor().redact(text)
    }

    public static func graphExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appending(path: "graphify-out/graph.json").path)
    }

    static func home(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// A short Markdown brief for one product: what it is, where its code is, and how to read more.
    public static func make(_ product: Product, cache: ObservationCache, packs: PackBuilder?, includePack: Bool, isPrimary: Bool) -> String {
        var lines = ["## \(product.name)\(isPrimary ? " (this product)" : "")", ""]
        var mapText: String?
        if !product.tagline.isEmpty { lines += [product.tagline, ""] }
        var facts: [String] = []
        if !product.stack.isEmpty { facts.append("Stack: \(product.stack.joined(separator: ", "))") }
        facts.append("Lifecycle: \(product.lifecycle.title)")
        if !product.components.isEmpty { facts.append("Components: " + product.components.map { "\($0.name) (\($0.kind.title))" }.joined(separator: ", ")) }
        if !product.repositories.isEmpty { facts.append("Repositories: " + product.repositories.map(\.fullName).joined(separator: ", ")) }
        let environments = product.environments.filter { !$0.domains.isEmpty }
        if !environments.isEmpty { facts.append("Environments: " + environments.map { "\($0.name) \($0.domains.joined(separator: ", "))" }.joined(separator: "; ")) }
        lines += facts.map { "- \($0)" }
        for checkout in product.checkouts where !product.isDemo {
            let git = cache.git[checkout.id]
            lines += ["", "### Checkout \(checkout.name)", "",
                      "- Path: `\(home(checkout.path))`" + (isPrimary ? " (the agent's working directory)" : " (readable: added to the agent's allowed folders)"),
                      "- Git: \(git?.summary ?? "not inspected")" + (git?.headSHA.map { " at \(shortSHA($0))" } ?? "")]
            if let pack = packs, includePack {
                let packURL = pack.location.pack(checkout)
                if let info = pack.info(checkout), info.packKept || FileManager.default.fileExists(atPath: pack.location.map(checkout).path) {
                    let state = info.isCurrent(for: git) ? "current" : "STALE: built from \(shortSHA(info.commit))\(info.wasDirty ? " with uncommitted changes" : ""), the checkout has moved on"
                    if !info.packKept {
                        lines.append("- Compressed code pack: not kept (\(info.bytes / 1_000_000) MB is too large to be useful; \(state)). Use the map below and read files directly.")
                    } else {
                    lines.append("- Compressed code pack: `\(home(packURL.path))` (~\(max(1, info.approxTokens / 1_000))k tokens, \(state)). Signatures and structure, bodies removed. Prefer the map below and the real files; open the pack only to survey the whole repository.")
                    }
                    if let map = try? String(contentsOf: pack.location.map(checkout), encoding: .utf8), !map.isEmpty {
                        mapText = map
                    }
                } else {
                    lines.append("- Compressed code pack: not built yet.")
                }
            }
            if graphExists(checkout.path) {
                lines.append("- Knowledge graph: `\(home(checkout.path))/graphify-out/graph.json`. Ask it with `graphify query \"<question>\" --graph \(home(checkout.path))/graphify-out/graph.json`.")
            }
            if let map = mapText {
                lines += ["", "Repo map (most-used files first, about \(RepoMap.defaultBudgetTokens) tokens):", "", "```", map, "```"]
                mapText = nil
            } else if !isPrimary {
                let tree = tree(checkout.path)
                if !tree.isEmpty { lines += ["", "Top of the tree:", "", "```"] + tree + ["```"] }
            }
            if !isPrimary, let report = graphReport(checkout.path) {
                lines += ["", "graphify summary for \(checkout.name):", "", report]
            }
        }
        if product.checkouts.isEmpty, !product.isDemo {
            lines += ["", "No local checkout. Read it on GitHub: " + (product.repositories.first?.webURL ?? "no repository linked") + "."]
        }
        return lines.joined(separator: "\n")
    }
}

/// The context file for one product, and the folders the agent may read.
public struct AgentContextBundle: Sendable, Equatable {
    public var contextFile: URL
    public var workingDirectory: String
    /// Folders to pass with --add-dir: the context folder, the pack folder, and related checkouts.
    public var readableFolders: [String]
    public var relatedNames: [String]
    public var approxTokens: Int

    public static func write(for product: Product, checkout: LocalCheckout? = nil, portfolio: Portfolio, cache: ObservationCache,
                             location: ContextLocation, now: Date = .now) throws -> AgentContextBundle {
        let packs = PackBuilder(location: location)
        let primary = checkout ?? product.primaryCheckout
        var sections = [RepoBrief.make(product, cache: cache, packs: packs, includePack: false, isPrimary: true)]
        var folders: [String] = []
        var names: [String] = []
        for link in product.contextLinks {
            guard let related = portfolio.product(id: link.productID), related.id != product.id else { continue }
            names.append(related.name)
            var section = RepoBrief.make(related, cache: cache, packs: packs, includePack: link.includePack, isPrimary: false)
            if !link.note.isEmpty { section += "\n\nWhy it matters here: \(link.note)" }
            sections.append(section)
            if !related.isDemo { folders += related.checkouts.map(\.path).filter { FileManager.default.fileExists(atPath: $0) } }
        }
        let header = """
        # Context for \(product.name)

        Written by \(Brand.name) \(ISO8601DateFormatter().string(from: now)). It holds names, paths, and structure only: no secrets, no customer data.
        \(names.isEmpty ? "No related products are linked." : "Related products: \(names.joined(separator: ", ")). Their checkouts are readable, so read the real files when you need them; the briefs below are a map, not the source.")
        Use a compressed pack only when you need code detail across a whole repository. Do not change files in a related repository unless asked.
        """
        let hints = Toolbox.agentHints()
        let tools = hints.isEmpty ? [] : ["## Tools on this Mac\n\nCheaper than reading whole files:\n\n" + hints.map { "- \($0)" }.joined(separator: "\n")]
        let text = Redactor().redact(([header] + sections + tools).joined(separator: "\n\n---\n\n")) + "\n"
        let folder = location.productFolder(product)
        try location.prepare(folder)
        let file = location.contextFile(product)
        try Data(text.utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let packFolderUsed = product.contextLinks.contains(where: \.includePack) && FileManager.default.fileExists(atPath: location.packsFolder.path)
        var readable = [folder.path] + (packFolderUsed ? [location.packsFolder.path] : []) + folders
        var seen = Set<String>()
        readable = readable.filter { $0 != primary?.path && seen.insert($0).inserted }
        return AgentContextBundle(contextFile: file, workingDirectory: primary?.path ?? NSHomeDirectory(), readableFolders: readable,
                                  relatedNames: names, approxTokens: text.utf8.count / 4)
    }

    /// One line for the agent's system prompt. The file holds the rest.
    public var pointer: String {
        "\(Brand.name) wrote a context file for this session at \(contextFile.path). Read it before working across repositories."
            + (relatedNames.isEmpty ? "" : " Related repositories you may read: \(relatedNames.joined(separator: ", ")).")
    }

    /// The agent's command line, as an argument array. Claude Code gets the folders with --add-dir and the
    /// pointer with --append-system-prompt. Codex and OpenCode get the pointer as their first prompt.
    public func command(program: URL, model: String? = nil) -> [String] {
        AgentCatalog.command(program: program, folders: readableFolders, pointer: pointer, message: nil, model: model, workingDirectory: workingDirectory)
    }
}
