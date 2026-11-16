import Foundation
import Testing
@testable import ForgeDeckKit

private let terminalID = "com.apple.Terminal"
private let ghosttyID = "com.mitchellh.ghostty"

/// Directory names a shell would love to misread. Each one tries to create INJECTED.
private let hostileNames = [
    "it's here",
    "double \"quoted\" name",
    "semi; touch INJECTED",
    "back `touch INJECTED` tick",
    "dollar $(touch INJECTED) paren",
    "and && touch INJECTED",
    "pipe | touch INJECTED",
    "new\nline; touch INJECTED",
    "tab\there",
    "back\\slash\\",
    "ünïcødé 日本語 🚀",
    "-rf",
    "--help",
    "$HOME ${PATH}",
    "glob * ? [abc] {a,b}",
    "~user #comment !history",
    "'; touch INJECTED; echo '",
]

@Suite struct ShellQuoteTests {
    @Test func plainWordsStayReadable() {
        #expect(ShellQuote.quote("npm") == "npm")
        #expect(ShellQuote.quote("/usr/local/bin/node") == "/usr/local/bin/node")
        #expect(ShellQuote.quote("--flag=value") == "--flag=value")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("two words") == "'two words'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.join(["echo", "a b", "c"]) == "echo 'a b' c")
    }

    @Test(arguments: hostileNames)
    func quotedDirectoryNamesRoundTripThroughZsh(name: String) throws {
        let sandbox = try makeTempDir("quote")
        defer { removeTemp(sandbox) }
        let directory = sandbox.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let absolute = try runTool("/bin/zsh", ["-f", "-c", "cd -- \(ShellQuote.quote(directory.path)) && pwd"], cwd: sandbox)
        #expect(absolute.code == 0, "\(absolute.err)")
        #expect(absolute.out.hasSuffix("\n"))
        #expect(realPath(String(absolute.out.dropLast())) == realPath(directory.path))

        // A relative name is where a leading dash or a metacharacter would bite.
        let relative = try runTool("/bin/zsh", ["-f", "-c", "cd -- \(ShellQuote.quote(name)) && pwd"], cwd: sandbox)
        #expect(relative.code == 0, "\(relative.err)")
        #expect(realPath(String(relative.out.dropLast())) == realPath(directory.path))

        let entries = try FileManager.default.subpathsOfDirectory(atPath: sandbox.path)
        #expect(entries == [name], "an injected command created \(entries)")
    }

    @Test(arguments: hostileNames)
    func copyCommandIsSafeToPaste(name: String) throws {
        let sandbox = try makeTempDir("copy")
        defer { removeTemp(sandbox) }
        let directory = sandbox.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = TerminalLauncher.copyCommand(directory: directory.path, command: ["/bin/echo", name, "$(touch INJECTED)", "it's"])
        let result = try runTool("/bin/zsh", ["-f", "-c", line], cwd: sandbox)
        #expect(result.code == 0, "\(result.err)")
        #expect(result.out == "\(name) $(touch INJECTED) it's\n")
        #expect(try FileManager.default.subpathsOfDirectory(atPath: sandbox.path) == [name])
    }

    @Test func copyCommandWithoutACommandIsJustCd() {
        #expect(TerminalLauncher.copyCommand(directory: "/code/app") == "cd -- /code/app")
        #expect(TerminalLauncher.copyCommand(directory: "/code/my app") == "cd -- '/code/my app'")
        #expect(TerminalLauncher.copyCommand(directory: "/code/app", command: ["npm", "run", "dev"]) == "cd -- /code/app && npm run dev")
    }
}

@Suite struct LaunchScriptTests {
    @Test func aGeneratedScriptPassesEveryArgumentLiterally() throws {
        let sandbox = try makeTempDir("script")
        defer { removeTemp(sandbox) }
        let directory = sandbox.appending(path: "proj's $(touch INJECTED) `touch INJECTED`; touch INJECTED", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let arguments = ["$(touch INJECTED)", "`touch INJECTED`", "a;touch INJECTED", "it's", "*", "$HOME", "two words",
                         "--flag=x y", "back\\slash", "a|b>c<d&e", "\"quoted\"", "#not-a-comment", "~", ""]
        let script = TerminalLauncher.script(directory: directory.path, command: ["/usr/bin/printf", "%s\\n"] + arguments)
        let file = sandbox.appending(path: "run.command")
        try script.write(to: file, atomically: true, encoding: .utf8)

        let result = try runTool("/bin/zsh", ["-f", file.path], cwd: sandbox)
        #expect(result.code == 0, "\(result.err)")
        #expect(result.out == arguments.map { $0 + "\n" }.joined())
        #expect(result.err.isEmpty)
        let entries = try FileManager.default.subpathsOfDirectory(atPath: sandbox.path).sorted()
        #expect(entries == [directory.lastPathComponent, "run.command"].sorted())
    }

    @Test func aGeneratedScriptRunsInTheRequestedDirectory() throws {
        let sandbox = try makeTempDir("script")
        defer { removeTemp(sandbox) }
        let directory = sandbox.appending(path: "dir with 'quotes' and $(x)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = sandbox.appending(path: "run.command")
        try TerminalLauncher.script(directory: directory.path, command: ["/bin/pwd", "-P"]).write(to: file, atomically: true, encoding: .utf8)
        let result = try runTool("/bin/zsh", ["-f", file.path], cwd: sandbox)
        #expect(result.code == 0)
        #expect(realPath(result.out.trimmed) == realPath(directory.path))
    }

    @Test func aMissingDirectoryStopsTheScriptBeforeTheCommand() throws {
        let sandbox = try makeTempDir("script")
        defer { removeTemp(sandbox) }
        let file = sandbox.appending(path: "run.command")
        try TerminalLauncher.script(directory: sandbox.appending(path: "gone").path, command: ["/usr/bin/touch", sandbox.appending(path: "RAN").path])
            .write(to: file, atomically: true, encoding: .utf8)
        let result = try runTool("/bin/zsh", ["-f", file.path], cwd: sandbox)
        #expect(result.code == 1)
        #expect(!FileManager.default.fileExists(atPath: sandbox.appending(path: "RAN").path))
    }

    @Test func scriptTextHasAQuotedCdAndExec() {
        let script = TerminalLauncher.script(directory: "/code/my app", command: ["forgedeck", "exec", "--product", "acme", "--", "npm", "run", "dev"])
        #expect(script.hasPrefix("#!/bin/zsh\n"))
        #expect(script.contains("cd -- '/code/my app' || exit 1\n"))
        #expect(script.contains("exec forgedeck exec --product acme -- npm run dev\n"))
    }
}

@Suite struct TerminalLauncherTests {
    private func makeLauncher(_ opener: FakeOpener, in root: URL) -> TerminalLauncher {
        TerminalLauncher(opener: opener, launchDirectory: root.appending(path: "launch", directoryHint: .isDirectory))
    }

    @Test func openFolderReportsOpenedOnlyWhenTheOpenerSucceeded() async throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let opener = FakeOpener()
        let outcome = await makeLauncher(opener, in: root).openFolder(root.path, appBundleID: terminalID)
        #expect(outcome == .opened(app: "Terminal"))
        #expect(outcome.didOpen)
        #expect(opener.opened.count == 1)
        #expect(opener.opened.first?.items.map(\.path) == [root.path])
    }

    @Test func aMissingFolderFailsWithoutACopyCommand() async throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let opener = FakeOpener()
        let missing = root.appending(path: "gone").path
        let outcome = await makeLauncher(opener, in: root).openFolder(missing, appBundleID: terminalID)
        guard case .failed(let reason, let copy) = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(reason.contains(missing))
        #expect(copy == nil)
        #expect(opener.opened.isEmpty)
        // A file is not a folder.
        try write("x", to: root.appending(path: "file.txt"))
        let file = await makeLauncher(opener, in: root).openFolder(root.appending(path: "file.txt").path, appBundleID: terminalID)
        #expect(!file.didOpen)
    }

    @Test func anAppThatIsNotInstalledFailsWithAUsableCopyCommand() async throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let folder = root.appending(path: "my project's folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let opener = FakeOpener(installed: [])
        let outcome = await makeLauncher(opener, in: root).openFolder(folder.path, appBundleID: "com.googlecode.iterm2")
        guard case .failed(let reason, let copy) = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(reason == "iTerm2 is not installed.")
        let line = try #require(copy)
        let result = try runTool("/bin/zsh", ["-f", "-c", line + " && pwd"], cwd: root)
        #expect(result.code == 0)
        #expect(realPath(result.out.trimmed) == realPath(folder.path))
        #expect(opener.opened.isEmpty)
    }

    @Test func anOpenerThatThrowsIsNeverReportedAsOpened() async throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let launcher = makeLauncher(FakeOpener(fails: true), in: root)
        let folder = await launcher.openFolder(root.path, appBundleID: terminalID)
        guard case .failed(_, let copy) = folder else { Issue.record("expected a failure, got \(folder)"); return }
        #expect(copy == TerminalLauncher.copyCommand(directory: root.path))
        let command = await launcher.run(command: ["npm", "test"], in: root.path, terminalBundleID: terminalID)
        guard case .failed(_, let commandCopy) = command else { Issue.record("expected a failure, got \(command)"); return }
        #expect(commandCopy == TerminalLauncher.copyCommand(directory: root.path, command: ["npm", "test"]))
        let link = await launcher.openURL("https://example.com")
        #expect(!link.didOpen)
    }

    @Test func aTerminalWithoutCommandFileSupportFailsWithACopyCommand() async throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let opener = FakeOpener()
        let launcher = makeLauncher(opener, in: root)
        let outcome = await launcher.run(command: ["npm", "run", "dev server"], in: root.path, terminalBundleID: ghosttyID)
        guard case .failed(let reason, let copy) = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(reason.contains("Ghostty"))
        #expect(copy == "cd -- \(ShellQuote.quote(root.path)) && npm run 'dev server'")
        #expect(opener.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: launcher.launchDirectory.path))
        // An unknown bundle id has no verified integration either.
        let unknown = await makeLauncher(FakeOpener(installed: ["com.example.term"]), in: root)
            .run(command: ["ls"], in: root.path, terminalBundleID: "com.example.term")
        #expect(!unknown.didOpen)
    }

    @Test func anEmptyCommandIsRefused() async throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let outcome = await makeLauncher(FakeOpener(), in: root).run(command: [], in: root.path, terminalBundleID: terminalID)
        #expect(outcome == .failed(reason: "The command is empty.", copyCommand: nil))
    }

    @Test func runWritesAPrivateScriptThatHoldsNoSecrets() async throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let world = SecretWorld(checkoutPath: root.path)
        let opener = FakeOpener()
        let launcher = makeLauncher(opener, in: root)
        // What the app hands a terminal: the CLI line. The secret is resolved later, in the child.
        let command = ["forgedeck", "exec", "--product", world.product.slug, "--environment", "local", "--profile", "dev", "--", "npm", "run", "dev"]
        let outcome = await launcher.run(command: command, in: root.path, terminalBundleID: terminalID)
        #expect(outcome == .opened(app: "Terminal"))

        let opened = try #require(opener.opened.first)
        let file = try #require(opened.items.first)
        #expect(file.pathExtension == "command")
        #expect(file.deletingLastPathComponent().path == launcher.launchDirectory.path)
        let fm = FileManager.default
        #expect(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o700)
        #expect(try fm.attributesOfItem(atPath: launcher.launchDirectory.path)[.posixPermissions] as? Int == 0o700)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == TerminalLauncher.script(directory: root.path, command: command))
        expectNoMarkers(text, "launch script")
        #expect(!text.contains(SecretWorld.plainMarker))
    }

    @Test func oldLaunchScriptsAreSwept() async throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let launcher = makeLauncher(FakeOpener(), in: root)
        let stale = launcher.launchDirectory.appending(path: "run-old.command")
        let keep = launcher.launchDirectory.appending(path: "notes.txt")
        try write("#!/bin/zsh\n", to: stale)
        try write("keep", to: keep)
        let twoDaysAgo = Date.now.addingTimeInterval(-2 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: keep.path)
        _ = await launcher.run(command: ["ls"], in: root.path, terminalBundleID: terminalID)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func onlyWebLinksAreOpened() async throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let opener = FakeOpener()
        let launcher = makeLauncher(opener, in: root)
        #expect(await launcher.openURL("https://example.com/admin").didOpen)
        for text in ["file:///etc/passwd", "javascript:alert(1)", "ssh://host", "not a link", "", "x-apple.systempreferences:"] {
            #expect(await launcher.openURL(text).didOpen == false, "\(text)")
        }
        #expect(opener.openedURLs.map(\.absoluteString) == ["https://example.com/admin"])
    }

    @Test func installedFiltersByWhatTheOpenerFinds() throws {
        let root = try makeTempDir("launch")
        defer { removeTemp(root) }
        let launcher = makeLauncher(FakeOpener(installed: [terminalID]), in: root)
        #expect(launcher.installed(KnownApps.terminals).map(\.bundleID) == [terminalID])
        #expect(launcher.installed(KnownApps.editors).isEmpty)
        #expect(KnownApps.descriptor(bundleID: terminalID)?.runsCommandFile == true)
        #expect(KnownApps.descriptor(bundleID: ghosttyID)?.runsCommandFile == false)
        #expect(KnownApps.descriptor(bundleID: "com.example.nope") == nil)
    }
}
