import Foundation

// Which version is out. Two sources:
// - A site that serves its own release marker (forgedeck-release.json, a version file, or an
//   X-Release header). Read by the "Version URL" check: runtime evidence, no companion needed.
// - A package registry for things that ship instead of run: a WordPress plugin, an npm or PyPI
//   package. Reported evidence: the registry says what it publishes; nothing runs it.
// Registry lookups are opt-in per product. A detected package is only a suggestion, because a
// private package can share a name with an unrelated public one.

// MARK: Release marker

public enum ReleaseMarker {
    public struct Found: Equatable, Sendable {
        public var sha: String?
        public var version: String?
        public var deployedAt: Date?
    }

    static let shaKeys = ["commit_sha", "commitSha", "git_sha", "gitSha", "git_commit", "gitCommit", "sha", "commit", "revision"]
    static let versionKeys = ["version", "app_version", "appVersion", "tag", "release"]
    static let dateKeys = ["deployed_at", "deployedAt", "built_at", "builtAt", "build_time", "buildTime"]
    static let shaHeaders = ["x-commit-sha", "x-git-commit", "x-git-sha", "x-commit", "x-revision"]
    static let versionHeaders = ["x-release", "x-version", "x-app-version"]

    /// Reads a release file body (JSON or one plain line) and the response headers. The body wins.
    public static func read(body: Data, headers: [String: String]) -> Found {
        var found = Found()
        if let object = try? JSONSerialization.jsonObject(with: body.prefix(256_000)) as? [String: Any] {
            // Flat files, the companion's nested "release", and common "build"/"git" blocks.
            let blocks = [object] + ["release", "build", "git"].compactMap { object[$0] as? [String: Any] }
            for block in blocks {
                if found.sha == nil { found.sha = shaKeys.lazy.compactMap { block[$0] as? String }.compactMap(sha).first }
                if found.version == nil { found.version = versionKeys.lazy.compactMap { block[$0] as? String }.compactMap(version).first }
                if found.deployedAt == nil { found.deployedAt = dateKeys.lazy.compactMap { FlexibleDate.parse(block[$0] as? String) }.first }
            }
        } else if body.count <= 200, let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !text.contains(where: \.isWhitespace), !text.hasPrefix("<") {
            if let value = sha(text), !text.contains(".") { found.sha = value } else { found.version = version(text) }
        }
        if found.sha == nil { found.sha = shaHeaders.lazy.compactMap { headers[$0] }.compactMap(sha).first }
        if found.version == nil {
            for value in versionHeaders.compactMap({ headers[$0] }) {
                // Some hosts put the commit in X-Release.
                if let commit = sha(value), !value.contains("."), found.sha == nil { found.sha = commit } else if let v = version(value) { found.version = v; break }
            }
        }
        return found
    }

    static func sha(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        return (7...40).contains(value.count) && value.allSatisfy(\.isHexDigit) ? value.lowercased() : nil
    }

    /// A version as text: short, printable, no spaces. Anything else is dropped rather than shown.
    static func version(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-+_"))
        guard (1...64).contains(value.count), value.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }),
              value.contains(where: \.isNumber) else { return nil }
        return value
    }
}

// MARK: Channels

/// A registry a product publishes to. Saved on the product; the person adds it.
public struct ReleaseChannel: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case wordpressOrg, npm, pypi

        public var title: String {
            switch self {
            case .wordpressOrg: "WordPress.org"
            case .npm: "npm"
            case .pypi: "PyPI"
            }
        }

        /// The kind of name the registry uses.
        public var packageLabel: String { self == .wordpressOrg ? "Plugin slug" : "Package name" }

        /// Which version in the code this registry should match.
        var codeSource: LocalRelease.Source {
            switch self {
            case .wordpressOrg: .pluginHeader
            case .npm: .packageJSON
            case .pypi: .pyproject
            }
        }
    }

    public var id = UUID()
    public var kind: Kind = .wordpressOrg
    public var package = ""
    public init() {}
    public init(kind: Kind, package: String) { self.kind = kind; self.package = package }

    /// The registry's public page for the package.
    public var pageURL: String {
        switch kind {
        case .wordpressOrg: "https://wordpress.org/plugins/\(package)/"
        case .npm: "https://www.npmjs.com/package/\(package)"
        case .pypi: "https://pypi.org/project/\(package)/"
        }
    }

    /// The read-only API request for the newest published version.
    var apiURL: String? {
        guard Self.isValidName(package, kind: kind) else { return nil }
        switch kind {
        case .wordpressOrg:
            return "https://api.wordpress.org/plugins/info/1.2/?action=plugin_information&request%5Bslug%5D=\(package)&request%5Bfields%5D%5Bsections%5D=0"
        case .npm:
            return "https://registry.npmjs.org/\(package.replacingOccurrences(of: "/", with: "%2F"))/latest"
        case .pypi:
            return "https://pypi.org/pypi/\(package)/json"
        }
    }

    public static func isValidName(_ name: String, kind: Kind) -> Bool {
        guard (1...214).contains(name.count), name.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        let base = CharacterSet.lowercaseLetters.union(.uppercaseLetters).union(.decimalDigits).union(CharacterSet(charactersIn: "-_."))
        switch kind {
        case .wordpressOrg:
            return name.unicodeScalars.allSatisfy { base.contains($0) && !CharacterSet.uppercaseLetters.contains($0) } && !name.hasPrefix(".")
        case .pypi:
            return name.unicodeScalars.allSatisfy(base.contains) && !name.hasPrefix(".")
        case .npm:
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 2 {
                guard parts[0].hasPrefix("@"), parts[0].count > 1 else { return false }
                return parts[0].dropFirst().unicodeScalars.allSatisfy(base.contains) && parts[1].unicodeScalars.allSatisfy(base.contains) && !parts[1].isEmpty
            }
            return parts.count == 1 && name.unicodeScalars.allSatisfy(base.contains) && !name.hasPrefix(".") && !name.hasPrefix("_")
        }
    }
}

/// What a registry reported for one channel.
public struct ReleaseObservation: Codable, Hashable, Sendable {
    public var channelID = UUID()
    public var productID = UUID()
    public var version: String?
    public var releasedAt: Date?
    public var problem: ObservationProblem?
    public var detail = ""
    public var provenance = Provenance(source: .packageRegistry, level: .unknown)
    public init() {}
}

// MARK: The code

/// The versions a checkout declares, read from its files. Nothing runs.
public struct LocalRelease: Equatable, Sendable {
    public enum Source: String, Sendable { case pluginHeader, readmeStableTag, packageJSON, pyproject }

    public struct Fact: Equatable, Sendable, Identifiable {
        public var id: String { source.rawValue }
        public var source: Source
        public var file: String
        public var version: String

        public init(source: Source, file: String, version: String) {
            self.source = source
            self.file = file
            self.version = version
        }

        public var label: String {
            switch source {
            case .pluginHeader: "Plugin header"
            case .readmeStableTag: "readme.txt Stable tag"
            case .packageJSON: "package.json"
            case .pyproject: "pyproject.toml"
            }
        }
    }

    public var facts: [Fact] = []
    /// Channels the files suggest. Shown as suggestions; never looked up until added.
    public var suggestions: [ReleaseChannel] = []
    public init() {}

    public func fact(_ source: Source) -> Fact? { facts.first { $0.source == source } }
    /// The version to compare a GitHub release against: the most specific one found.
    public var primary: Fact? { fact(.pluginHeader) ?? fact(.packageJSON) ?? fact(.pyproject) }

    public static func detect(in path: String) -> LocalRelease {
        var result = LocalRelease()
        let root = URL(fileURLWithPath: path)
        let fm = FileManager.default
        // A WordPress plugin: a PHP file in the root with a Plugin Name header.
        let php = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasSuffix(".php") }.sorted().prefix(40)
        for name in php {
            guard let head = Self.head(root.appending(path: name)), let headers = Optional(Self.pluginHeaders(head)), headers["plugin name"] != nil else { continue }
            if let version = headers["version"].flatMap(ReleaseMarker.version) {
                result.facts.append(Fact(source: .pluginHeader, file: name, version: version))
            }
            let slug = headers["text domain"].flatMap { ReleaseChannel.isValidName($0, kind: .wordpressOrg) ? $0 : nil }
                ?? Slug.make(root.lastPathComponent)
            if ReleaseChannel.isValidName(slug, kind: .wordpressOrg) { result.suggestions.append(ReleaseChannel(kind: .wordpressOrg, package: slug)) }
            if let readme = Self.head(root.appending(path: "readme.txt")),
               let stable = Self.pluginHeaders(readme)["stable tag"].flatMap(ReleaseMarker.version) {
                result.facts.append(Fact(source: .readmeStableTag, file: "readme.txt", version: stable))
            }
            break
        }
        if let data = try? Data(contentsOf: root.appending(path: "package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let version = (json["version"] as? String).flatMap(ReleaseMarker.version) {
                result.facts.append(Fact(source: .packageJSON, file: "package.json", version: version))
            }
            if (json["private"] as? Bool) != true, let name = json["name"] as? String, ReleaseChannel.isValidName(name, kind: .npm) {
                result.suggestions.append(ReleaseChannel(kind: .npm, package: name))
            }
        }
        if let text = try? String(contentsOf: root.appending(path: "pyproject.toml"), encoding: .utf8) {
            let project = Self.tomlTable(text, names: ["project", "tool.poetry"])
            if let version = project["version"].flatMap(ReleaseMarker.version) {
                result.facts.append(Fact(source: .pyproject, file: "pyproject.toml", version: version))
            }
            if let name = project["name"], ReleaseChannel.isValidName(name, kind: .pypi) {
                result.suggestions.append(ReleaseChannel(kind: .pypi, package: name))
            }
        }
        return result
    }

    static func head(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8_192)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// "Key: value" lines, as in a plugin header or readme.txt. Keys lowercased.
    static func pluginHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "*#/".contains(first) { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard (2...30).contains(key.count), !value.isEmpty, headers[key] == nil else { continue }
            headers[key] = value
        }
        return headers
    }

    /// String values from the first matching TOML table. Enough for name and version.
    static func tomlTable(_ text: String, names: [String]) -> [String: String] {
        var current = "", values: [String: [String: String]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { current = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")); continue }
            guard names.contains(current), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") else { continue }
            value = String(value[value.index(after: value.startIndex)..<end])
            values[current, default: [:]][key] = value
        }
        return names.lazy.compactMap { values[$0] }.first ?? [:]
    }
}

// MARK: Registry lookups

public struct ReleaseRegistryConnector: Sendable {
    public let http: any HTTPClient
    public let ttl: TimeInterval

    public init(http: any HTTPClient = URLSessionHTTPClient(timeout: 10), ttl: TimeInterval = 3_600) {
        self.http = http
        self.ttl = ttl
    }

    public func latest(_ channel: ReleaseChannel, productID: UUID) async -> ReleaseObservation {
        let started = Date.now
        var observation = ReleaseObservation()
        observation.channelID = channel.id
        observation.productID = productID
        func fail(_ problem: ObservationProblem, _ detail: String) -> ReleaseObservation {
            observation.problem = problem
            observation.detail = detail
            observation.provenance = Provenance(observedAt: started, source: .packageRegistry, level: .unknown, ttl: ttl)
            return observation
        }
        guard let address = channel.apiURL, let url = try? URLPolicy.validate(address) else {
            return fail(.notConfigured, "\"\(channel.package)\" is not a valid \(channel.kind.title) name.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Brand.name, forHTTPHeaderField: "User-Agent")
        let response: HTTPResponse
        do { response = try await http.send(request) } catch {
            let (problem, detail) = HTTPFailure.problem(for: error)
            return fail(problem, detail)
        }
        if response.status == 404 { return fail(.notFound, "\(channel.kind.title) has no \(channel.package).") }
        if let (problem, detail, _) = HTTPFailure.problem(status: response.status, headers: response.headers) { return fail(problem, detail) }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return fail(.malformed, "\(channel.kind.title) answered with something other than JSON.")
        }
        // WordPress.org answers 200 with an error field for an unknown slug.
        if json["error"] != nil { return fail(.notFound, "\(channel.kind.title) has no \(channel.package).") }
        let info = channel.kind == .pypi ? (json["info"] as? [String: Any] ?? [:]) : json
        guard let version = (info["version"] as? String).flatMap(ReleaseMarker.version) else {
            return fail(.malformed, "\(channel.kind.title) did not report a version.")
        }
        observation.version = version
        if channel.kind == .wordpressOrg, let updated = json["last_updated"] as? String { observation.releasedAt = Self.wordpressDate(updated) }
        observation.detail = "\(channel.kind.title) publishes \(version)"
        observation.provenance = Provenance(observedAt: started, source: .packageRegistry, level: .reported, ttl: ttl)
        return observation
    }

    /// WordPress.org writes "2024-05-01 3:12pm GMT".
    static func wordpressDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd h:mma 'GMT'"
        return formatter.date(from: text.uppercased())
    }
}

// MARK: Comparison

public struct ReleaseFinding: Equatable, Sendable, Identifiable {
    public enum Tone: Sendable { case ok, warn }
    public var id: String { text }
    public var text: String
    public var tone: Tone
}

public enum ReleaseCheck {
    /// Compares the code with what is published. Words, not colors: each finding says what to do.
    public static func findings(local: LocalRelease, channels: [(ReleaseChannel, ReleaseObservation?)], githubTag: String?) -> [ReleaseFinding] {
        var out: [ReleaseFinding] = []
        if let header = local.fact(.pluginHeader), let stable = local.fact(.readmeStableTag), compare(header.version, stable.version) != .orderedSame {
            out.append(ReleaseFinding(text: "readme.txt says Stable tag \(stable.version), the plugin header says \(header.version). WordPress.org installs the Stable tag.", tone: .warn))
        }
        for (channel, observation) in channels {
            guard let published = observation?.version, observation?.problem == nil else { continue }
            let code = local.fact(channel.kind.codeSource) ?? local.primary
            out.append(finding(code: code?.version, published: published, where_: channel.kind.title))
        }
        if let tag = githubTag, let code = local.primary {
            out.append(finding(code: code.version, published: tag, where_: "the latest GitHub release"))
        }
        return out
    }

    static func finding(code: String?, published: String, where_: String) -> ReleaseFinding {
        let start = where_.prefix(1).uppercased() + where_.dropFirst()
        guard let code else { return ReleaseFinding(text: "\(start) has \(published). No version found in the code to compare.", tone: .ok) }
        switch compare(code, published) {
        case .orderedSame: return ReleaseFinding(text: "\(start) has \(published), the same as the code.", tone: .ok)
        case .orderedDescending: return ReleaseFinding(text: "The code is at \(code), but \(where_) has \(published). Not released yet.", tone: .warn)
        case .orderedAscending: return ReleaseFinding(text: "\(start) has \(published), newer than this checkout's \(code). Pull before changing it.", tone: .warn)
        }
    }

    /// Compares dotted versions numerically. A leading "v" is ignored; text after a number breaks ties as text.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ text: String) -> [Int] {
            var value = text.lowercased()
            if value.hasPrefix("v") { value.removeFirst() }
            let core = value.prefix { $0.isNumber || $0 == "." }
            return core.split(separator: ".").compactMap { Int($0) }
        }
        let (x, y) = (parts(a), parts(b))
        for index in 0..<max(x.count, y.count) {
            let (l, r) = (index < x.count ? x[index] : 0, index < y.count ? y[index] : 0)
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        func suffix(_ text: String) -> String { String(text.lowercased().trimmingPrefix("v").drop { $0.isNumber || $0 == "." }) }
        let (sa, sb) = (suffix(a), suffix(b))
        // 1.2.0-beta comes before 1.2.0.
        if sa.isEmpty != sb.isEmpty { return sa.isEmpty ? .orderedDescending : .orderedAscending }
        return sa == sb ? .orderedSame : (sa < sb ? .orderedAscending : .orderedDescending)
    }
}
