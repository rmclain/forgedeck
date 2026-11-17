import ForgeDeckKit
import SwiftUI

// Run setup: Play › Set Up Run starts the agent with a prompt built from what ForgeDeck knows about the product.
// The agent works out how it runs, tries it, and proposes commands in .forgedeck/run.json. The review here is the approval.

extension AppModel {
    /// Proposals that would save something or have a problem. Ones already saved are left out.
    func runProposals(_ product: Product) -> [RunProposal] {
        let files = product.isDemo ? DemoFixtures.runProposals(for: product) : (runFiles[product.id] ?? [])
        return RunSetup.plan(product, files: files).filter { $0.changes || !$0.problems.isEmpty }
    }

    func runFileErrors(_ product: Product) -> [String] {
        (runFiles[product.id] ?? []).compactMap { file in file.error.map { "\(file.checkoutName): \($0)" } }
    }

    /// Starts the agent in the product's folder with the setup prompt. When it ends, the product is read again,
    /// so what it proposed shows up for review.
    func setUpRun(_ product: Product, checkout wanted: LocalCheckout? = nil) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. There is nothing to set up.", isError: true) }
        guard let checkout = checkout(for: product, wanted) else { return }
        let site = localSites.first { $0.contains(checkout.path) }
        let prompt = RunSetup.prompt(for: product, checkout: checkout, cli: cliCommand, localSite: site)
        startSetupAgent(product, checkout: checkout, prompt: prompt, title: "Set Up Run", audit: "run.setup")
    }

    /// Starts the chosen agent with a first message, in ForgeDeck's terminal or the preferred one.
    /// The product is refreshed when an in-app session ends, so proposals it wrote appear at once.
    func startSetupAgent(_ product: Product, checkout: LocalCheckout, prompt: String, title: String, audit: String) {
        let program = portfolio.settings.aiAgentProgram
        guard let url = ExecutableLocator.find(program) else {
            return show("\(AgentCatalog.name(program)) is not installed. Choose another agent in Settings › Agents.", isError: true)
        }
        let bundle: AgentContextBundle
        do {
            bundle = try AgentContextBundle.write(for: product, checkout: checkout, portfolio: portfolio, cache: cache, location: contextLocation, mcp: mcpInfo(product))
        } catch {
            return show("Could not write the context file: \(error.localizedDescription)", isError: true)
        }
        let argv = bundle.command(program: url, model: portfolio.settings.model(for: program), message: prompt)
        if terminalsInApp {
            guard var launch = TerminalLaunch.command(argv, kind: .agent, title: "\(title) · \(product.name)", in: checkout.path) else {
                return show("\(AgentCatalog.name(program)) could not be started.", isError: true)
            }
            launch.banner = bundle.banner(product: product.name, program: program)
            let session = terminals.open(launch, productID: product.id, checkoutID: checkout.id)
            session.onExit = { [weak self] _ in
                guard let self else { return }
                Task { await self.refresh(product, announce: false) }
            }
            self.session(program, product: product, checkout: checkout, command: audit)
            record(audit, product: product, detail: "agent=\(program) checkout=\(checkout.name)")
            return
        }
        Task {
            let outcome = await launcher.run(command: argv, in: checkout.path, terminalBundleID: terminalForCommands)
            if outcome.didOpen {
                session(program, product: product, checkout: checkout, command: audit)
                record(audit, product: product, detail: "agent=\(program) checkout=\(checkout.name) app=terminal")
            }
            report(outcome, success: "Started \(AgentCatalog.name(program)) for \(title.lowercased()) in \(product.name). Refresh when it is done.")
        }
    }

    /// Opens the review, reading the folder first so a file the agent just wrote is included.
    func reviewRunSetup(_ product: Product) {
        Task {
            if !product.isDemo { await refresh(product, announce: false) }
            if runProposals(product).isEmpty, runFileErrors(product).isEmpty {
                show("No \(RunSetup.relativePath) in \(product.name) yet. Use Set Up Run to have \(AgentCatalog.name(portfolio.settings.aiAgentProgram)) write one.", isError: true)
            } else {
                sheet = .runSetup(product.id)
            }
        }
    }

    /// Saves the chosen commands, approved. A saved command with the same name is replaced; nothing else changes.
    func addRunCommands(_ chosen: [RunProposal], to product: Product) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. Its run setup is a fixture.", isError: true) }
        let current = self.product(product.id) ?? product
        let fresh = RunSetup.plan(current, files: runFiles[product.id] ?? [])
        let wanted = Set(chosen.map(\.id))
        // Checked again now: the file or the saved commands may have changed while the sheet was open.
        let addable = fresh.filter { wanted.contains($0.id) && $0.isAddable }
        guard !addable.isEmpty else { return show("Nothing to save: the run setup changed since the review.", isError: true) }
        update(product.id) { product in
            for proposal in addable { RunSetup.apply(proposal, to: &product) }
        }
        for proposal in addable {
            record("recipe.add", product: product,
                   detail: "recipe=\(proposal.recipe.label) source=\(RunSetup.relativePath) play=\(proposal.play?.rawValue ?? "none") replaced=\(proposal.existingID != nil)")
        }
        show(addable.count == 1 ? "Saved \(addable[0].recipe.label)" : "Saved \(addable.count) commands. Play runs \(addable.first { $0.play != nil }?.recipe.label ?? "the first one").")
    }
}

extension RunProposal {
    /// One line: what it does.
    var summary: String {
        if !problems.isEmpty { return problems.count == 1 ? "1 problem to fix in the file" : "\(problems.count) problems to fix in the file" }
        let what = recipe.executor == .openURL ? "opens \(recipe.url ?? "")" : recipe.steps.map { $0.joined(separator: " ") }.joined(separator: " → ")
        return (existingID == nil ? "" : "Replaces the saved one · ") + what
    }

    var kindTitle: String { play.map { "Play · \($0.title)" } ?? "Action" }
}

struct ProposedRunCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let proposals = model.runProposals(product)
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Run setup", subtitle: "Proposed in \(RunSetup.relativePath) in the repository") {
                if product.isDemo { DemoBadge() }
                Button("Review…") { model.sheet = .runSetup(product.id) }
                    .buttonStyle(.kit(.secondary, compact: true))
                    .help("See each proposed command and choose what Play and Actions get. Nothing is saved or run until you do.")
            }
            .padding(Space.lg)
            ForEach(proposals) { proposal in
                HStack(spacing: Space.sm) {
                    Icon(proposal.problems.isEmpty ? (proposal.play == nil ? .terminal : .play) : .alert, size: 12)
                        .foregroundStyle(proposal.problems.isEmpty ? Ink.text2 : Ink.warn)
                    Text(proposal.recipe.label).kitType(.labelMedium, Ink.text)
                    Text(proposal.summary).kitType(.label, Ink.text2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                .hairlineAbove()
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}

struct RunSetupSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    @State private var chosen: Set<String> = []
    @State private var loaded = false

    var body: some View {
        let product = model.product(productID)
        let proposals = product.map { model.runProposals($0) } ?? []
        let errors = product.map { model.runFileErrors($0) } ?? []
        let selected = proposals.filter { chosen.contains($0.id) && $0.isAddable }
        let first = selected.first { $0.play != nil }
        SheetPanel(width: 640) {
            SheetHeader(icon: .play, tone: .accent, title: "Review Run Setup",
                        message: "\(product?.name ?? "This product")'s repository proposes these commands in \(RunSetup.relativePath). Saving them approves them: Play and Actions run them on this Mac without asking again.")
            let list = VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(errors, id: \.self) { error in Text(error).kitType(.meta, Ink.warn).fixedSize(horizontal: false, vertical: true) }
                ForEach(proposals) { proposal in row(proposal) }
            }
            .padding(.horizontal, Space.xl)
            if proposals.count <= 4 { list } else { ScrollView { list }.frame(height: 440) }
            SheetFooter(note: first.map { "Play will run \($0.recipe.label)." } ?? "Edit the file and review again to change a command.") {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button(selected.count <= 1 ? "Save Command" : "Save \(selected.count) Commands") {
                    model.sheet = nil
                    if let product { model.addRunCommands(selected, to: product) }
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || product?.isDemo != false)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            chosen = Set(proposals.filter(\.isAddable).map(\.id))
        }
    }

    private func row(_ proposal: RunProposal) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Toggle("", isOn: Binding(get: { chosen.contains(proposal.id) }, set: { on in
                if on { chosen.insert(proposal.id) } else { chosen.remove(proposal.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden().disabled(!proposal.isAddable)
            .accessibilityLabel("Save \(proposal.recipe.label)")
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Text(proposal.recipe.label).kitType(.labelMedium, Ink.text)
                    TagBadge(proposal.kindTitle)
                    if proposal.existingID != nil { Text("replaces the saved one").kitType(.meta, Ink.text3) }
                }
                if proposal.problems.isEmpty {
                    if proposal.recipe.executor == .openURL {
                        Text("Opens \(proposal.recipe.url ?? "")").kitType(.monoSmall, Ink.text2).lineLimit(1).truncationMode(.middle)
                    } else {
                        ForEach(Array(proposal.recipe.steps.enumerated()), id: \.offset) { _, step in
                            Text("$ " + step.joined(separator: " ")).kitType(.monoSmall, Ink.text2).lineLimit(2).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Text(details(proposal)).kitType(.meta, Ink.text3)
                    }
                    ForEach(proposal.warnings, id: \.self) { warning in Text(warning).kitType(.meta, Ink.warn) }
                } else {
                    ForEach(proposal.problems, id: \.self) { problem in
                        Text(problem).kitType(.meta, Ink.warn).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note = proposal.entry.note, !note.isEmpty {
                    Text("Why: \(String(note.prefix(240)))").kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Metric.controlRadius).stroke(Ink.line, lineWidth: Metric.hairline))
    }

    private func details(_ proposal: RunProposal) -> String {
        let recipe = proposal.recipe
        var parts = [recipe.opensInTerminal ? "Runs in a terminal" : "Runs and shows a log"]
        if !recipe.workingSubdirectory.isEmpty { parts.append("in \(recipe.workingSubdirectory)/") }
        if let url = recipe.url { parts.append("opens \(url) once it answers") }
        if !recipe.variableKeys.isEmpty { parts.append("gets " + recipe.variableKeys.joined(separator: ", ")) }
        if proposal.checkoutName.isEmpty == false, (model.product(productID)?.checkouts.count ?? 0) > 1 { parts.append("checkout \(proposal.checkoutName)") }
        return parts.joined(separator: " · ")
    }
}
