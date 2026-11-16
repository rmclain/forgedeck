import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ToolboxTests {
    @Test func everyToolIsDescribedAndUnique() {
        let ids = Toolbox.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        for spec in Toolbox.catalog {
            #expect(!spec.summary.isEmpty && !spec.why.isEmpty, "\(spec.id)")
            #expect(spec.homepage.hasPrefix("https://"), "\(spec.id)")
            for option in spec.install { #expect(["brew", "npx", "pipx", "uv"].contains(option.command[0]), "\(spec.id)") }
            for action in spec.actions {
                #expect(!action.arguments.contains { $0.contains(";") || $0.contains("|") || $0.contains("&&") || $0.contains("$(") }, "\(action.id)")
                #expect(!action.note.isEmpty, "\(action.id)")
            }
        }
    }

    @Test func npxToolsArePinned() {
        for spec in Toolbox.catalog {
            guard let package = spec.npxPackage else { continue }
            let version = package.split(separator: "@").last.map(String.init) ?? ""
            #expect(version.first?.isNumber == true, "\(package) is not pinned to a version")
        }
    }

    @Test func actionsThatWriteSayThatTheyWrite() {
        let writers = Toolbox.catalog.flatMap(\.actions).filter { $0.safety >= .localWrite }
        #expect(writers.map(\.id) == ["graphify-update"])
        #expect(writers.allSatisfy { $0.note.lowercased().contains("writes") })
    }

    @Test func aPathWithShellCharactersStaysOneArgument() throws {
        let hostile = try makeTempDir("it's $(touch pwned); `x` & y")
        defer { removeTemp(hostile) }
        guard let rg = Toolbox.spec("ripgrep"), Toolbox.status(rg).isUsable, let action = rg.actions.first else { return }
        let (_, arguments, directory) = try Toolbox.command(action, of: rg, checkout: hostile.path)
        #expect(arguments.last == hostile.path)
        #expect(arguments.filter { $0.contains("pwned") }.count == 1)
        #expect(directory?.path == hostile.path)
    }

    @Test func missingInputsAreExplained() {
        let graphify = Toolbox.spec("graphify")!
        let hubs = graphify.actions.first { $0.id == "graphify-hubs" }!
        #expect(throws: Toolbox.Unavailable.noCheckout) { _ = try Toolbox.command(hubs, of: graphify, checkout: nil) }
        #expect(throws: Toolbox.Unavailable.needsFile("graphify-out/graph.json")) { _ = try Toolbox.command(hubs, of: graphify, checkout: "/tmp") }
        let fake = ToolSpec(id: "nope", name: "Nope", category: .git, summary: "s", why: "w", homepage: "https://example.com",
                            executable: "forgedeck-no-such-tool", npxPackage: nil, install: [], actions: [])
        #expect(Toolbox.status(fake) == .missing)
        #expect(throws: Toolbox.Unavailable.notInstalled("Nope")) {
            _ = try Toolbox.command(ToolAction(id: "x", label: "x", arguments: [], note: "n"), of: fake, checkout: "/tmp")
        }
        #expect(Toolbox.status(Toolbox.spec("serena")!) == .external)
    }

    @Test func outputIsRedactedAndUncolored() async throws {
        let runner = FakeRunner { _ in ProcessResult(exitCode: 0, stdout: "\u{1B}[31mleak ghp_abcdefghijklmnopqrstuvwxyz0123\u{1B}[0m") }
        guard let rg = Toolbox.spec("ripgrep"), Toolbox.status(rg).isUsable else { return }
        let result = try await Toolbox.run(rg.actions[0], of: rg, checkout: FileManager.default.temporaryDirectory.path, runner: runner)
        #expect(!result.stdout.contains("\u{1B}"))
        #expect(!result.stdout.contains("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        #expect(runner.requests.first?.environment?["NO_COLOR"] == "1")
    }

    @Test func installedToolsBecomeAgentHints() {
        let hints = Toolbox.agentHints()
        if case .installed = Toolbox.status(Toolbox.spec("ripgrep")!) { #expect(hints.contains { $0.contains("rg") }) }
        #expect(!hints.contains { $0.contains("ast-grep") } || ExecutableLocator.find("ast-grep") != nil)
    }
}

/// Real runs of the tools installed on this Mac. FORGEDECK_LIVE_TOOLS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FORGEDECK_LIVE_TOOLS"] == "1")) struct LiveToolbox {
    @Test func ripgrepFindsATodoInARealRepository() async throws {
        let directory = try makeTempDir("tools repo")
        defer { removeTemp(directory) }
        let repo = try TestRepo.create(at: directory)
        _ = try repo.commit(file: "main.swift", content: "let x = 1 // TODO: tidy this\n", message: "todo")
        let rg = Toolbox.spec("ripgrep")!
        let result = try await Toolbox.run(rg.actions[0], of: rg, checkout: directory.path)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("TODO: tidy this"))
    }

    @Test func repomixReportsTokensByFolderAndWritesNothing() async throws {
        let directory = try makeTempDir("tools repo")
        defer { removeTemp(directory) }
        let repo = try TestRepo.create(at: directory)
        let body = (0..<300).map { "func work\($0)(value: Int) -> Int { return value * \($0) + 1 }" }.joined(separator: "\n")
        try FileManager.default.createDirectory(at: directory.appending(path: "Sources"), withIntermediateDirectories: true)
        _ = try repo.commit(file: "Sources/Work.swift", content: body, message: "work")
        let spec = Toolbox.spec("repomix")!
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let result = try await Toolbox.run(spec.actions[0], of: spec, checkout: directory.path)
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stdout.contains("Sources"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)
    }
}
