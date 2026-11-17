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
        + "asks what is deployed or broken, asks how to run or set up a product, asks whether leads or sales come in, or needs a secret or environment variable."

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

        ## Set up production or another environment

        You cannot add an environment yourself; you propose one and the person approves it in \(Brand.name).

        1. Find where the product runs from its own files: deploy workflows (`.github/workflows`, look for `environment:`), \
        `vercel.json`, `netlify.toml`, `fly.toml`, `CNAME`, Docker or server configs, a WordPress plugin's `Plugin URI`, the README. \
        Ask the person for anything you cannot find. Never guess a domain.
        2. Look for a URL that names the running release (a `forgedeck-release.json`, `/version`, `/health` with a commit, \
        or for a WordPress plugin its served `readme.txt` with a `Stable tag`) \
        and a health URL. Check them with a plain GET. If none exists and the person wants one, add a small file or route that \
        returns `{"commit_sha": "…", "version": "…"}` from the deploy, in a separate change they approve.
        3. Write `.forgedeck/environments.json` in the product's folder:
           `{"environments": [{"tier": "production", "name": "Production", "domains": ["example.com"], \
        "versionURL": "https://example.com/forgedeck-release.json", "healthURL": "https://example.com/health", \
        "github": "production", "note": "which files told you"}]}`
           Tiers: production, staging, development, preview, custom. Domains are hosts only. URLs are https.
        4. Run `\(tool) env check <slug>` and fix every problem it prints.
        5. Tell the person to open the product in \(Brand.name) and press Review… on Proposed environments. Nothing is added before that.

        ## Set up how a product runs

        When the person asks how to run, start, launch, or test a product, or to set up its Play button:

        1. Work out what it is and how it runs from its own files (README, package scripts, Docker or compose files, Makefile, \
        Procfile, framework config). Install what it needs and try the commands; stop what you started. Ask before changing project files.
        2. Write `.forgedeck/run.json` in its folder, best first:
           `{"commands": [{"label": "Start Dev Server", "kind": "web", "steps": [["npm", "install"], ["npm", "run", "dev"]], \
        "url": "http://localhost:5173", "note": "package.json dev script"}, {"label": "Run Tests", "steps": [["npm", "test"]]}]}`
           kind web, desktop, mobile, or site goes on Play; leave it out for tests and builds. Each step is a program and its \
        arguments: no shell strings, `&&`, or pipes. url is a page on this Mac. Nothing that deploys, publishes, or pushes.
        3. Run `\(tool) run check <slug>` and fix every problem it prints.
        4. Tell the person to choose Review Run Setup… in the Play menu in \(Brand.name). Nothing is saved before that.

        ## Leads, signups, and purchases

        When the person asks whether leads, sales, or signups reach \(Brand.name), or to set that up:

        1. Run `\(tool) leads <slug>`. It shows each metrics source, when it last answered, counts, and the newest lead.
        2. If there is no source, or it misses something: look first, change nothing. Find what the product collects (forms, signups, \
        orders, subscriptions, bookings) and where each is stored. Tell the person in a short table and ask which ones \(Brand.name) \
        should see, and whether to set up the check now. Wait for the answer.
        3. To set it up, the person chooses Set Up Leads… on the product in \(Brand.name): it makes the token in the Keychain and \
        starts an agent with the token's hash and the companion contract. Never ask for the token itself.
        4. The metrics source is proposed in `.forgedeck/environments.json` with "metricsURL" and "metricsToken" (a variable name), \
        checked with `\(tool) env check <slug>`, and added when the person presses Review….

        ## Suggest skills for a product

        When the person asks which skills, plugins, or add-ons would help with a product:

        1. Run `\(tool) skills <slug>` to see what is already chosen. Look at the product and its recent work, then find skills \
        that fit (GitHub skills repositories, skills.sh, `claude plugin list --available --json`). Read each one before suggesting it.
        2. Write `.forgedeck/skills.json`: `{"skills": [{"name": "skill-folder", "repo": "owner/repo", "why": "…"}, \
        {"name": "plugin", "plugin": "plugin", "marketplace": "owner/repo", "includes": ["skills", "hooks"]}]}`. Install nothing.
        3. Run `\(tool) skills check <slug>`, then tell the person to press Install in \(Brand.name) › the product › Development › Skills.

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
