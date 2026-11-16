import Foundation

/// Walks one connection step by step and says where it breaks. Never shows a secret.
public struct DoctorStep: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable { case pass, warn, fail, skipped }
    public var id: String { title }
    public var title: String
    public var state: State
    public var detail: String

    public init(_ title: String, _ state: State, _ detail: String) {
        self.title = title
        self.state = state
        self.detail = detail
    }
}

public struct ConnectionDoctor: Sendable {
    public var http: any HTTPClient
    public var ssh: SSHInspector
    public var runner: any ProcessRunning

    public init(http: any HTTPClient = URLSessionHTTPClient(timeout: 8), ssh: SSHInspector = SSHInspector(),
                runner: any ProcessRunning = SystemProcessRunner()) {
        self.http = http
        self.ssh = ssh
        self.runner = runner
    }

    static func resolves(_ host: String) async -> Bool {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            return status == 0
        }.value
    }

    /// DNS, TLS, authentication, capability, last good response.
    public func diagnose(probe: ProbeConfig, bearer: String?, tokenConfigured: Bool, tier: EnvironmentTier, lastGood: Date?, now: Date = .now) async -> [DoctorStep] {
        var steps: [DoctorStep] = []
        let url: URL
        do {
            url = try URLPolicy.validate(probe.url)
            steps.append(DoctorStep("Address", .pass, "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"))
        } catch {
            return [DoctorStep("Address", .fail, String(describing: error))]
        }
        let host = url.host ?? ""
        if URLPolicy.isLoopback(host) {
            steps.append(DoctorStep("DNS", .pass, "Loopback address"))
        } else if await Self.resolves(host) {
            steps.append(DoctorStep("DNS", .pass, "\(host) resolves"))
        } else {
            steps.append(DoctorStep("DNS", .fail, "\(host) does not resolve. Check the domain and your network."))
            steps += [DoctorStep("TLS", .skipped, "Needs DNS"), DoctorStep("Authentication", .skipped, "Needs a connection"),
                      DoctorStep("Capability", .skipped, "Needs a connection")]
            steps.append(lastGoodStep(lastGood, now: now))
            return steps
        }
        let outcome = await HTTPProbeConnector(http: http).status(probe, bearer: bearer, expectedTier: tier)
        let problem = outcome.sample.problem ?? outcome.deployment?.problem
        if problem == .tlsFailure {
            steps.append(DoctorStep("TLS", .fail, outcome.detail))
        } else if [.offline, .timeout, .unavailable].contains(problem) && outcome.sample.statusCode == nil {
            steps.append(DoctorStep("TLS", .fail, outcome.detail))
        } else {
            steps.append(DoctorStep("TLS", .pass, url.scheme == "https" ? "Certificate verified" : "Plain HTTP on loopback"))
        }
        if outcome.sample.statusCode == nil {
            steps += [DoctorStep("Authentication", .skipped, "No response"), DoctorStep("Capability", .skipped, "No response")]
        } else {
            switch problem {
            case .unauthorized:
                steps.append(DoctorStep("Authentication", .fail, tokenConfigured ? "The token was rejected. It may be revoked or expired: rotate it." : "The endpoint needs a token. Add a secret variable and select it for this check."))
                steps.append(DoctorStep("Capability", .skipped, "Needs authentication"))
            case .forbidden:
                steps.append(DoctorStep("Authentication", .warn, "The token is valid but lacks the status:read scope."))
                steps.append(DoctorStep("Capability", .skipped, "Needs permission"))
            default:
                steps.append(DoctorStep("Authentication", .pass, tokenConfigured ? "Token accepted" : "No token needed"))
                if probe.kind.reportsRelease {
                    if let deployment = outcome.deployment, deployment.problem == nil {
                        steps.append(DoctorStep("Capability", .pass, "Reports release \(deployment.version ?? shortSHA(deployment.sha)), health \(deployment.health.title.lowercased())"))
                    } else {
                        steps.append(DoctorStep("Capability", .fail, outcome.deployment?.detail ?? outcome.detail))
                    }
                } else {
                    steps.append(DoctorStep("Capability", outcome.sample.ok ? .pass : .fail, outcome.detail))
                }
            }
        }
        steps.append(lastGoodStep(outcome.sample.ok ? now : lastGood, now: now))
        return steps
    }

    private func lastGoodStep(_ date: Date?, now: Date) -> DoctorStep {
        guard let date else { return DoctorStep("Last good response", .warn, "Never") }
        return DoctorStep("Last good response", .pass, RelativeTime.short(date, now: now))
    }

    public func diagnoseGitHub(token: String?) async -> [DoctorStep] {
        var steps: [DoctorStep] = []
        steps.append(await Self.resolves("api.github.com") ? DoctorStep("DNS", .pass, "api.github.com resolves")
                                                          : DoctorStep("DNS", .fail, "api.github.com does not resolve. This Mac may be offline."))
        guard steps[0].state == .pass else { return steps }
        guard let token, !token.isEmpty else {
            steps.append(DoctorStep("Authentication", .warn, "No token stored. Public repositories work; private ones need a token."))
            return steps
        }
        switch await GitHubConnector(http: http, token: token).viewer() {
        case .success(let viewer), .partial(let viewer, _):
            steps.append(DoctorStep("Authentication", .pass, "Signed in as \(viewer.login)"))
            let writeScopes = viewer.scopes.filter { ["repo", "workflow", "admin:org", "delete_repo", "write:packages"].contains($0) }
            if viewer.scopes.isEmpty {
                steps.append(DoctorStep("Permissions", .pass, "Fine-grained token: access is set per repository on GitHub"))
            } else if writeScopes.isEmpty {
                steps.append(DoctorStep("Permissions", .pass, "Scopes: \(viewer.scopes.joined(separator: ", "))"))
            } else {
                steps.append(DoctorStep("Permissions", .warn, "This token can write (\(writeScopes.joined(separator: ", "))). \(Brand.name) only reads. A fine-grained read-only token is safer."))
            }
            if let remaining = viewer.rateLimitRemaining, let limit = viewer.rateLimit {
                steps.append(DoctorStep("Rate limit", remaining < 100 ? .warn : .pass, "\(remaining) of \(limit) requests left this hour"))
            }
        case .failure(let problem, let detail, _):
            steps.append(DoctorStep("Authentication", .fail, problem == .unauthorized ? "GitHub rejected the token. It may be revoked or expired." : detail))
        }
        return steps
    }

    public func diagnoseSSH(alias: String) async -> [DoctorStep] {
        var steps: [DoctorStep] = []
        guard SSHConfig.isValidAlias(alias) else { return [DoctorStep("Host alias", .fail, "\"\(alias)\" is not a valid alias.")] }
        let configured = SSHConfig.load().contains { $0.alias == alias }
        steps.append(DoctorStep("Host alias", configured ? .pass : .warn,
                                configured ? "Found in ~/.ssh/config" : "Not in ~/.ssh/config. ssh will treat it as a host name."))
        if let target = await ssh.resolved(alias: alias) {
            steps.append(await Self.resolves(target.host) ? DoctorStep("DNS", .pass, "\(target.host) resolves")
                                                           : DoctorStep("DNS", .fail, "\(target.host) does not resolve."))
        }
        let known = await ssh.hostKeyIsKnown(alias: alias)
        steps.append(DoctorStep("Host key", known ? .pass : .fail,
                                known ? "Present in known_hosts" : "Not in known_hosts. Connect once in a terminal and check the fingerprint. \(Brand.name) never accepts a host key for you."))
        guard known, steps.allSatisfy({ $0.state != .fail }) else {
            steps.append(DoctorStep("Authentication", .skipped, "Needs a trusted host key"))
            return steps
        }
        let result = await ssh.probe(alias: alias, command: SSHProbeCommand.find("uptime")!)
        if result.ok {
            steps.append(DoctorStep("Authentication", .pass, "Key accepted"))
            steps.append(DoctorStep("Read-only probe", .pass, result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else {
            steps.append(DoctorStep(result.problem == .hostKeyChanged ? "Host key" : "Authentication", .fail, result.detail))
        }
        return steps
    }

    /// The local tools ForgeDeck can use.
    public func toolchain() async -> [DoctorStep] {
        var steps: [DoctorStep] = []
        for (name, why) in [("git", "Git status and history"), ("ssh", "SSH probes"), ("gh", "optional: import a GitHub token"),
                            ("docker", "optional: container status"), ("op", "optional: 1Password references")] {
            if let url = ExecutableLocator.find(name) {
                steps.append(DoctorStep(name, .pass, url.path))
            } else {
                steps.append(DoctorStep(name, why.hasPrefix("optional") ? .skipped : .fail, "Not installed (\(why))"))
            }
        }
        let terminals = TerminalLauncher().installed(KnownApps.terminals).map(\.name)
        steps.append(DoctorStep("Terminals", terminals.isEmpty ? .fail : .pass, terminals.joined(separator: ", ")))
        let editors = TerminalLauncher().installed(KnownApps.editors).map(\.name)
        steps.append(DoctorStep("Editors", editors.isEmpty ? .warn : .pass, editors.isEmpty ? "None found" : editors.joined(separator: ", ")))
        let agents = AgentPrograms.installed()
        steps.append(DoctorStep("AI agents", agents.isEmpty ? .skipped : .pass, agents.isEmpty ? "None found" : agents.joined(separator: ", ")))
        return steps
    }
}
