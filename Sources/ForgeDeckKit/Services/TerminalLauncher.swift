import AppKit
import Foundation

// Opens folders in terminals and editors, and runs approved commands in a terminal.
//
// Folders open through Launch Services (the same path as `open -a Terminal <folder>`):
// the folder URL is handed to the app, so no path is ever typed into a shell or an
// AppleScript, and no Automation permission is needed.
//
// A command in a terminal goes through a small `.command` script. The script holds a
// quoted `cd` and `exec` line and never a secret: secrets are resolved later, inside
// `forgedeck exec`, in the child process.

public struct AppDescriptor: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable { case terminal, editor }
    public var id: String { bundleID }
    public var name: String
    public var bundleID: String
    public var role: Role
    /// Opens a folder as the working directory through Launch Services.
    public var opensFolder = true
    /// Runs a `.command` script handed to it.
    public var runsCommandFile = false
    /// False when the integration follows the app's documentation but was not exercised on a test Mac.
    public var verified = true
}

public enum KnownApps {
    public static let terminals: [AppDescriptor] = [
        AppDescriptor(name: "Terminal", bundleID: "com.apple.Terminal", role: .terminal, runsCommandFile: true),
        AppDescriptor(name: "iTerm2", bundleID: "com.googlecode.iterm2", role: .terminal, runsCommandFile: true),
        AppDescriptor(name: "Ghostty", bundleID: "com.mitchellh.ghostty", role: .terminal, verified: false),
        AppDescriptor(name: "Warp", bundleID: "dev.warp.Warp-Stable", role: .terminal, verified: false),
    ]

    public static let editors: [AppDescriptor] = [
        AppDescriptor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", role: .editor),
        AppDescriptor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", role: .editor),
        AppDescriptor(name: "Xcode", bundleID: "com.apple.dt.Xcode", role: .editor),
        AppDescriptor(name: "Zed", bundleID: "dev.zed.Zed", role: .editor, verified: false),
    ]

    public static func descriptor(bundleID: String) -> AppDescriptor? {
        (terminals + editors).first { $0.bundleID == bundleID }
    }
}

public protocol AppOpening: Sendable {
    func applicationURL(bundleID: String) -> URL?
    /// Opens the items with the app. Throws when the app could not be started.
    func open(_ items: [URL], withApplicationAt app: URL) async throws
    func open(_ url: URL) async throws
    func reveal(_ url: URL)
}

public struct WorkspaceOpener: AppOpening {
    public init() {}

    public func applicationURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    public func open(_ items: [URL], withApplicationAt app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(items, withApplicationAt: app, configuration: configuration)
    }

    public func open(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
    }

    public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

public enum LaunchOutcome: Sendable, Equatable {
    /// The app accepted the request.
    case opened(app: String)
    /// Nothing was opened. `copyCommand` is a safe line the user can paste instead.
    case failed(reason: String, copyCommand: String?)

    public var didOpen: Bool { if case .opened = self { true } else { false } }
}

public struct TerminalLauncher: Sendable {
    public let opener: any AppOpening
    public let launchDirectory: URL

    public init(opener: any AppOpening = WorkspaceOpener(), launchDirectory: URL = StoreLocation.resolve().launchDirectory) {
        self.opener = opener
        self.launchDirectory = launchDirectory
    }

    public func installed(_ apps: [AppDescriptor]) -> [AppDescriptor] {
        apps.filter { opener.applicationURL(bundleID: $0.bundleID) != nil }
    }

    /// The line to paste when automation is unavailable.
    public static func copyCommand(directory: String, command: [String] = []) -> String {
        let cd = "cd -- " + ShellQuote.quote(directory)
        return command.isEmpty ? cd : cd + " && " + ShellQuote.join(command)
    }

    /// Opens a folder in a terminal or editor.
    /// `item` is what the app opens, inside the folder: a workspace or project file. It defaults to the folder.
    public func openFolder(_ path: String, appBundleID: String, item: String? = nil) async -> LaunchOutcome {
        let fallback = Self.copyCommand(directory: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed(reason: "The folder no longer exists at \(path).", copyCommand: nil)
        }
        let name = KnownApps.descriptor(bundleID: appBundleID)?.name ?? appBundleID
        guard let app = opener.applicationURL(bundleID: appBundleID) else {
            return .failed(reason: "\(name) is not installed.", copyCommand: fallback)
        }
        do {
            let opened = item.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: path, isDirectory: true)
            try await opener.open([opened], withApplicationAt: app)
            return .opened(app: name)
        } catch {
            return .failed(reason: "\(name) could not be opened: \(error.localizedDescription)", copyCommand: fallback)
        }
    }

    /// The text of a launch script. Every dynamic word is single-quoted.
    public static func script(directory: String, command: [String]) -> String {
        script(directory: directory, commands: [command])
    }

    /// Several commands in order. Each word is quoted; the script stops at the first failure.
    public static func script(directory: String, commands: [[String]]) -> String {
        var lines = ["#!/bin/zsh", "# Written by \(Brand.name). Holds no secrets. Safe to delete.", "cd -- \(ShellQuote.quote(directory)) || exit 1"]
        let steps = commands.filter { !$0.isEmpty }
        for (index, step) in steps.enumerated() {
            if index == steps.count - 1 {
                lines.append("exec \(ShellQuote.join(step))")
            } else {
                lines.append("print -r -- \(ShellQuote.quote("▸ " + step.joined(separator: " ")))")
                lines.append("\(ShellQuote.join(step)) || exit $?")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the launch script for commands and returns its path. The file holds no secrets.
    public func writeScript(commands: [[String]], in directory: String) throws -> URL {
        try FileManager.default.createDirectory(at: launchDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = launchDirectory.appending(path: "run-\(UUID().uuidString.prefix(8)).command")
        try Self.script(directory: directory, commands: commands).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    /// Runs a command in a terminal window, in a folder.
    public func run(command: [String], in directory: String, terminalBundleID: String) async -> LaunchOutcome {
        await run(commands: [command], in: directory, terminalBundleID: terminalBundleID)
    }

    public func run(commands: [[String]], in directory: String, terminalBundleID: String) async -> LaunchOutcome {
        let steps = commands.filter { !$0.isEmpty }
        let fallback = "cd -- " + ShellQuote.quote(directory) + steps.map { " && " + ShellQuote.join($0) }.joined()
        guard !steps.isEmpty else { return .failed(reason: "The command is empty.", copyCommand: nil) }
        let descriptor = KnownApps.descriptor(bundleID: terminalBundleID)
        let name = descriptor?.name ?? terminalBundleID
        guard let app = opener.applicationURL(bundleID: terminalBundleID) else {
            return .failed(reason: "\(name) is not installed.", copyCommand: fallback)
        }
        guard descriptor?.runsCommandFile == true else {
            return .failed(reason: "\(name) has no verified way to start a command. Paste the copied command instead.", copyCommand: fallback)
        }
        do {
            try FileManager.default.createDirectory(at: launchDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            sweep()
            let file = launchDirectory.appending(path: "run-\(UUID().uuidString.prefix(8)).command")
            try Self.script(directory: directory, commands: steps).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            try await opener.open([file], withApplicationAt: app)
            return .opened(app: name)
        } catch {
            return .failed(reason: "\(name) could not be opened: \(error.localizedDescription)", copyCommand: fallback)
        }
    }

    /// Removes launch scripts older than a day.
    private func sweep() {
        let cutoff = Date.now.addingTimeInterval(-86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: launchDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "command" {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    public func openURL(_ text: String) async -> LaunchOutcome {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            return .failed(reason: "That link is not a web address.", copyCommand: nil)
        }
        do {
            try await opener.open(url)
            return .opened(app: "browser")
        } catch {
            return .failed(reason: "The link could not be opened: \(error.localizedDescription)", copyCommand: nil)
        }
    }
}

/// AI coding agents that can be started in a project folder.
public enum AgentPrograms {
    public static var known: [String] { AgentCatalog.all.map(\.program) }

    public static func installed() -> [String] { known.filter { ExecutableLocator.find($0) != nil } }

    /// A short project description for an agent: names, stack, and layout. No tokens,
    /// no customer data, no file contents, and paths relative to the home folder.
    public static func contextFile(for product: Product, cache: ObservationCache) -> String {
        var lines = ["# \(product.name)", ""]
        if !product.tagline.isEmpty { lines += [product.tagline, ""] }
        if !product.stack.isEmpty { lines.append("Stack: \(product.stack.joined(separator: ", "))") }
        lines.append("Lifecycle: \(product.lifecycle.title)")
        if !product.components.isEmpty {
            lines += ["", "## Components"]
            for component in product.components { lines.append("- \(component.name) (\(component.kind.title))") }
        }
        if !product.checkouts.isEmpty {
            lines += ["", "## Checkouts"]
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for checkout in product.checkouts {
                let path = checkout.path.hasPrefix(home) ? "~" + checkout.path.dropFirst(home.count) : checkout.path
                let state = cache.git[checkout.id]?.summary ?? "not inspected"
                lines.append("- \(checkout.name): \(path) (\(state))")
            }
        }
        if !product.environments.isEmpty {
            lines += ["", "## Environments"]
            for environment in product.environments {
                lines.append("- \(environment.name) (\(environment.tier.rawValue))\(environment.domains.isEmpty ? "" : ": " + environment.domains.joined(separator: ", "))")
            }
        }
        lines += ["", "Secrets are not included. Use `\(Brand.cliName) exec` with an approved profile to run a command with its variables."]
        return Redactor().redact(lines.joined(separator: "\n")) + "\n"
    }
}
