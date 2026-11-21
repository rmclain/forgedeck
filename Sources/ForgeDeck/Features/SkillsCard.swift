import ForgeDeckKit
import SwiftUI

// Skills for a product: the agent suggests skills in .forgedeck/skills.json. A skill from a GitHub repository is added
// with the Toolbox's sheet; a Claude Code plugin with `claude plugin install` after a confirmation. Active ones are
// named in the agent's prompt.

extension AppModel {
    func skillSuggestions(_ product: Product) -> [SkillSuggestion] {
        let entries = product.isDemo ? DemoFixtures.skillSuggestions(for: product) : (skillFiles[product.id]?.entries ?? [])
        return SkillSuggestions.suggestions(for: product, entries: entries)
    }

    /// Reads `claude plugin list --json`. Without Claude Code the set stays empty.
    func loadInstalledPlugins() async {
        guard let claude = ExecutableLocator.find("claude") else { installedPlugins = []; return }
        let result = try? await SystemProcessRunner().run(ProcessRequest(executable: claude, arguments: SkillSuggestions.listArguments,
                                                                         workingDirectory: agentHomeURL, timeout: 30))
        installedPlugins = result.map { SkillSuggestions.installedPlugins(fromListJSON: Data($0.stdout.utf8)) } ?? []
    }

    /// Installed: a skill folder in an agent's skills folder, or an enabled Claude Code plugin.
    func isInstalled(_ name: String, plugin: Bool) -> Bool {
        _ = skillsVersion
        return plugin ? installedPlugins?.contains(name) == true : SkillSuggestions.installedSkills(home: agentHomeURL).contains(name)
    }

    /// Starts the agent with the suggestion prompt. What it writes shows up in the Skills card within a second.
    func suggestSkills(_ product: Product) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. Its suggestions are a fixture.", isError: true) }
        guard let checkout = checkout(for: product) else { return }
        Task {
            if installedPlugins == nil { await loadInstalledPlugins() }
            let prompt = SkillSuggestions.prompt(for: product, checkout: checkout, cli: cliCommand,
                                                 installedSkills: Array(SkillSuggestions.installedSkills(home: agentHomeURL)),
                                                 installedPlugins: installedPlugins ?? [])
            startSetupAgent(product, checkout: checkout, prompt: prompt, title: "Suggest Skills", audit: "skills.suggest")
        }
    }

    /// A skill: chosen for the product, then the usual sheet fetches its repository to add it.
    /// A plugin: a confirmation, then `claude plugin install`.
    func installSuggested(_ entry: ProposedSkill, for product: Product) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. Nothing installs.", isError: true) }
        if !entry.isPlugin, let repo = entry.repo {
            choose(entry, for: product)
            return lookUpSkills("npx skills add \(repo) --skill \(entry.name)")
        }
        guard ExecutableLocator.find("claude") != nil else { return show("Claude Code is not installed, so its plugins cannot be.", isError: true) }
        let suggestion = SkillSuggestions.check(entry)
        var checks = [ConfirmRequest.Check(label: "From", meta: entry.marketplace ?? "", ok: true)]
        if let includes = entry.includes, !includes.isEmpty {
            checks.append(.init(label: "Adds", meta: includes.joined(separator: ", "), ok: !suggestion.runsCode))
        }
        sheet = .confirm(ConfirmRequest(
            title: "Install \(entry.plugin ?? entry.name)?",
            message: "Claude Code installs this plugin for every session on this Mac."
                + (suggestion.runsCode ? " It includes hooks or an MCP server, which run as you in every session." : ""),
            checks: checks,
            footnote: entry.link.map { "Read it first: \($0)" } ?? "",
            confirmLabel: "Install", icon: .sparkle,
            action: { [weak self] in await self?.installPlugin(entry, for: product) }))
    }

    private func installPlugin(_ entry: ProposedSkill, for product: Product) async {
        guard let claude = ExecutableLocator.find("claude"), let marketplace = entry.marketplace else { return }
        let plugin = entry.plugin ?? entry.name
        installingSkills.insert(entry.name)
        defer { installingSkills.remove(entry.name) }
        let arguments = SkillSuggestions.installArguments(plugin: plugin, marketplace: marketplace)
        // stdin is empty, so a plugin that needs a confirmation fails here instead of waiting.
        let result = try? await SystemProcessRunner().run(ProcessRequest(executable: claude, arguments: arguments, workingDirectory: agentHomeURL,
                                                                         timeout: 300, stdin: Data()))
        guard let result, result.ok else {
            let text = Toolbox.stripANSI((result?.stderr ?? "") + "\n" + (result?.stdout ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = text.split(separator: "\n").first.map(String.init) ?? "it did not finish"
            record("skill.install", product: product, detail: "plugin=\(plugin) marketplace=\(marketplace)", outcome: "failed")
            copy(ShellQuote.join(["claude"] + arguments), message: "")
            return show("Could not install \(plugin): \(reason). The install command is on the clipboard, to run in a terminal.", isError: true)
        }
        record("skill.install", product: product, detail: "plugin=\(plugin) marketplace=\(marketplace)")
        choose(entry, for: product)
        skillsChanged()
        await loadInstalledPlugins()
        show(staleAgentSessions(product).isEmpty ? "Installed \(plugin). Claude Code sessions started from now on have it."
                                                 : "Installed \(plugin). Restart the agent so it loads it: Restart Agent on the Skills card.")
    }

    /// Adds it to the product's skills, active.
    func choose(_ entry: ProposedSkill, for product: Product) {
        update(product.id) { product in
            var skills = (product.agentSkills ?? []).filter { $0.id != entry.name }
            skills.append(entry.skill)
            product.agentSkills = skills
        }
        skillsChangedAt[product.id] = .now
        record("skill.choose", product: product, detail: "skill=\(entry.name)")
    }

    /// Skills installed on this Mac reach every agent session, so every product with one running is marked.
    func skillsChanged() {
        let now = Date.now
        for id in Set(terminals.running.filter { $0.launch.kind == .agent }.compactMap(\.productID)) { skillsChangedAt[id] = now }
    }

    /// The product's agent sessions in the dock that started before its skills last changed.
    func staleAgentSessions(_ product: Product) -> [TerminalSession] {
        guard let changed = skillsChangedAt[product.id] else { return [] }
        return terminals.sessions(for: product.id).filter { $0.launch.kind == .agent && $0.startedAt < changed }
    }

    /// Closes the product's agent sessions that started before its skills changed and starts the agent again,
    /// with a fresh context file that names the active skills. Whatever the old session was doing stops.
    func restartAgent(_ product: Product) {
        guard let current = self.product(product.id), !current.isDemo else { return }
        let stale = staleAgentSessions(current)
        let checkout = stale.last.flatMap { session in current.checkouts.first { $0.id == session.checkoutID } }
        for session in stale { terminals.close(session) }
        skillsChangedAt[current.id] = nil
        record("agent.restart", product: current, detail: "agent=\(portfolio.agentProgram(for: current)) closed=\(stale.count) reason=skills")
        openAgent(current, checkout: checkout)
    }

    func setSkill(_ id: String, active: Bool, in product: Product) {
        update(product.id) { product in
            guard let index = product.agentSkills?.firstIndex(where: { $0.id == id }) else { return }
            product.agentSkills?[index].isActive = active
        }
    }

    /// Turns a suggestion down. Kept, so the agent does not suggest it again.
    func dismissSkill(_ entry: ProposedSkill, in product: Product) {
        update(product.id) { product in
            var skills = (product.agentSkills ?? []).filter { $0.id != entry.name }
            var skill = entry.skill
            skill.isActive = false
            skill.isDismissed = true
            skills.append(skill)
            product.agentSkills = skills
        }
    }

    /// Takes a skill off this product. What is installed stays installed.
    func removeSkill(_ id: String, from product: Product) {
        update(product.id) { product in product.agentSkills?.removeAll { $0.id == id } }
        record("skill.remove", product: product, detail: "skill=\(id)")
    }
}

/// Skills chosen for this product and the agent's suggestions, on the Development tab.
struct SkillsCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let chosen = (product.agentSkills ?? []).filter { !$0.isDismissed }
        let suggestions = model.skillSuggestions(product)
        let installed = installedChoices(excluding: Set(chosen.map(\.id)))
        let errors = model.skillFiles[product.id]?.errors ?? []
        let agent = AgentCatalog.name(model.portfolio.agentProgram(for: product))
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Skills", subtitle: "Active ones are named in the agent's prompt when it starts here") {
                if product.isDemo { DemoBadge() }
                Menu("Add Installed") {
                    ForEach(installed, id: \.name) { item in
                        Button(item.name) { model.choose(item, for: product) }
                    }
                }
                .menuStyle(.button).buttonStyle(.kit(.secondary, compact: true)).fixedSize()
                .disabled(installed.isEmpty || product.isDemo)
                .help("Choose a skill or plugin that is already installed on this Mac")
                Button("Suggest with \(agent)…") { model.suggestSkills(product) }
                    .buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo || !product.hasLocal)
                    .help("\(agent) looks at this product and suggests skills. Nothing installs until you press Install.")
            }
            .padding(Space.lg)
            let stale = model.staleAgentSessions(product)
            if !stale.isEmpty { restartRow(stale.count, agent: agent) }
            if chosen.isEmpty && suggestions.isEmpty {
                Text("No skills yet. Suggest with \(agent) looks at what this product is and the work you do in it, then lists skills worth adding.")
                    .kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
            }
            ForEach(chosen) { skill in chosenRow(skill) }
            ForEach(suggestions) { suggestion in suggestionRow(suggestion) }
            ForEach(errors, id: \.self) { error in
                Text(error).kitType(.meta, Ink.warn).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineAbove()
            }
        }
        .card()
        .task(id: product.id) {
            await model.reloadAgentFiles(product)
            if model.installedPlugins == nil { await model.loadInstalledPlugins() }
        }
    }

    /// Skills load when an agent starts, so a session that was already running needs a restart to get them.
    private func restartRow(_ count: Int, agent: String) -> some View {
        HStack(spacing: Space.md) {
            ToneIcon(icon: .sync, tone: .accent, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "An agent session started before these skills" : "\(count) agent sessions started before these skills").kitType(.labelMedium)
                Text("Skills and plugins load when the agent starts. Restart closes \(count == 1 ? "that session" : "those sessions") and opens \(agent) again with the new skills and a fresh context.")
                    .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            Button("Restart Agent") { model.restartAgent(product) }
                .buttonStyle(.kit(.secondary, compact: true)).fixedSize()
                .help("Closes the running \(agent) session in the dock and starts a new one that loads the new skills")
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
        .hairlineAbove()
    }

    private func installedChoices(excluding chosen: Set<String>) -> [ProposedSkill] {
        _ = model.skillsVersion
        let skills = SkillSuggestions.installedSkills(home: model.agentHomeURL).subtracting(chosen).sorted()
            .map { ProposedSkill(name: $0, repo: nil) }
        let plugins = (model.installedPlugins ?? []).subtracting(chosen).sorted()
            .map { ProposedSkill(name: $0, plugin: $0, marketplace: "installed") }
        return skills + plugins
    }

    private func chosenRow(_ skill: AgentSkill) -> some View {
        let missing = (product.isDemo || model.installedPlugins != nil) && !model.isInstalled(skill.id, plugin: skill.isPlugin)
        let entry = ProposedSkill(name: skill.id, repo: skill.repo, plugin: skill.isPlugin ? skill.id : nil, marketplace: skill.marketplace, why: skill.why)
        return HStack(spacing: Space.md) {
            label(skill.id, why: skill.why) {
                if skill.isPlugin { TagBadge("Plugin") }
                if missing { TagBadge("Not installed", tone: .warn) }
            }
            Spacer(minLength: Space.sm)
            if missing, skill.repo != nil || (skill.marketplace ?? "installed") != "installed" { installButton(entry).disabled(product.isDemo) }
            Toggle("Active", isOn: Binding(get: { skill.isActive }, set: { model.setSkill(skill.id, active: $0, in: product) }))
                .toggleStyle(.checkbox).font(KitType.label.font)
                .help("Named in the agent's prompt when it starts in \(product.name)")
            IconButton(.trash, label: "Remove \(skill.id) from \(product.name)") { model.removeSkill(skill.id, from: product) }
                .help("Takes it off \(product.name). It stays installed.")
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
        .hairlineAbove()
    }

    private func suggestionRow(_ suggestion: SkillSuggestion) -> some View {
        let entry = suggestion.entry
        let installed = model.isInstalled(entry.plugin ?? entry.name, plugin: entry.isPlugin)
        return HStack(spacing: Space.md) {
            label(entry.name, why: suggestion.isValid ? [entry.why ?? "", entry.origin].filter { !$0.isEmpty }.joined(separator: " · ")
                                                       : suggestion.problems.joined(separator: " "), problem: !suggestion.isValid) {
                TagBadge("Suggested", tone: .accent)
                if entry.isPlugin { TagBadge("Plugin") }
                if suggestion.runsCode { TagBadge("Runs code", tone: .warn).help("Includes hooks or an MCP server, which run as you in every Claude Code session") }
            }
            Spacer(minLength: Space.sm)
            if installed {
                Button("Use") { model.choose(entry, for: product) }.buttonStyle(.kit(.secondary, compact: true))
                    .disabled(product.isDemo).help("Already installed. Adds it to \(product.name), active.")
            } else {
                installButton(entry).disabled(!suggestion.isValid || product.isDemo)
            }
            IconButton(.xmark, label: "Not for \(product.name)") { model.dismissSkill(entry, in: product) }
                .disabled(product.isDemo).help("Turn it down. It is not suggested again.")
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
        .hairlineAbove()
    }

    private func installButton(_ entry: ProposedSkill) -> some View {
        let busy = model.installingSkills.contains(entry.name) || (entry.repo != nil && model.fetchingSkills == entry.repo)
        return Button(busy ? "Installing…" : "Install…") { model.installSuggested(entry, for: product) }
            .buttonStyle(.kit(.secondary, compact: true)).disabled(busy)
            .help(entry.isPlugin ? "Installs the plugin with Claude Code, after you confirm" : "Downloads \(entry.repo ?? "the repository") and lets you pick where to add it")
    }

    private func label(_ name: String, why: String, problem: Bool = false, @ViewBuilder badges: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.xs) {
                Text(name).kitType(.labelMedium)
                badges()
            }
            if !why.isEmpty { Text(why).kitType(.meta, problem ? Ink.warn : Ink.text3).lineLimit(2) }
        }
    }
}
