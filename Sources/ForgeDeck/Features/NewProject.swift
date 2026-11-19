import AppKit
import ForgeDeckKit
import SwiftUI

// New Project: from an idea to a registered, agent-ready product. ForgeDeck makes the folder, the Git repository, and
// the product record; a starter's generator runs from a fixed argument list in a terminal; the agent plans in
// .forgedeck/blueprint.json and builds only after the person approves the plan here.

extension AppModel {
    /// The blueprint to show: the file the agent wrote, or a labeled fixture for a demo product.
    func blueprint(_ product: Product) -> BlueprintFile? {
        product.isDemo ? DemoFixtures.blueprint(for: product) : blueprintFiles[product.id]
    }

    /// Where new projects go unless the person picks another folder: the last one used, or a usual code folder.
    var defaultProjectParent: String {
        if let saved = UserDefaults.standard.string(forKey: "genesis.parent"), FileManager.default.fileExists(atPath: saved) { return saved }
        let home = NSHomeDirectory()
        for name in ["Developer", "Projects", "Code", "code", "src", "dev"] {
            let path = (home as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return path }
        }
        return home
    }

    /// The agent session running in the product's folder in a built-in terminal.
    func agentSession(_ product: Product) -> TerminalSession? {
        terminals.sessions(for: product.id).last { $0.launch.kind == .agent }
    }

    /// True while an agent works for the product here or in an external terminal that ForgeDeck still watches.
    func isAgentWorking(_ product: Product) -> Bool {
        agentSession(product) != nil || agentFileWatches[product.id] != nil
    }

    func genesisChecklist(_ product: Product) -> GenesisChecklist {
        var inputs = GenesisChecklist.Inputs()
        inputs.agentName = AgentCatalog.name(portfolio.settings.aiAgentProgram)
        inputs.blueprint = blueprint(product)
        inputs.agentRunning = product.isDemo || isAgentWorking(product)
        inputs.scaffoldRunning = genesisScaffolds[product.id]?.isRunning == true
        inputs.runToReview = runProposals(product).filter(\.isAddable).count
        inputs.environmentsToReview = environmentProposals(product).filter(\.isAddable).count
        inputs.skillsToReview = skillSuggestions(product).filter(\.isValid).count
        return GenesisChecklist.make(product, inputs: inputs)
    }

    // MARK: Creating

    /// Makes the folder and the product, then starts the starter's generator or the agent's planning.
    func createProject(_ request: GenesisRequest) async -> String? {
        let creation: GenesisCreation
        do {
            creation = try await ProjectGenesis.create(request, existing: portfolio.products, runner: SystemProcessRunner())
        } catch {
            return String(describing: error)
        }
        // Checked again after the await: another window or the CLI may have added the folder meanwhile.
        if let owner = portfolio.products.first(where: { $0.checkouts.contains { $0.path == creation.path } }) {
            return "\(abbreviate(creation.path)) already belongs to \(owner.name)."
        }
        let product = ProjectGenesis.product(for: request, creation: creation, existing: portfolio.products)
        portfolio.products.append(product)
        save()
        UserDefaults.standard.set(request.parent, forKey: "genesis.parent")
        record("product.create", product: product,
               detail: "kind=new-project starter=\(request.starter?.id ?? "agent") git=\(creation.gitInitialized) folder=\(creation.createdFolder ? "new" : "existing")")
        sheet = nil
        open(product)
        for note in creation.notes { show(note, isError: true) }
        if let starter = request.starter {
            if starter.needsEmptyFolder {
                runStarter(product)
            } else {
                ProjectGenesis.writeRunFile(for: starter, in: creation.path)
                show("Created \(product.name) in \(abbreviate(creation.path))")
            }
        } else {
            startGenesisPlan(product)
        }
        Task { await refresh(product, announce: false) }
        return nil
    }

    /// Starts the agent on the plan: research, write the blueprint, then wait for approval.
    func startGenesisPlan(_ product: Product) {
        guard let checkout = checkout(for: product) else { return }
        Task {
            let tools = await Task.detached { ProjectGenesis.installedTools() }.value
            if installedPlugins == nil { await loadInstalledPlugins() }
            let home = agentHomeURL
            let skills = await Task.detached { Array(SkillSuggestions.installedSkills(home: home)) }.value
            let prompt = GenesisPrompt.plan(product, folder: checkout.path, tools: tools, cli: cliCommand,
                                            installedSkills: skills, installedPlugins: installedPlugins ?? [])
            startSetupAgent(product, checkout: checkout, prompt: prompt, title: "Plan", audit: "genesis.plan")
        }
    }

    /// Runs the starter's generator in a terminal the person can see and answer. Its exit code is kept on the product.
    func runStarter(_ product: Product) {
        guard let checkout = checkout(for: product), let starter = GenesisStarter.find(product.genesis?.starter) else { return }
        let commands = starter.scaffoldCommands(slug: product.slug, module: ProjectGenesis.moduleName(for: product.name))
        var resolved: [[String]] = []
        for step in commands {
            guard let name = step.first, let program = ExecutableLocator.find(name) else {
                return show("\(step.first ?? "A program") is not installed, so the \(starter.title) generator can't run.", isError: true)
            }
            resolved.append([program.path] + step.dropFirst())
        }
        update(product.id) { $0.genesis?.scaffoldExit = nil; $0.genesis?.phase = .building }
        record("genesis.scaffold", product: product, detail: "starter=\(starter.id)")
        if terminalsInApp {
            do {
                let script = try launcher.writeScript(commands: resolved, in: checkout.path)
                guard var launch = TerminalLaunch.command(["/bin/zsh", script.path], kind: .recipe, title: "\(starter.title) generator", in: checkout.path) else {
                    return show("The terminal could not start.", isError: true)
                }
                launch.banner = "\(Brand.name) runs the \(starter.title) generator in \(abbreviate(checkout.path)):\r\n"
                    + commands.map { "  $ " + $0.joined(separator: " ") }.joined(separator: "\r\n") + "\r\n"
                let session = terminals.open(launch, productID: product.id, checkoutID: checkout.id)
                genesisScaffolds[product.id] = session
                session.onExit = { [weak self] session in
                    guard let self else { return }
                    var code: Int32 = 1
                    if case .exited(let exit) = session.state { code = exit ?? 1 }
                    self.finishScaffold(product.id, exit: code)
                }
            } catch {
                show("Could not prepare the generator: \(error.localizedDescription)", isError: true)
            }
            return
        }
        Task {
            let outcome = await launcher.run(commands: resolved, in: checkout.path, terminalBundleID: terminalForCommands)
            report(outcome, success: "Started the \(starter.title) generator in a terminal. Press Check Folder when it finishes.")
        }
    }

    /// After the generator: keep its result, propose the starter's commands, and read the folder again.
    func finishScaffold(_ productID: UUID, exit: Int32) {
        genesisScaffolds[productID] = nil
        guard let product = product(productID), let checkout = product.primaryCheckout else { return }
        update(productID) { $0.genesis?.scaffoldExit = exit }
        if exit == 0, let starter = GenesisStarter.find(product.genesis?.starter) {
            ProjectGenesis.writeRunFile(for: starter, in: checkout.path)
            show("\(starter.title) is set up in \(product.name). Review its commands to use Play.")
        } else {
            show("The generator for \(product.name) stopped with code \(exit). Read the terminal, then run it again.", isError: true)
        }
        record("genesis.scaffold.done", product: product, detail: "exit=\(exit)")
        if let current = self.product(productID) { Task { await refresh(current, announce: false) } }
    }

    /// For a generator that ran in an external terminal: looks at the folder to see whether it produced anything.
    func checkScaffoldFolder(_ product: Product) {
        guard let checkout = product.primaryCheckout else { return }
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: checkout.path)) ?? []).filter { ![".git", ".DS_Store", ".forgedeck"].contains($0) }
        if items.isEmpty {
            show("\(abbreviate(checkout.path)) is still empty. Wait for the generator, or run it again.", isError: true)
        } else {
            finishScaffold(product.id, exit: 0)
        }
    }

    // MARK: Approving

    /// Keeps the approval on the product, adds the planned environments and variable names the person chose, and tells
    /// the agent to build: in its own terminal when it still runs there, or in a new session.
    func approveBlueprint(_ product: Product, stack: Blueprint.Stack, note: String?, addProduction: Bool, addVariables: Bool, startAgent: Bool = true) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. Its blueprint is a fixture.", isError: true) }
        guard let file = blueprintFiles[product.id], let blueprint = file.blueprint, file.isApprovable else {
            return show("The blueprint changed or has problems. Review it again.", isError: true)
        }
        let structure = (blueprint.structure ?? []).prefix(8).map { folder in folder.purpose.map { "\(folder.path) (\($0))" } ?? folder.path }
        update(product.id) { product in
            product.genesis?.approvedStack = stack.name
            product.genesis?.approvedAt = .now
            product.genesis?.phase = .building
            product.genesis?.architecture = blueprint.summary + (structure.isEmpty ? "" : " Structure: " + structure.joined(separator: "; ") + ".")
            product.genesis?.plannedProduction = blueprint.productionLine
            for part in stack.parts ?? [stack.name] where !product.stack.contains(part) { product.stack.append(part) }
            product.lifecycle = .active
            if addProduction {
                if blueprint.production?.staging == true, product.environment(tier: .staging) == nil {
                    product.environments.append(ProductEnvironment(name: "Staging", tier: .staging))
                }
                if product.environment(tier: .production) == nil {
                    product.environments.append(ProductEnvironment(name: "Production", tier: .production))
                }
            }
        }
        if addVariables {
            let taken = Set(portfolio.variables.filter { $0.scope.productID == product.id }.map(\.key))
            for variable in blueprint.variables ?? [] where !taken.contains(variable.name) {
                var definition = VariableDefinition()
                definition.key = variable.name
                definition.scope = .product(product.id)
                definition.isSecret = variable.secret ?? true
                definition.allowedTiers = BlueprintCheck.tiers(variable)
                definition.isRequired = true
                definition.note = (variable.why.map { $0 + ". " } ?? "") + "From the blueprint: add the value when you have it."
                portfolio.variables.append(definition)
            }
            save()
        }
        record("genesis.approve", product: product, detail: "stack=\(stack.name) production=\(addProduction) variables=\(addVariables ? (blueprint.variables ?? []).count : 0)")
        sheet = nil
        if startAgent { sendBuild(product, stack: stack.name, note: note) }
    }

    /// Tells the agent to build. A planning session still open in a built-in terminal gets one line; otherwise a new one starts.
    func sendBuild(_ product: Product, stack: String, note: String?, resuming: Bool = false) {
        guard let current = self.product(product.id), let checkout = checkout(for: current) else { return }
        if !resuming, let session = agentSession(current) {
            session.view.pasteText(GenesisPrompt.approvalMessage(stack: stack, note: note, skills: SkillSuggestions.activeNames(current)))
            // The paste lands asynchronously; Return goes after it.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                session.send("\r")
            }
            watchAgentFiles(current) { [weak session] in session?.isRunning == true }
            terminals.select(session)
            show("Approved. \(AgentCatalog.name(portfolio.settings.aiAgentProgram)) is building \(current.name) with \(stack).")
            return
        }
        let prompt = GenesisPrompt.build(current, stack: stack, note: note, cli: cliCommand, resuming: resuming)
        startSetupAgent(current, checkout: checkout, prompt: prompt, title: "Build", audit: "genesis.build")
    }

    /// Picks up where setup stopped: planning again, building again, or the generator again.
    func continueGenesis(_ product: Product) {
        guard let genesis = product.genesis else { return }
        if !genesis.usesAgent { return runStarter(product) }
        if let stack = genesis.approvedStack {
            sendBuild(product, stack: stack, note: nil, resuming: true)
        } else {
            startGenesisPlan(product)
        }
    }

    func finishGenesis(_ product: Product) {
        update(product.id) { $0.genesis?.phase = .finished; $0.genesis?.finishedAt = .now }
        record("genesis.finish", product: product, detail: "")
        show("\(product.name) is set up. The checklist is closed; its brief stays in the agent's context.")
    }

    /// `gh repo create`, private, with origin set and nothing pushed, after a press and hold.
    func createGitHubRepository(_ product: Product) {
        guard let checkout = checkout(for: product) else { return }
        guard let gh = ExecutableLocator.find("gh") else {
            return show("The GitHub CLI (gh) is not installed. Install it, run gh auth login, then try again.", isError: true)
        }
        let arguments = GenesisGitHub.createArguments(name: product.slug, folder: checkout.path)
        sheet = .confirm(ConfirmRequest(
            title: "Create a GitHub repository",
            message: "Creates a private repository named \(product.slug) under your GitHub account and sets it as origin for \(product.name). Nothing is pushed.",
            checks: [.init(label: "Command", meta: (["gh"] + arguments.map { $0 == checkout.path ? abbreviate($0) : $0 }).joined(separator: " "), ok: true),
                     .init(label: "Visibility", meta: "Private", ok: true)],
            footnote: "A remote write. It is written to the audit log.",
            confirmLabel: "Hold to Create",
            requiresHold: true,
            action: { [weak self] in
                guard let self else { return }
                let result = try? await SystemProcessRunner().run(ProcessRequest(executable: gh, arguments: arguments,
                                                                                  workingDirectory: URL(fileURLWithPath: checkout.path), timeout: 60))
                guard let result, result.ok else {
                    let reason = result.map { Redactor().redact($0.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? "gh did not start"
                    return self.show("GitHub didn't create the repository: \(reason)", isError: true)
                }
                if let url = GenesisGitHub.createdURL(result.stdout + " " + result.stderr) {
                    _ = self.addRepository(url, original: url.webURL, group: product.group, to: product.id)
                }
                self.record("genesis.github", product: product, detail: "repo=\(product.slug) visibility=private")
                self.show("Created the private repository \(product.slug). Push when you're ready.")
                if let current = self.product(product.id) { await self.refresh(current, announce: false) }
            }))
    }
}

// MARK: The sheet

struct NewProjectSheet: View {
    enum Mode: Hashable { case agent, starter }

    /// Snapshot mode opens the sheet filled in, in this mode.
    static var preset: Mode?

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var idea = ""
    @State private var parent = ""
    @State private var folder = ""
    @State private var folderEdited = false
    @State private var mode: Mode = .agent
    @State private var preference = ""
    @State private var starterID = "nextjs"
    @State private var initializeGit = true
    @State private var useExisting = false
    @State private var installed: Set<String>?
    @State private var creating = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var agent: String { AgentCatalog.name(model.portfolio.settings.aiAgentProgram) }
    private var agentInstalled: Bool { installed?.contains(model.portfolio.settings.aiAgentProgram) ?? true }
    private var starter: GenesisStarter? { mode == .starter ? GenesisStarter.find(starterID) : nil }

    private var request: GenesisRequest {
        GenesisRequest(name: name, idea: idea, parent: parent, folder: folder, preference: mode == .agent ? preference : "",
                       starter: starter, useExistingFolder: useExisting, initializeGit: initializeGit)
    }

    private var destination: GenesisDestination { ProjectGenesis.check(request, existing: model.portfolio.products) }

    private var canCreate: Bool {
        guard destination.canCreate, !creating else { return false }
        switch mode {
        case .agent: return agentInstalled && !idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .starter: return starter.map { $0.tool == nil || installed?.contains($0.tool!) != false } ?? false
        }
    }

    var body: some View {
        SheetPanel(width: 680) {
            SheetHeader(icon: .sparkle, title: "New Project",
                        message: "Describe what you want to build. \(Brand.name) makes the folder and the product. \(agent) can plan the stack with you. Nothing is installed or published until you approve it.")
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    section("What are we building?") { what }
                    section("Where should it live?") { location }
                    section("How should it be set up?") { setup }
                }
                .padding(.horizontal, Space.xl).padding(.bottom, Space.sm)
            }
            .frame(maxHeight: 560)
            SheetFooter(note: error ?? footnote) {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : mode == .agent ? "Create and Plan" : "Create Project") { create() }
                    .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction).disabled(!canCreate)
            }
        }
        .onAppear {
            if parent.isEmpty { parent = model.defaultProjectParent }
            if let preset = Self.preset {
                mode = preset
                parent = "/tmp"
                name = "Subscription Desk"
                folder = "subscription-desk"
                idea = "A SaaS app for managing customer subscriptions, with a web dashboard, PostgreSQL, Stripe billing, and a production deployment."
            }
            nameFocused = true
        }
        .task {
            let program = model.portfolio.settings.aiAgentProgram
            installed = await Task.detached { Set(ProjectGenesis.installedTools() + (ExecutableLocator.find(program) != nil ? [program] : [])) }.value
        }
    }

    private var footnote: String {
        mode == .agent ? "\(agent) researches the stack and writes a blueprint. It builds only after you approve."
            : "The generator runs in a terminal you can see. Its commands are proposed for Play."
    }

    private func create() {
        creating = true
        error = nil
        let request = request
        Task {
            if let problem = await model.createProject(request) { error = problem }
            creating = false
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(title).kitType(.section).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var what: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            LabeledField(label: "Name") {
                KitField(placeholder: "Subscription Desk", text: $name).focused($nameFocused)
                    .onChange(of: name) { if !folderEdited { folder = ProjectGenesis.folderName(for: name) } }
            }
            LabeledField(label: "The idea", hint: mode == .agent ? "Who it's for, what it does, and anything it must use. A sentence or a page." : "Optional. Goes in the README.") {
                ZStack(alignment: .topLeading) {
                    if idea.isEmpty {
                        Text("A SaaS app for managing customer subscriptions, with a web dashboard, PostgreSQL, Stripe billing, and a production deployment.")
                            .kitType(.body, Ink.text3).padding(.horizontal, Space.sm).padding(.vertical, Space.sm).allowsHitTesting(false)
                    }
                    TextEditor(text: $idea).font(KitType.body.font).scrollContentBackground(.hidden).padding(Space.xs)
                        .accessibilityLabel("The idea")
                }
                .frame(height: 84)
                .background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
            }
        }
    }

    private var location: some View {
        let destination = destination
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .bottom, spacing: Space.md) {
                LabeledField(label: "In") {
                    HStack(spacing: Space.sm) {
                        Icon(.projects, size: 12).foregroundStyle(Ink.text2)
                        Text(abbreviate(parent)).kitType(.mono).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.sm)
                        Button("Choose…") { chooseParent() }.buttonStyle(.kit(.secondary, compact: true))
                    }
                    .padding(.leading, Space.sm).padding(.trailing, Space.xs).frame(height: Metric.controlHeight)
                    .background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
                }
                LabeledField(label: "Folder") {
                    KitField(placeholder: "subscription-desk", text: Binding(get: { folder }, set: { folder = $0; folderEdited = true }), monospaced: true)
                }
                .frame(width: 220)
            }
            HStack(spacing: Space.sm) {
                let unnamed = folder.trimmingCharacters(in: .whitespaces).isEmpty
                Icon(unnamed ? .projects : destination.problems.isEmpty ? .check : .alert, size: 12)
                    .foregroundStyle(unnamed ? Ink.text3 : destination.problems.isEmpty ? Ink.ok : Ink.warn)
                Text(unnamed ? "Name the project to see where it goes" : abbreviate(destination.path)).kitType(.monoSmall, Ink.text2).lineLimit(1).truncationMode(.middle)
                if let state = destination.state {
                    switch state {
                    case .new: TagBadge("New folder", tone: .ok)
                    case .emptyFolder: TagBadge("Empty folder", tone: .ok)
                    case .notEmpty(let count): TagBadge("Existing · \(count) item\(count == 1 ? "" : "s")", tone: .warn)
                    }
                }
            }
            ForEach(destination.problems.filter { !name.isEmpty || !$0.contains("name") }, id: \.self) { Text($0).kitType(.meta, Ink.warn).fixedSize(horizontal: false, vertical: true) }
            ForEach(destination.warnings, id: \.self) { Text($0).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true) }
            if useExisting || destination.problems.contains(where: { $0.contains("set up in the existing folder") }) {
                Toggle("Set up in the existing folder. Nothing in it is changed or overwritten.", isOn: $useExisting)
                    .toggleStyle(.checkbox).kitType(.label, Ink.text2)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SegmentedPill(options: [(Mode.agent, "\(agent) recommends"), (.starter, "I'll pick a starter")], selection: $mode, stretch: true)
            switch mode {
            case .agent:
                VStack(alignment: .leading, spacing: Space.sm) {
                    LabeledField(label: "Stack preference", hint: "Optional. Leave it empty and \(agent) recommends one, with alternatives and reasons.") {
                        KitField(placeholder: "Next.js with PostgreSQL", text: $preference)
                    }
                    if !agentInstalled {
                        Text("\(agent) isn't installed. Pick a starter, or choose another agent in Settings › Agents.").kitType(.meta, Ink.warn)
                    }
                    steps(["Makes the folder\(initializeGit ? " and a Git repository" : "") and adds \(name.isEmpty ? "the product" : name) to \(Brand.name)",
                           "\(agent) researches the stack and writes a blueprint: stack, structure, environments, variables",
                           "You review the blueprint here and approve it",
                           "\(agent) builds it, checks that it runs, and proposes commands, environments, and skills"])
                }
            case .starter:
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.sm), GridItem(.flexible(), spacing: Space.sm)], spacing: Space.sm) {
                    ForEach(GenesisStarter.all) { starter in starterTile(starter) }
                }
            }
            Toggle("Create a Git repository", isOn: $initializeGit).toggleStyle(.checkbox).kitType(.label, Ink.text2)
        }
    }

    private func steps(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text("\(index + 1)").kitType(.meta, Ink.accent).monospacedDigit().frame(width: 12, alignment: .trailing)
                    Text(line).kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.accent.soft(0.06), in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
    }

    private func starterTile(_ starter: GenesisStarter) -> some View {
        let missing = starter.tool.flatMap { tool in installed.map { $0.contains(tool) ? nil : tool } ?? nil }
        let selected = starterID == starter.id
        return Button { starterID = starter.id } label: {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Text(starter.title).kitType(.labelMedium, Ink.text)
                    Spacer(minLength: 0)
                    if let missing { TagBadge("Needs \(missing)", tone: .warn) } else if selected { Icon(.check, size: 11).foregroundStyle(Ink.accent) }
                }
                Text(starter.summary).kitType(.meta, Ink.text3).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            }
            .padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Ink.accent.soft(0.08) : Ink.panel, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous)
                .strokeBorder(selected ? Ink.accent : Ink.line, lineWidth: selected ? 1.5 : Metric.hairline)) // grid: ok selection ring
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(starter.title): \(starter.summary)\(missing.map { ". Needs \($0)" } ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that will hold the new project's folder."
        panel.directoryURL = URL(fileURLWithPath: parent)
        if panel.runModal() == .OK, let url = panel.url { parent = url.path }
    }
}
