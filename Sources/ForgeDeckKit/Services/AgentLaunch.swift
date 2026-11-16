import Foundation

// The AI coding agents ForgeDeck can start, and how each one takes folders, a model, and a first
// message. Every launch is an argument array: no shell parses any of it.

public struct AgentSpec: Sendable, Hashable, Identifiable {
    public var id: String { program }
    /// The executable name.
    public var program: String
    public var name: String
    /// Flag that adds a readable folder, repeated per folder. nil when the agent has none.
    public var addFolderFlag: String?
    /// Flag that sets the model. nil when unsupported.
    public var modelFlag: String?
    /// How a first message is passed while staying interactive.
    public enum FirstMessage: Sendable, Hashable { case positional, flag(String) }
    public var firstMessage: FirstMessage
    /// A flag for text added to the system prompt, kept apart from the first message.
    public var systemPromptFlag: String?
    /// The agent takes its working folder as an argument instead of the current directory.
    public var takesDirectoryArgument = false
    /// Models offered in Settings when the agent cannot list its own.
    public var suggestedModels: [String] = []
    /// A command that prints the available models, one `id<TAB>name` per line.
    public var listModels: [String]?
}

public enum AgentCatalog {
    public static let all: [AgentSpec] = [
        AgentSpec(program: "claude", name: "Claude Code", addFolderFlag: "--add-dir", modelFlag: "--model", firstMessage: .positional,
                  systemPromptFlag: "--append-system-prompt", suggestedModels: ["opus", "sonnet", "haiku"]),
        AgentSpec(program: "codex", name: "Codex", addFolderFlag: nil, modelFlag: "--model", firstMessage: .positional),
        AgentSpec(program: "opencode", name: "OpenCode", addFolderFlag: nil, modelFlag: "--model", firstMessage: .flag("--prompt"),
                  takesDirectoryArgument: true),
        AgentSpec(program: "gemini", name: "Gemini CLI", addFolderFlag: "--include-directories", modelFlag: "--model",
                  firstMessage: .flag("--prompt-interactive")),
        AgentSpec(program: "agy", name: "Antigravity (agy)", addFolderFlag: "--add-dir", modelFlag: "--model",
                  firstMessage: .flag("--prompt-interactive"), listModels: ["models"]),
    ]

    public static func spec(_ program: String) -> AgentSpec? { all.first { $0.program == program } }
    public static func name(_ program: String) -> String { spec(program)?.name ?? program }
    public static func installed() -> [AgentSpec] { all.filter { ExecutableLocator.find($0.program) != nil } }

    /// The agent's command line.
    /// - folders: readable folders beyond the working directory (context, packs, related checkouts).
    /// - pointer: one line about CONTEXT.md. A system-prompt flag carries it where the agent has one;
    ///   otherwise it leads the first message.
    /// - message: what the agent should do first, if anything.
    public static func command(program: URL, folders: [String], pointer: String?, message: String?, model: String?, workingDirectory: String) -> [String] {
        let name = program.lastPathComponent
        guard let spec = spec(name) else { return [program.path] }
        var argv = [program.path]
        if let flag = spec.addFolderFlag { argv += folders.flatMap { [flag, $0] } }
        if let flag = spec.modelFlag, let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty { argv += [flag, model] }
        var first = message
        if let pointer, !pointer.isEmpty {
            if let flag = spec.systemPromptFlag { argv += [flag, pointer] } else { first = [pointer, message].compactMap { $0 }.joined(separator: " ") }
        }
        if let first, !first.isEmpty {
            switch spec.firstMessage {
            case .positional: argv.append(first)
            case .flag(let flag): argv += [flag, first]
            }
        }
        if spec.takesDirectoryArgument { argv.append(workingDirectory) }
        return argv
    }

    /// Models the agent offers. Reads the agent's own list when it has one, else the suggestions.
    public static func models(_ spec: AgentSpec, runner: any ProcessRunning = SystemProcessRunner()) async -> [(id: String, name: String)] {
        if let arguments = spec.listModels, let program = ExecutableLocator.find(spec.program),
           let result = try? await runner.run(ProcessRequest(executable: program, arguments: arguments, timeout: 20)), result.ok {
            let parsed = result.stdout.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") else { return nil }
                return (parts[0], parts[1])
            }
            if !parsed.isEmpty { return parsed.map { (id: $0.0, name: $0.1) } }
        }
        return spec.suggestedModels.map { (id: $0, name: $0) }
    }
}
