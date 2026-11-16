import Foundation

// Install links: a symlink from a folder in a checkout into a place that loads it, like a
// local WordPress site's wp-content/plugins. Edit in the repository, reload the site.
//
// Rules:
// - A symlink, never a Finder alias: PHP and most tools do not follow aliases.
// - Never overwrite. If something real is at the destination, the link is not made. Moving a
//   real copy aside is a separate, explicit action, and the copy is kept, not deleted.
// - Removing a link deletes only a symlink that points at this checkout. It never follows it.
// - Local folders only. Nothing here touches a remote server.

public enum InstallLinkKind: String, Codable, CaseIterable, Sendable {
    case wordpressPlugin, wordpressTheme, folder

    public var title: String {
        switch self {
        case .wordpressPlugin: "WordPress plugin"
        case .wordpressTheme: "WordPress theme"
        case .folder: "Folder"
        }
    }
}

public struct InstallLink: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var checkoutID: UUID?
    /// A folder inside the checkout to link, like "build" or "plugins/my-plugin". Empty links the checkout itself.
    public var sourceSubpath = ""
    /// The folder the link is created in, like ~/Local Sites/x/app/public/wp-content/plugins.
    public var destinationFolder = ""
    /// The link's own name in that folder. For a WordPress plugin, the plugin's folder slug.
    public var linkName = ""
    public var kind: InstallLinkKind = .folder
    /// A readable name for the destination, like a Local site's name.
    public var siteName = ""
    public init() {}

    public var linkPath: String { (destinationFolder as NSString).appendingPathComponent(linkName) }
}

/// A WordPress install found on this Mac. Found by its folders: wp-config.php is never read.
public struct WordPressSite: Sendable, Hashable, Identifiable {
    public var id: String { root }
    public var name: String
    public var root: String
    public var pluginsFolder: String { (root as NSString).appendingPathComponent("wp-content/plugins") }
    public var themesFolder: String { (root as NSString).appendingPathComponent("wp-content/themes") }
    /// Where moved-aside copies go: inside wp-content, outside plugins and themes, so WordPress never loads them.
    public var backupFolder: String { (root as NSString).appendingPathComponent("wp-content/forgedeck-backups") }
}

/// What WordPress reads from a plugin or theme header.
public struct WordPressPackage: Sendable, Equatable {
    public var kind: InstallLinkKind
    public var name: String
    public var version: String?
}

public enum InstallLinkState: Sendable, Equatable {
    /// The symlink exists and points at the source.
    case linked
    /// Nothing at the destination yet.
    case notLinked
    /// A symlink is there, but its target is gone.
    case broken(target: String)
    /// A symlink is there and points somewhere else.
    case pointsElsewhere(target: String)
    /// A real folder or file is in the way. Usually an old copy.
    case blockedByCopy(version: String?)
    /// The destination folder itself is missing (site deleted or moved).
    case destinationMissing
    /// The folder in the checkout is missing.
    case sourceMissing

    public var title: String {
        switch self {
        case .linked: "Linked"
        case .notLinked: "Not linked"
        case .broken: "Broken link"
        case .pointsElsewhere: "Points elsewhere"
        case .blockedByCopy: "A copy is in the way"
        case .destinationMissing: "Destination missing"
        case .sourceMissing: "Source missing"
        }
    }

    public var tone: Tone {
        switch self {
        case .linked: .ok
        case .notLinked: .muted
        case .broken, .destinationMissing, .sourceMissing: .err
        case .pointsElsewhere, .blockedByCopy: .warn
        }
    }
}

public enum InstallLinkError: Error, CustomStringConvertible, Equatable {
    case sourceMissing(String)
    case destinationMissing(String)
    case occupied(String)
    case notOurLink(String)
    case invalidName
    case notACopy

    public var description: String {
        switch self {
        case .sourceMissing(let path): "The folder to link is not there: \(path)."
        case .destinationMissing(let path): "The destination folder is not there: \(path)."
        case .occupied(let path): "Something is already at \(path). Nothing was changed."
        case .notOurLink(let path): "\(path) is not a link to this checkout. It was left alone."
        case .invalidName: "Use a plain folder name: letters, digits, dots, dashes, underscores."
        case .notACopy: "There is no real folder to move aside."
        }
    }
}

public enum InstallLinks {
    // MARK: Finding WordPress

    /// Folders that usually hold local sites: Local's "Local Sites", ~/Sites, and any extra roots.
    public static func defaultSearchRoots(extra: [String] = []) -> [String] {
        let home = NSHomeDirectory()
        return ["\(home)/Local Sites", "\(home)/Sites", "\(home)/Studio"] + extra
    }

    public static func isWordPressRoot(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: (path as NSString).appendingPathComponent("wp-content/plugins"), isDirectory: &isDirectory) && isDirectory.boolValue
            && fm.fileExists(atPath: (path as NSString).appendingPathComponent("wp-includes"))
    }

    /// Finds WordPress installs up to three levels under each root. Local's layout is <site>/app/public.
    public static func findWordPressSites(roots: [String]) -> [WordPressSite] {
        let fm = FileManager.default
        var sites: [WordPressSite] = []
        var seen = Set<String>()
        func visit(_ path: String, depth: Int, siteName: String?) {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(real).inserted else { return }
            if isWordPressRoot(path) {
                sites.append(WordPressSite(name: siteName ?? (path as NSString).lastPathComponent, root: path))
                return
            }
            guard depth < 3, let children = try? fm.contentsOfDirectory(atPath: path) else { return }
            for child in children.sorted() where !child.hasPrefix(".") && !ProjectDiscovery.skipped.contains(child) {
                let full = (path as NSString).appendingPathComponent(child)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                visit(full, depth: depth + 1, siteName: siteName ?? child)
            }
        }
        for root in roots where fm.fileExists(atPath: root) {
            // The roots themselves are containers, not sites.
            for child in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where !child.hasPrefix(".") {
                visit((root as NSString).appendingPathComponent(child), depth: 0, siteName: child)
            }
        }
        return sites
    }

    // MARK: Reading a package

    /// Reads the plugin header from top-level PHP files, or a theme's style.css header. Never wp-config.php.
    public static func package(at path: String) -> WordPressPackage? {
        let fm = FileManager.default
        func header(_ file: String) -> [String: String] {
            guard !ProjectDiscovery.isSecretBearing((file as NSString).lastPathComponent),
                  let handle = FileHandle(forReadingAtPath: file), let data = try? handle.read(upToCount: 8_192) else { return [:] }
            try? handle.close()
            var fields: [String: String] = [:]
            // WordPress matches "Key:" anywhere on a line, like `<?php /* Plugin Name: X`.
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) {
                for key in ["plugin name", "theme name", "version"] where fields[key] == nil {
                    guard let range = line.range(of: key + ":", options: .caseInsensitive) else { continue }
                    let before = line[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \t*#/@<?php"))
                    guard before.isEmpty else { continue }
                    var value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if let end = value.range(of: "*/") { value = String(value[..<end.lowerBound]).trimmingCharacters(in: .whitespaces) }
                    if !value.isEmpty { fields[key] = value }
                }
            }
            return fields
        }
        let style = (path as NSString).appendingPathComponent("style.css")
        if fm.fileExists(atPath: style), let name = header(style)["theme name"] {
            return WordPressPackage(kind: .wordpressTheme, name: name, version: header(style)["version"])
        }
        for file in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted() where file.hasSuffix(".php") {
            let fields = header((path as NSString).appendingPathComponent(file))
            if let name = fields["plugin name"] { return WordPressPackage(kind: .wordpressPlugin, name: name, version: fields["version"]) }
        }
        return nil
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("-"), name.count <= 128 else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._- ".unicodeScalars.contains($0) }
    }

    // MARK: State

    public static func source(of link: InstallLink, checkout: LocalCheckout) -> String {
        link.sourceSubpath.isEmpty ? checkout.path : (checkout.path as NSString).appendingPathComponent(link.sourceSubpath)
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func state(of link: InstallLink, checkout: LocalCheckout) -> InstallLinkState {
        let fm = FileManager.default
        let source = source(of: link, checkout: checkout)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: link.destinationFolder, isDirectory: &isDirectory), isDirectory.boolValue else { return .destinationMissing }
        guard fm.fileExists(atPath: source, isDirectory: &isDirectory), isDirectory.boolValue else { return .sourceMissing }
        let path = link.linkPath
        if let target = try? fm.destinationOfSymbolicLink(atPath: path) {
            let absolute = target.hasPrefix("/") ? target : (link.destinationFolder as NSString).appendingPathComponent(target)
            guard fm.fileExists(atPath: absolute) else { return .broken(target: absolute) }
            return standardized(absolute) == standardized(source) ? .linked : .pointsElsewhere(target: absolute)
        }
        if (try? fm.attributesOfItem(atPath: path)) != nil {
            return .blockedByCopy(version: package(at: path)?.version)
        }
        return .notLinked
    }

    // MARK: Changes

    /// Creates the symlink. Refuses when anything is at the destination.
    public static func create(_ link: InstallLink, checkout: LocalCheckout) throws {
        guard isValidName(link.linkName) else { throw InstallLinkError.invalidName }
        let fm = FileManager.default
        let source = source(of: link, checkout: checkout)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source, isDirectory: &isDirectory), isDirectory.boolValue else { throw InstallLinkError.sourceMissing(source) }
        guard fm.fileExists(atPath: link.destinationFolder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InstallLinkError.destinationMissing(link.destinationFolder)
        }
        switch state(of: link, checkout: checkout) {
        case .linked: return
        case .notLinked: break
        default: throw InstallLinkError.occupied(link.linkPath)
        }
        // An absolute target keeps working if the site folder is moved within the disk.
        try fm.createSymbolicLink(atPath: link.linkPath, withDestinationPath: standardized(source))
    }

    /// Removes the symlink, only when it points at this checkout (or at nothing, for a broken link to it).
    public static func remove(_ link: InstallLink, checkout: LocalCheckout) throws {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: link.linkPath) else {
            if (try? fm.attributesOfItem(atPath: link.linkPath)) == nil { return }
            throw InstallLinkError.notOurLink(link.linkPath)
        }
        let absolute = target.hasPrefix("/") ? target : (link.destinationFolder as NSString).appendingPathComponent(target)
        let source = source(of: link, checkout: checkout)
        let ours = standardized(absolute) == standardized(source)
            || URL(fileURLWithPath: absolute).standardizedFileURL.path == URL(fileURLWithPath: source).standardizedFileURL.path
        guard ours else { throw InstallLinkError.notOurLink(link.linkPath) }
        // removeItem on a symlink removes the link, never what it points at.
        try fm.removeItem(atPath: link.linkPath)
    }

    /// Moves a real copy out of the way into a backup folder, then links. Returns where the copy went.
    @discardableResult
    public static func moveAsideAndLink(_ link: InstallLink, checkout: LocalCheckout, backupFolder: String, now: Date = .now) throws -> String {
        guard case .blockedByCopy = state(of: link, checkout: checkout) else { throw InstallLinkError.notACopy }
        let fm = FileManager.default
        try fm.createDirectory(atPath: backupFolder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let backup = (backupFolder as NSString).appendingPathComponent("\(link.linkName)-\(stamp)")
        guard !fm.fileExists(atPath: backup) else { throw InstallLinkError.occupied(backup) }
        try fm.moveItem(atPath: link.linkPath, toPath: backup)
        do {
            try create(link, checkout: checkout)
        } catch {
            // Put the copy back so the site is exactly as it was.
            try? fm.moveItem(atPath: backup, toPath: link.linkPath)
            throw error
        }
        return backup
    }

    /// The backup folder for a destination: next to wp-content's plugins and themes, or beside any other folder.
    public static func backupFolder(for destination: String) -> String {
        let parent = (destination as NSString).deletingLastPathComponent
        let name = (parent as NSString).lastPathComponent == "wp-content" ? "forgedeck-backups" : ".forgedeck-backups"
        return (parent as NSString).appendingPathComponent(name)
    }

    // MARK: Suggestions

    public struct Suggestion: Sendable, Hashable, Identifiable {
        public var id: String { link.linkPath }
        public var link: InstallLink
        public var site: WordPressSite
        /// True when a real copy with this name is already in the site.
        public var hasCopy: Bool
        public var copyVersion: String?
    }

    /// For a checkout that is a WordPress plugin or theme: where it could be linked. Sites that already
    /// hold a copy with the same folder name come first.
    public static func suggestions(for checkout: LocalCheckout, subpath: String = "", existing: [InstallLink], sites: [WordPressSite]) -> [Suggestion] {
        let source = subpath.isEmpty ? checkout.path : (checkout.path as NSString).appendingPathComponent(subpath)
        guard let package = package(at: source) else { return [] }
        let name = (source as NSString).lastPathComponent
        let taken = Set(existing.map(\.linkPath))
        return sites.compactMap { site -> Suggestion? in
            var link = InstallLink()
            link.checkoutID = checkout.id
            link.sourceSubpath = subpath
            link.kind = package.kind
            link.destinationFolder = package.kind == .wordpressTheme ? site.themesFolder : site.pluginsFolder
            link.linkName = name
            link.siteName = site.name
            guard !taken.contains(link.linkPath) else { return nil }
            let state = state(of: link, checkout: checkout)
            if case .linked = state { return nil }
            var copyVersion: String?
            var hasCopy = false
            if case .blockedByCopy(let version) = state { hasCopy = true; copyVersion = version }
            return Suggestion(link: link, site: site, hasCopy: hasCopy, copyVersion: copyVersion)
        }
        .sorted { ($0.hasCopy ? 0 : 1, $0.site.name) < ($1.hasCopy ? 0 : 1, $1.site.name) }
    }

    /// Symlinks already in a site that point into a checkout: links made by hand, to adopt.
    public static func existingLinks(into checkout: LocalCheckout, sites: [WordPressSite]) -> [InstallLink] {
        let fm = FileManager.default
        let root = standardized(checkout.path)
        var found: [InstallLink] = []
        for site in sites {
            for (folder, kind) in [(site.pluginsFolder, InstallLinkKind.wordpressPlugin), (site.themesFolder, .wordpressTheme)] {
                for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                    let path = (folder as NSString).appendingPathComponent(name)
                    guard let target = try? fm.destinationOfSymbolicLink(atPath: path) else { continue }
                    let absolute = standardized(target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target))
                    guard absolute == root || absolute.hasPrefix(root + "/") else { continue }
                    var link = InstallLink()
                    link.checkoutID = checkout.id
                    link.sourceSubpath = absolute == root ? "" : String(absolute.dropFirst(root.count + 1))
                    link.destinationFolder = folder
                    link.linkName = name
                    link.kind = kind
                    link.siteName = site.name
                    found.append(link)
                }
            }
        }
        return found
    }
}
