import Foundation

// SSH, through the system client. ForgeDeck never reads or stores a private key:
// the user's ~/.ssh/config and SSH agent stay in charge. Host keys are always checked.
// The only remote commands are the fixed ones in SSHProbeCommand.catalog.

public struct SSHConfigHost: Sendable, Hashable, Identifiable {
    public var id: String { alias }
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: String?
}

public enum SSHConfig {
    public static var defaultPath: String { NSHomeDirectory() + "/.ssh/config" }

    /// Host aliases from an ssh config. Patterns with wildcards are not hosts and are skipped.
    public static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: [Int] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch key {
            case "host":
                current = []
                for alias in value.split(whereSeparator: \.isWhitespace).map(String.init)
                where isValidAlias(alias) && !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                    current.append(hosts.count)
                    hosts.append(SSHConfigHost(alias: alias))
                }
            case "match":
                current = []
            case "hostname": for index in current { hosts[index].hostName = value }
            case "user": for index in current { hosts[index].user = value }
            case "port": for index in current { hosts[index].port = value }
            default: break
            }
        }
        return hosts
    }

    public static func load(path: String = defaultPath) -> [SSHConfigHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// An alias is passed to ssh as one argument. It may not look like an option.
    public static func isValidAlias(_ alias: String) -> Bool {
        guard let first = alias.first, first != "-", alias.count <= 255 else { return false }
        return alias.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-@".unicodeScalars.contains($0) }
    }
}

public struct SSHProbeCommand: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// The remote command line. Fixed text: nothing from a remote API or a server is ever added.
    public var remote: String

    public static let catalog: [SSHProbeCommand] = [
        SSHProbeCommand(id: "uptime", title: "Uptime and load", remote: "uptime"),
        SSHProbeCommand(id: "disk", title: "Disk usage", remote: "df -h /"),
        SSHProbeCommand(id: "memory", title: "Memory", remote: "free -m 2>/dev/null || vm_stat"),
        SSHProbeCommand(id: "docker", title: "Docker containers", remote: "docker ps --format '{{.Names}}\\t{{.Status}}\\t{{.Image}}'"),
        SSHProbeCommand(id: "os", title: "OS release", remote: "uname -srm"),
    ]

    public static func find(_ id: String) -> SSHProbeCommand? { catalog.first { $0.id == id } }

    /// Reading a release file is the one command with a user-supplied part: the path,
    /// limited to plain path characters and quoted.
    public static func release(path: String) -> SSHProbeCommand? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        guard path.hasPrefix("/"), !path.contains(".."), path.count <= 300,
              path.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return nil }
        return SSHProbeCommand(id: "release", title: "Release file", remote: "cat -- " + ShellQuote.quote(path))
    }
}

public struct SSHProbeResult: Sendable, Equatable {
    public var ok: Bool
    public var problem: ObservationProblem?
    public var output: String
    public var detail: String
}

public struct SSHInspector: Sendable {
    public let runner: any ProcessRunning
    public let ssh: URL
    public let keygen: URL
    public let timeout: TimeInterval

    public init(runner: any ProcessRunning = SystemProcessRunner(), timeout: TimeInterval = 15) {
        self.runner = runner
        ssh = URL(fileURLWithPath: "/usr/bin/ssh")
        keygen = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        self.timeout = timeout
    }

    /// Options for every connection: never prompt, never accept a host key on its own.
    public static let options = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
                                 "-o", "NumberOfPasswordPrompts=0", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-T"]

    public static func arguments(alias: String, command: SSHProbeCommand) -> [String] {
        options + ["--", alias, command.remote]
    }

    /// The host name and port ssh would actually use for an alias (`ssh -G`).
    public func resolved(alias: String) async -> (host: String, port: String)? {
        guard SSHConfig.isValidAlias(alias),
              let result = try? await runner.run(ProcessRequest(executable: ssh, arguments: ["-G", "--", alias], timeout: 5)), result.ok else { return nil }
        var host = alias, port = "22"
        for line in result.stdout.split(separator: "\n") {
            if line.hasPrefix("hostname ") { host = String(line.dropFirst("hostname ".count)) }
            if line.hasPrefix("port ") { port = String(line.dropFirst("port ".count)) }
        }
        return (host, port)
    }

    /// True when known_hosts already has a key for the host the alias points at.
    public func hostKeyIsKnown(alias: String) async -> Bool {
        guard let target = await resolved(alias: alias) else { return false }
        let name = target.port == "22" ? target.host : "[\(target.host)]:\(target.port)"
        guard let result = try? await runner.run(ProcessRequest(executable: keygen, arguments: ["-F", name], timeout: 5)) else { return false }
        return result.ok && !result.stdout.isEmpty
    }

    public func probe(alias: String, command: SSHProbeCommand) async -> SSHProbeResult {
        guard SSHConfig.isValidAlias(alias) else {
            return SSHProbeResult(ok: false, problem: .notConfigured, output: "", detail: "\"\(alias)\" is not a valid host alias.")
        }
        let result: ProcessResult
        do {
            result = try await runner.run(ProcessRequest(executable: ssh, arguments: Self.arguments(alias: alias, command: command),
                                                         timeout: timeout, maxOutputBytes: 64_000))
        } catch {
            return SSHProbeResult(ok: false, problem: .unavailable, output: "", detail: String(describing: error))
        }
        if result.timedOut {
            return SSHProbeResult(ok: false, problem: .timeout, output: "", detail: "The host did not answer in time.")
        }
        if result.ok {
            return SSHProbeResult(ok: true, problem: nil, output: Redactor().redact(result.stdout), detail: "Connected")
        }
        let (problem, detail) = Self.classify(stderr: result.stderr)
        return SSHProbeResult(ok: false, problem: problem, output: Redactor().redact(result.stdout), detail: detail)
    }

    public static func classify(stderr: String) -> (ObservationProblem, String) {
        let text = stderr.lowercased()
        if text.contains("remote host identification has changed") || text.contains("host key for") && text.contains("has changed") {
            return (.hostKeyChanged, "The host's key changed since it was last trusted. Nothing was sent. Verify the new fingerprint with the server's owner, then update known_hosts yourself.")
        }
        if text.contains("host key verification failed") || text.contains("no matching host key") || text.contains("host key is known") {
            return (.hostKeyUnknown, "This host is not in known_hosts. Connect once in a terminal, check the fingerprint, and accept it there.")
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            return (.unauthorized, "The server refused the key. Check that the SSH agent holds the right key (ssh-add -l).")
        }
        if text.contains("could not resolve hostname") {
            return (.unavailable, "The host name could not be resolved.")
        }
        if text.contains("timed out") {
            return (.timeout, "The connection timed out.")
        }
        if text.contains("connection refused") || text.contains("no route to host") || text.contains("network is unreachable") {
            return (.unavailable, "The host refused the connection or cannot be reached.")
        }
        if text.contains("command not found") {
            return (.unsupported, "The host does not have that command.")
        }
        let first = stderr.split(separator: "\n").first.map(String.init) ?? "The connection failed."
        return (.unavailable, Redactor().redact(first))
    }

    /// Reads a release file and turns it into a verified deployment observation.
    /// Accepts the JSON written by the deployment-fingerprint recipe, or a bare commit sha.
    public func release(alias: String, path: String, ttl: TimeInterval = 900) async -> DeploymentObservation {
        var observation = DeploymentObservation()
        observation.provenance = Provenance(source: .sshInspection, level: .unknown, ttl: ttl)
        guard let command = SSHProbeCommand.release(path: path) else {
            observation.problem = .notConfigured
            observation.detail = "The release file path may only hold letters, digits, and / . _ -"
            return observation
        }
        let result = await probe(alias: alias, command: command)
        guard result.ok else {
            observation.problem = result.problem ?? .unavailable
            observation.detail = result.detail
            return observation
        }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            let sha = (json["commit_sha"] ?? json["sha"] ?? json["commit"]) as? String
            observation.sha = sha.flatMap { GitService.isRevision($0) ? $0.lowercased() : nil }
            observation.version = json["version"] as? String
            observation.deployedAt = FlexibleDate.parse((json["deployed_at"] ?? json["built_at"]) as? String)
        } else if GitService.isRevision(text) {
            observation.sha = text.lowercased()
        }
        if observation.sha == nil && observation.version == nil {
            observation.problem = .malformed
            observation.detail = "The release file holds no commit or version."
        } else {
            observation.provenance = Provenance(source: .sshInspection, level: .verified, ttl: ttl)
            observation.detail = "Read from \(path) on \(alias)"
        }
        return observation
    }
}
