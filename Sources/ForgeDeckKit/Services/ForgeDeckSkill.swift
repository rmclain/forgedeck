import Foundation

// The `forgedeck` agent skill. An agent loads only its description at the start of a session; the body is read
// when a task needs it. The body sends the agent to the CLI, so it is never out of date: `list` finds the product,
// `context --write` prints the context file, and the task decides what else to read.

public enum ForgeDeckSkill {
    public static let name = "forgedeck"
    /// Marks a copy ForgeDeck wrote, so it never replaces or removes a skill of the same name it did not write.
    public static let marker = "<!-- Written by \(Brand.name). It rewrites this file; edits are lost. -->"

    public static let description = "Find a ForgeDeck product and the context a task needs: its folder, CONTEXT.md, related products, "
        + "what is deployed, CI failures, links, and variable names. Use when the person names a product or project, asks to work on one, "
        + "asks what is deployed or broken, or needs a secret or environment variable."

    /// The SKILL.md text. `cli` is the command to run: the installed link or the app's own binary.
    public static func text(cli: String) -> String {
        let tool = cli.contains(" ") ? "\"\(cli)\"" : cli
        return """
        ---
        name: \(name)
        description: \(description)
        ---
        \(marker)

        # ForgeDeck

        ForgeDeck tracks the products on this Mac. `\(tool)` is its command line. Every command below only reads, except `exec`, \
        which runs one program with granted variables. Read only what the task needs, when it needs it.

        ## 1. Find the product

        Run `\(tool) list`. Match the person's words to a name or slug. Skip rows marked (demo). If two fit, ask.

        ## 2. Read what the task needs

        | The task | Read |
        |---|---|
        | Change code, fix a bug, review, explain | `\(tool) context <slug> --write` prints the context file's path. Read that file, then `cd` into the folder it names. |
        | What is deployed, is it up, what changed | `\(tool) status <slug> --json` |
        | CI is failing | `\(tool) ci <slug> --brief` |
        | Dashboards, admin, docs links | `\(tool) links <slug>` |
        | Needs a secret or environment variable | The Variables section of the context file. Run the program with the `\(tool) exec` line it shows. Values are never printed. |
        | Touches another product | The context file's related products. Read their real files; change them only when asked. |

        Do not read the context file for a question that `status`, `ci`, or `links` answers.

        ## Rules

        - One product per task. Never change two products unless the person asks for exactly that.
        - `exec` runs no shell: `$NAME` in an argument stays literal. The program reads the value from its environment.
        - Production secrets need Touch ID at the Mac. If the person is not at the Mac, say so and stop.
        - Never deploy, push to a shared branch, publish, or change remote or production data unless the person asks.

        """
    }

    /// Writes `<skills>/forgedeck/SKILL.md`. Refuses to replace a folder of that name that ForgeDeck did not write.
    @discardableResult
    public static func install(in skills: URL, cli: String) throws -> Bool {
        let folder = skills.appending(path: name, directoryHint: .isDirectory)
        let file = folder.appending(path: "SKILL.md")
        if FileManager.default.fileExists(atPath: folder.path), !isOurs(file) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folder.path,
                NSLocalizedDescriptionKey: "\(folder.path) holds a skill \(Brand.name) did not write. Rename or remove it first."])
        }
        let data = Data(text(cli: cli).utf8)
        if (try? Data(contentsOf: file)) == data { return false }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return true
    }

    /// Removes the skill only when ForgeDeck wrote it.
    public static func remove(from skills: URL) throws {
        let folder = skills.appending(path: name, directoryHint: .isDirectory)
        guard isOurs(folder.appending(path: "SKILL.md")) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public static func isInstalled(in skills: URL) -> Bool { isOurs(skills.appending(path: "\(name)/SKILL.md")) }

    static func isOurs(_ file: URL) -> Bool {
        (try? String(contentsOf: file, encoding: .utf8))?.contains(marker) == true
    }

    /// Claude Code's own skills folder, read by every Claude Code session on this Mac.
    public static var claudeSkills: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills", directoryHint: .isDirectory)
    }
}
