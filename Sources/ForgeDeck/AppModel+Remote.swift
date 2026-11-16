import Foundation
import ForgeDeckKit

// Forge Remote: a Claude Code Remote Control server in ForgeDeck's terminal dock. Sessions started from the
// Claude app begin in the Forge Session workspace, which lists every product, and each one starts clean.

extension AppModel {
    var remoteSettings: ForgeRemoteSettings { portfolio.settings.remote ?? ForgeRemoteSettings() }
    var remoteWorkspace: ForgeRemoteWorkspace { ForgeRemoteWorkspace(store: store.location) }
    var remoteSession: TerminalSession? { remoteSessionID.flatMap { id in terminals.sessions.first { $0.id == id } } }
    var isRemoteRunning: Bool { remoteSession?.isRunning == true }

    /// One line for Settings and the menu bar.
    var remoteStatus: String {
        if ExecutableLocator.find(ForgeRemote.program) == nil { return "Claude Code is not installed" }
        if isRemoteRunning { return "Running: \(ForgeRemote.products(in: portfolio).count) products reachable from the Claude app" }
        if case .exited(let code)? = remoteSession?.state { return code.map { "Stopped (exit \($0))" } ?? "Stopped" }
        if case .failed(let why)? = remoteSession?.state { return "Could not start: \(why)" }
        return remoteSettings.enabled ? "Starting…" : "Off"
    }

    func updateRemote(_ change: (inout ForgeRemoteSettings) -> Void) {
        var settings = remoteSettings
        change(&settings)
        portfolio.settings.remote = settings
    }

    /// The Settings toggle.
    func setRemote(enabled: Bool) {
        updateRemote { $0.enabled = enabled }
        if enabled { startRemote(showTerminal: true) } else { stopRemote() }
    }

    /// Starts the server, or brings its terminal forward when it already runs.
    func startRemote(showTerminal: Bool) {
        if let session = remoteSession, session.isRunning {
            if showTerminal { showRemoteTerminal() }
            return
        }
        guard let claude = ExecutableLocator.find(ForgeRemote.program) else {
            return show("Forge Remote needs Claude Code. Install it, then turn Forge Remote on again.", isError: true)
        }
        let workspace = remoteWorkspace
        do {
            try syncRemoteWorkspace(writeAllContexts: true)
        } catch {
            return show("Could not write the Forge Session folder: \(error.localizedDescription)", isError: true)
        }
        let settings = remoteSettings
        let argv = ForgeRemote.command(program: claude, settings: settings)
        guard var launch = TerminalLaunch.command(argv, kind: .agent, title: "Forge Remote", in: workspace.folder.path) else {
            return show("Claude Code could not be started.", isError: true)
        }
        launch.banner = remoteBanner(settings)
        let wasVisible = terminals.isVisible
        let previous = terminals.selectedID
        if let old = remoteSession { terminals.close(old) }
        let session = terminals.open(launch, productID: nil, checkoutID: nil)
        if !showTerminal {
            terminals.isVisible = wasVisible
            terminals.selectedID = previous
        }
        remoteSessionID = session.id
        remoteStopping = false
        session.onExit = { [weak self] ended in self?.remoteEnded(ended) }
        if settings.keepAwake, remoteActivity == nil {
            remoteActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Forge Remote is running")
        }
        record("remote.start", detail: "agent=claude mode=\(settings.mode.rawValue) products=\(ForgeRemote.products(in: portfolio).count)")
    }

    func stopRemote() {
        remoteStopping = true
        if let session = remoteSession {
            terminals.close(session)
            record("remote.stop")
        }
        remoteSessionID = nil
        endRemoteActivity()
    }

    /// Restart after a setting that the server reads only at start changed.
    func restartRemote() {
        guard remoteSettings.enabled else { return }
        stopRemote()
        startRemote(showTerminal: false)
    }

    func showRemoteTerminal() {
        guard let session = remoteSession else { return }
        terminals.showAll = true
        terminals.select(session)
        terminals.isVisible = true
    }

    /// Rewrites the briefing and folder access, so the next remote session sees new or renamed products.
    func syncRemoteWorkspace(writeAllContexts: Bool = false) throws {
        let context = contextLocation
        for product in ForgeRemote.products(in: portfolio)
        where writeAllContexts || !FileManager.default.fileExists(atPath: context.contextFile(product).path) {
            _ = try? AgentContextBundle.write(for: product, portfolio: portfolio, cache: cache, location: context, mcp: mcpInfo(product))
        }
        try remoteWorkspace.write(portfolio: portfolio, context: context, cli: cliInstalledPath)
    }

    /// The server ended. When nobody stopped it, start it again, at most three times in ten minutes.
    private func remoteEnded(_ session: TerminalSession) {
        guard session.id == remoteSessionID else { return }
        endRemoteActivity()
        guard !remoteStopping, remoteSettings.enabled, !Runtime.isAutomated else { return }
        let now = Date.now
        remoteRestarts = remoteRestarts.filter { now.timeIntervalSince($0) < 600 } + [now]
        guard remoteRestarts.count <= 3 else {
            record("remote.stop", detail: "reason=exited-repeatedly", outcome: "failed")
            return show("Forge Remote stopped three times in ten minutes. Open its terminal to see why.", isError: true)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.remoteSettings.enabled, !self.remoteStopping, self.remoteSessionID == session.id else { return }
            self.startRemote(showTerminal: false)
        }
    }

    private func endRemoteActivity() {
        if let activity = remoteActivity { ProcessInfo.processInfo.endActivity(activity) }
        remoteActivity = nil
    }

    private func remoteBanner(_ settings: ForgeRemoteSettings) -> String {
        let dim = "\u{1B}[2m", bold = "\u{1B}[1m", reset = "\u{1B}[0m"
        let home = NSHomeDirectory()
        let folder = remoteWorkspace.folder.path.replacingOccurrences(of: home, with: "~")
        let lines = [
            "\(bold)Forge Remote\(reset)  open the Claude app or claude.ai/code and pick \"\(ForgeRemote.sessionName(settings))\"",
            "\(dim)Workspace  \(folder) (CLAUDE.md lists \(ForgeRemote.products(in: portfolio).count) products)\(reset)",
            "\(dim)Sessions   each new session starts clean; one product per session\(reset)",
            "\(dim)Approvals  \(settings.mode.title)\(settings.keepAwake ? "; this Mac stays awake while this runs" : "")\(reset)",
            "",
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
