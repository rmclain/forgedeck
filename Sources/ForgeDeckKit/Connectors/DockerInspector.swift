import Foundation

/// Reads the local Docker CLI. Status and bounded logs only.
public struct DockerContainer: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var image: String
    public var state: String
    public var status: String
    public var composeProject: String?

    public var isRunning: Bool { state == "running" }
}

public struct DockerInspector: Sendable {
    public let runner: any ProcessRunning
    public let docker: URL?

    public init(runner: any ProcessRunning = SystemProcessRunner(), docker: URL? = ExecutableLocator.find("docker")) {
        self.runner = runner
        self.docker = docker
    }

    public var isInstalled: Bool { docker != nil }

    public func context() async -> String? {
        guard let docker, let result = try? await runner.run(ProcessRequest(executable: docker, arguments: ["context", "show"], timeout: 5)),
              result.ok else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func containers() async -> ConnectorResult<[DockerContainer]> {
        guard let docker else { return .failure(.notConfigured, "The Docker CLI is not installed.") }
        let result: ProcessResult
        do {
            result = try await runner.run(ProcessRequest(executable: docker, arguments: ["ps", "--all", "--no-trunc", "--format", "{{json .}}"], timeout: 8))
        } catch {
            return .failure(.unavailable, String(describing: error))
        }
        if result.timedOut { return .failure(.timeout, "Docker did not answer in time.") }
        guard result.ok else {
            let text = result.stderr.lowercased()
            if text.contains("cannot connect") || text.contains("is the docker daemon running") {
                return .failure(.unavailable, "Docker is installed but the daemon is not running.")
            }
            if text.contains("permission denied") { return .failure(.forbidden, "This user may not talk to the Docker daemon.") }
            return .failure(.unavailable, Redactor().redact(result.stderr.split(separator: "\n").first.map(String.init) ?? "Docker failed."))
        }
        return .success(Self.parse(result.stdout))
    }

    public static func parse(_ text: String) -> [DockerContainer] {
        text.split(separator: "\n").compactMap { line in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = json["ID"] as? String else { return nil }
            let labels = (json["Labels"] as? String ?? "").split(separator: ",")
            let project = labels.first { $0.hasPrefix("com.docker.compose.project=") }.map { String($0.dropFirst("com.docker.compose.project=".count)) }
            return DockerContainer(id: id, name: json["Names"] as? String ?? id, image: json["Image"] as? String ?? "",
                                   state: (json["State"] as? String ?? "").lowercased(), status: json["Status"] as? String ?? "",
                                   composeProject: project)
        }
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first != "-", name.count <= 128 else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    /// The last lines of a container's log, redacted and capped.
    public func logs(container: String, tail: Int = 200) async -> ConnectorResult<String> {
        guard let docker else { return .failure(.notConfigured, "The Docker CLI is not installed.") }
        guard Self.isValidName(container) else { return .failure(.notConfigured, "Not a container name.") }
        let lines = String(min(max(tail, 1), 1_000))
        guard let result = try? await runner.run(ProcessRequest(executable: docker, arguments: ["logs", "--tail", lines, "--", container],
                                                                timeout: 10, maxOutputBytes: 400_000)) else {
            return .failure(.unavailable, "Docker could not be started.")
        }
        guard result.ok else { return .failure(.unavailable, Redactor().redact(result.stderr)) }
        return .success(Redactor().redact(result.stdout + result.stderr))
    }
}
