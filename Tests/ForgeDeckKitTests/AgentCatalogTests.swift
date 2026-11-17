import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct AgentCatalogTests {
    let folders = ["/code/it's api"]
    let context = ["/Users/me/Library/Application Support/ForgeDeck/context/app"]
    let pointer = "Read /ctx/app/CONTEXT.md first."

    func command(_ program: String, message: String? = nil, model: String? = nil) -> [String] {
        AgentCatalog.command(program: URL(fileURLWithPath: "/bin/\(program)"), folders: folders, contextFolders: context, pointer: pointer, message: message, model: model, workingDirectory: "/code/app")
    }

    @Test func everyAgentGetsFoldersModelAndFirstMessageItsOwnWay() {
        #expect(command("claude", message: "Fix it.", model: "opus") ==
                ["/bin/claude", "--settings", AgentCatalog.readSettings(context)!, "--add-dir", "/code/it's api", "--model", "opus", "--append-system-prompt", pointer, "Fix it."])
        #expect(command("gemini", message: "Fix it.", model: "gemini-x") ==
                ["/bin/gemini", "--include-directories", context[0], "--include-directories", "/code/it's api", "--model", "gemini-x", "--prompt-interactive", "\(pointer) Fix it."])
        #expect(command("agy", model: "gemini-3.8-flash-low") ==
                ["/bin/agy", "--add-dir", context[0], "--add-dir", "/code/it's api", "--model", "gemini-3.8-flash-low", "--prompt-interactive", pointer])
        #expect(command("codex") == ["/bin/codex", pointer])
        #expect(command("opencode", model: "anthropic/claude") == ["/bin/opencode", "--model", "anthropic/claude", "--prompt", pointer, "/code/app"])
        #expect(command("unknown-agent") == ["/bin/unknown-agent"])
    }

    /// Claude Code asks to trust every --add-dir folder it has not opened as a project. The context folder is
    /// never opened as one, so it gets a read-only allow rule instead and the session starts without a prompt.
    @Test func claudeReadsTheContextFolderWithoutATrustPrompt() throws {
        let argv = command("claude")
        #expect(!argv.contains(context[0]))
        let settings = try #require(AgentCatalog.readSettings(context + ["/packs/"]))
        let json = try #require(JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: [String: [String]]])
        #expect(json == ["permissions": ["allow": ["Read(//Users/me/Library/Application Support/ForgeDeck/context/app/**)", "Read(//packs/**)"]]])
        #expect(!settings.contains("Edit") && !settings.contains("Write") && !settings.contains("Bash"))
        #expect(AgentCatalog.readSettings([]) == nil && AgentCatalog.readSettings(["relative"]) == nil)
        let bare = AgentCatalog.command(program: URL(fileURLWithPath: "/bin/claude"), folders: [], pointer: nil, message: nil, model: nil, workingDirectory: "/w")
        #expect(bare == ["/bin/claude"])
    }

    @Test func aBlankModelUsesTheAgentsDefault() {
        #expect(!command("claude", model: "  ").contains("--model"))
        var settings = AppSettings()
        settings.agentModels = ["agy": "gemini-4-argon-high", "claude": " "]
        #expect(settings.model(for: "agy") == "gemini-4-argon-high")
        #expect(settings.model(for: "claude") == nil)
        #expect(settings.model(for: "gemini") == nil)
    }

    @Test func settingsWrittenBeforeModelsExistedStillLoad() throws {
        var json = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(AppSettings())) as! [String: Any]
        json.removeValue(forKey: "agentModels")
        json.removeValue(forKey: "terminalPlacement")
        let settings = try JSONCoding.decoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(settings.agentModels == nil)
    }

    @Test func modelListsAreReadFromTheAgentWhenItHasOne() async {
        let runner = FakeRunner { _ in ProcessResult(exitCode: 0, stdout: "Fetching available models...\ngemini-4-argon-high\tGemini 4 Argon (High)\nclaude-opus-5-5-low\tClaude Opus 5.5 (Low)\n") }
        let agy = AgentCatalog.spec("agy")!
        if ExecutableLocator.find("agy") != nil {
            let models = await AgentCatalog.models(agy, runner: runner)
            #expect(models.map(\.id) == ["gemini-4-argon-high", "claude-opus-5-5-low"])
        }
        let claude = await AgentCatalog.models(AgentCatalog.spec("claude")!, runner: runner)
        #expect(claude.map(\.id) == ["opus", "sonnet", "haiku"])
    }

    @Test func theCatalogKnowsFiveAgents() {
        #expect(AgentPrograms.known == ["claude", "codex", "opencode", "gemini", "agy"])
        #expect(AgentCatalog.name("agy") == "Antigravity (agy)")
        #expect(AgentCatalog.name("gemini") == "Gemini CLI")
    }
}
