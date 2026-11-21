import ForgeDeckKit
import SwiftUI

// The Project setup checklist on a new product's Overview, and the blueprint review. The checklist is worked out from
// what ForgeDeck can see (the folder, the blueprint, the proposal files, saved commands), so it is right after a restart
// and offers the next step: review, continue, or run again.

struct ProjectSetupCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let checklist = model.genesisChecklist(product)
        let agent = AgentCatalog.name(model.portfolio.agentProgram(for: product))
        let done = checklist.rows.filter { $0.state == .done }.count
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Project setup", subtitle: checklist.isComplete ? "Ready to work on. Press Play, or open \(agent)."
                       : "\(done) of \(checklist.rows.count) done. \(Brand.name) keeps track, so you can leave and come back.") {
                if product.isDemo { DemoBadge() }
                Button(checklist.isComplete ? "Finish" : "Close Checklist") { model.finishGenesis(product) }
                    .buttonStyle(.kit(checklist.isComplete ? .secondary : .ghost, compact: true)).disabled(product.isDemo)
                    .help("Hides this checklist. The project brief stays in the agent's context.")
            }
            .padding(Space.lg)
            if let idea = product.genesis?.idea, !idea.isEmpty {
                Text(idea).kitType(.label, Ink.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.lg).padding(.bottom, Space.md)
            }
            ProgressView(value: Double(done), total: Double(max(1, checklist.rows.count))).progressViewStyle(.linear).tint(Ink.accent)
                .padding(.horizontal, Space.lg).padding(.bottom, Space.md)
                .accessibilityLabel("\(done) of \(checklist.rows.count) setup steps done")
            ForEach(checklist.rows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: Space.md) {
                        stateIcon(row.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).kitType(.labelMedium, Ink.text)
                            Text(row.detail).kitType(.meta, row.state == .attention ? Ink.warn : Ink.text3).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Space.md)
                        actions(row, agent: agent)
                    }
                    if row.item == .build, product.genesis?.approvedStack != nil, let steps = model.blueprint(product)?.blueprint?.steps, !steps.isEmpty {
                        BlueprintSteps(steps: steps).padding(.leading, Space.xxl + Space.xs).padding(.top, Space.sm)
                    }
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
                .background(row.id == checklist.next?.id ? Ink.accent.soft(0.05) : .clear)
                .hairlineAbove()
                .accessibilityElement(children: .contain)
            }
        }
        .card()
    }

    @ViewBuilder private func stateIcon(_ state: GenesisChecklist.State) -> some View {
        Group {
            switch state {
            case .done: Icon(.check, size: 11, weight: .bold).foregroundStyle(Ink.ok)
            case .working: ProgressView().controlSize(.mini)
            case .needsYou: Circle().fill(Ink.accent).frame(width: 8, height: 8)
            case .attention: Icon(.alert, size: 11).foregroundStyle(Ink.warn)
            case .pending: Icon(.clock, size: 11).foregroundStyle(Ink.text3)
            case .optional: Circle().strokeBorder(Ink.text3, lineWidth: 1).frame(width: 8, height: 8)
            }
        }
        .frame(width: 20, height: 20)
        .background(Ink.tone(tone(state)).soft(0.12), in: Circle())
        .accessibilityLabel(label(state))
    }

    private func tone(_ state: GenesisChecklist.State) -> Tone {
        switch state {
        case .done: .ok
        case .working, .needsYou: .accent
        case .attention: .warn
        case .pending, .optional: .muted
        }
    }

    private func label(_ state: GenesisChecklist.State) -> String {
        switch state {
        case .done: "Done"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .attention: "Needs attention"
        case .pending: "Not started"
        case .optional: "Optional"
        }
    }

    @ViewBuilder private func actions(_ row: GenesisChecklist.Row, agent: String) -> some View {
        let demo = product.isDemo
        HStack(spacing: Space.sm) {
            switch (row.item, row.state) {
            case (.plan, .needsYou), (.plan, .done):
                button(row.state == .done ? "Blueprint" : "Review Blueprint…", prominent: row.state == .needsYou) { model.sheet = .blueprint(product.id) }
            case (.plan, .attention):
                if model.blueprint(product) != nil { button("Review Blueprint…") { model.sheet = .blueprint(product.id) } }
                button("Start \(agent)") { model.continueGenesis(product) }.disabled(demo)
            case (.plan, .working), (.build, .working):
                if let session = model.agentSession(product) { button("Show Terminal") { model.terminals.select(session) } }
            case (.build, .attention):
                if product.genesis?.usesAgent == true {
                    button("Continue with \(agent)") { model.continueGenesis(product) }.disabled(demo)
                } else {
                    if !model.terminalsInApp { button("Check Folder") { model.checkScaffoldFolder(product) }.disabled(demo) }
                    button("Run Generator Again") { model.continueGenesis(product) }.disabled(demo)
                }
            case (.commands, .needsYou):
                button("Review…", prominent: true) { model.reviewRunSetup(product) }
            case (.commands, .pending):
                button("Set Up with \(agent)") { model.setUpRun(product) }.disabled(demo)
            case (.commands, .done):
                button("Play") { model.play(product) }.disabled(demo)
            case (.environments, .needsYou):
                button("Review…", prominent: true) { model.sheet = .environmentProposals(product.id) }
            case (.environments, _):
                if product.environment(tier: .production) == nil {
                    button("Add Environment…") { model.sheet = .environment(productID: product.id) }.disabled(demo)
                }
            case (.skills, .needsYou):
                button("Review…", prominent: true) { model.open(product, tab: .development) }
            case (.skills, .optional):
                button("Suggest with \(agent)") { model.suggestSkills(product) }.disabled(demo)
            case (.github, .optional):
                button("Create Private Repository…") { model.createGitHubRepository(product) }
                    .disabled(demo || product.primaryCheckout?.isGitRepository != true)
            default:
                EmptyView()
            }
        }
    }

    private func button(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.kit(prominent ? .secondary : .ghost, compact: true))
    }
}

/// The blueprint's build steps as the agent reports them. Reported, not verified: the words say so.
struct BlueprintSteps: View {
    let steps: [Blueprint.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Group {
                        switch step.state {
                        case .done: Icon(.check, size: 10, weight: .bold).foregroundStyle(Ink.ok)
                        case .running: ProgressView().controlSize(.mini)
                        case .failed: Icon(.error, size: 10).foregroundStyle(Ink.err)
                        case .skipped: Icon(.chevronRight, size: 10).foregroundStyle(Ink.text3)
                        case .pending: Circle().strokeBorder(Ink.text3, lineWidth: 1).frame(width: 7, height: 7)
                        }
                    }
                    .frame(width: 14)
                    Text(step.title).kitType(.label, step.state == .pending ? Ink.text3 : Ink.text2)
                    if let detail = step.detail, !detail.isEmpty {
                        Text(detail).kitType(.meta, step.state == .failed ? Ink.err : Ink.text3).lineLimit(2)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.title): \(step.state.rawValue)\(step.detail.map { ", \($0)" } ?? "")")
            }
            Text("Reported by the agent").kitType(.meta, Ink.text3)
        }
    }
}

// MARK: Blueprint review

struct BlueprintSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    @State private var choice = 0
    @State private var custom = ""
    @State private var note = ""
    @State private var addProduction = true
    @State private var addVariables = true

    var body: some View {
        let product = model.product(productID)
        let file = product.flatMap { model.blueprint($0) }
        let agent = AgentCatalog.name(model.portfolio.agentProgram(for: product))
        let approved = product?.genesis?.approvedStack
        SheetPanel(width: 720) {
            SheetHeader(icon: .sparkle, title: "Blueprint for \(product?.name ?? "the project")",
                        message: approved.map { "Approved: \($0). \(agent) reports its progress in the build steps below." }
                            ?? "\(agent)'s plan. Nothing is built until you approve it. Production and variables are plans, not evidence.")
            ScrollView {
                if let blueprint = file?.blueprint, let product {
                    content(blueprint, file: file!, product: product, agent: agent, approved: approved != nil)
                        .padding(.horizontal, Space.xl).padding(.bottom, Space.sm)
                } else {
                    EmptyState(icon: .sparkle, title: "No blueprint", message: file?.problems.first ?? "\(agent) hasn't written one yet.", compact: true)
                        .padding(.horizontal, Space.xl)
                }
            }
            .frame(maxHeight: 600)
            SheetFooter(note: approved != nil ? "" : product?.isDemo == true ? "Demo blueprint. Nothing is built." : "Approving tells \(agent) to build. It can't deploy, publish, or push.") {
                if approved != nil {
                    Button("Close") { model.sheet = nil }.buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                    Button("Approve and Build") { approve(product, file: file) }
                        .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(product?.isDemo != false || file?.isApprovable != true || (isCustom(file) && custom.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }

    private func stacks(_ file: BlueprintFile?) -> [Blueprint.Stack] {
        guard let blueprint = file?.blueprint else { return [] }
        return [blueprint.stack] + (blueprint.alternatives ?? []).prefix(4)
    }

    private func isCustom(_ file: BlueprintFile?) -> Bool { choice == stacks(file).count }

    private func approve(_ product: Product?, file: BlueprintFile?) {
        guard let product else { return }
        let options = stacks(file)
        let stack = isCustom(file) ? Blueprint.Stack(name: custom.trimmingCharacters(in: .whitespacesAndNewlines)) : options[min(choice, options.count - 1)]
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        model.approveBlueprint(product, stack: stack, note: trimmed.isEmpty ? nil : trimmed, addProduction: addProduction, addVariables: addVariables)
    }

    @ViewBuilder private func content(_ blueprint: Blueprint, file: BlueprintFile, product: Product, agent: String, approved: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if !file.problems.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Fix before approving").kitType(.labelMedium, Ink.warn)
                    ForEach(file.problems, id: \.self) { Text("• \($0)").kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true) }
                    Text("Tell \(agent) in its terminal, or run \(Brand.cliName) blueprint check \(product.slug).").kitType(.meta, Ink.text3)
                }
                .padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.warn.soft(0.08), in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
            }
            HStack(spacing: Space.sm) {
                TagBadge("Recommended by \(agent)", tone: .accent)
                if product.isDemo { DemoBadge() }
            }
            Text(blueprint.summary).kitType(.body, Ink.text).fixedSize(horizontal: false, vertical: true)

            group("Stack") {
                VStack(spacing: Space.sm) {
                    ForEach(Array(stacks(file).enumerated()), id: \.offset) { index, stack in
                        stackOption(stack, index: index, recommended: index == 0, disabled: approved)
                    }
                    if !approved {
                        Button { choice = stacks(file).count } label: {
                            HStack(spacing: Space.sm) {
                                radio(choice == stacks(file).count)
                                Text("Something else").kitType(.labelMedium, Ink.text)
                                if choice == stacks(file).count {
                                    KitField(placeholder: "What to use instead", text: $custom)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(Space.md).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous)
                            .strokeBorder(choice == stacks(file).count ? Ink.accent : Ink.line, lineWidth: choice == stacks(file).count ? 1.5 : Metric.hairline)) // grid: ok selection ring
                    }
                }
            }

            HStack(alignment: .top, spacing: Space.xl) {
                if let structure = blueprint.structure, !structure.isEmpty {
                    group("Structure") {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            ForEach(Array(structure.prefix(30).enumerated()), id: \.offset) { _, folder in
                                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                    Text(folder.path).kitType(.monoSmall, Ink.text).lineLimit(1).truncationMode(.head).frame(width: 150, alignment: .leading)
                                        .help(folder.path)
                                    Text(folder.purpose ?? "").kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let tools = blueprint.tools, !tools.isEmpty {
                    group("Tools") {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            ForEach(Array(tools.prefix(20).enumerated()), id: \.offset) { _, tool in
                                VStack(alignment: .leading, spacing: 2) { // grid: ok name and reason read as one line pair
                                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                        Text(tool.name).kitType(.monoSmall, Ink.text).lineLimit(1).truncationMode(.middle)
                                        if let installed = tool.installed {
                                            TagBadge(installed ? "Installed" : "Not installed", tone: installed ? .ok : .warn).fixedSize()
                                        }
                                    }
                                    if let why = tool.why, !why.isEmpty {
                                        Text(why).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.bottom, 2) // grid: ok gap between tools
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let production = blueprint.production {
                group("Production plan") {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.sm) {
                            TagBadge("Planned", tone: .muted)
                            Text([production.host, production.domain].compactMap { $0 }.joined(separator: " · ")).kitType(.labelMedium, Ink.text)
                            if production.staging == true { TagBadge("With staging") }
                        }
                        let facts = [production.versionPath.map { "Version at \($0)" }, production.healthPath.map { "Health at \($0)" },
                                     production.companion.flatMap { $0 == "none" ? nil : "\(Brand.name) companion: \($0)" }].compactMap { $0 }
                        if !facts.isEmpty { Text(facts.joined(separator: " · ")).kitType(.monoSmall, Ink.text2) }
                        if let note = production.note { Text(note).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true) }
                        Text("Nothing is deployed. Once it is, add a check on the environment and \(Brand.name) shows what runs there.")
                            .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                        if !approved {
                            Toggle("Add \(production.staging == true ? "Production and Staging environments" : "a Production environment") with no checks yet. They show Unknown until a check answers.",
                                   isOn: $addProduction).toggleStyle(.checkbox).kitType(.label, Ink.text2)
                        }
                    }
                }
            }

            if let variables = blueprint.variables, !variables.isEmpty {
                group("Variables") {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(Array(variables.prefix(40).enumerated()), id: \.offset) { _, variable in
                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                Icon(variable.secret == false ? .tag : .key, size: 10).foregroundStyle(Ink.text3)
                                Text(variable.name).kitType(.monoSmall, Ink.text)
                                Text(BlueprintCheck.tiers(variable).map(\.title).joined(separator: ", ")).kitType(.meta, Ink.text3)
                                Text(variable.why ?? "").kitType(.meta, Ink.text3).lineLimit(1)
                            }
                        }
                        if !approved {
                            Toggle("Add these names to \(product.name)'s Secrets, without values. You add each value yourself.", isOn: $addVariables)
                                .toggleStyle(.checkbox).kitType(.label, Ink.text2).padding(.top, Space.xs)
                        }
                    }
                }
            }

            skillsGroup(product, agent: agent, approved: approved)

            if let questions = blueprint.questions, !questions.isEmpty {
                group("Open questions") {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(Array(questions.prefix(6).enumerated()), id: \.offset) { _, question in
                            Text("• \(question)").kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        if !approved { Text("Answer them in the note below, or in \(agent)'s terminal.").kitType(.meta, Ink.text3) }
                    }
                }
            }

            if let steps = blueprint.steps, !steps.isEmpty {
                group("Build steps") { BlueprintSteps(steps: steps) }
            }

            if !approved {
                LabeledField(label: "Note for \(agent)", hint: "Optional. Answers, constraints, or changes. Never a password or key.") {
                    KitField(placeholder: "Customers sign in themselves; use Postgres in Docker locally.", text: $note)
                }
            }
            if !file.warnings.isEmpty {
                Text(file.warnings.joined(separator: " ")).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The skills the agent suggested with the plan, and the ones already chosen, so they are in place before the build.
    @ViewBuilder private func skillsGroup(_ product: Product, agent: String, approved: Bool) -> some View {
        let suggested = model.skillSuggestions(product).filter(\.isValid).map(\.entry)
        let chosen = (product.agentSkills ?? []).filter { !$0.isDismissed }
        if !suggested.isEmpty || !chosen.isEmpty {
            group("Skills") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(chosen) { skill in
                        skillRow(skill.id, why: skill.why, isPlugin: skill.isPlugin, state: skill.isActive ? "Chosen" : "Off")
                    }
                    ForEach(suggested, id: \.name) { entry in
                        skillRow(entry.name, why: entry.why ?? "", isPlugin: entry.isPlugin, state: nil)
                    }
                    HStack(spacing: Space.sm) {
                        Text(suggested.isEmpty ? "\(agent) is told about the chosen skills when it builds."
                             : approved ? "Choose them in Development › Skills."
                             : "Choose them before approving, so \(agent) can use them while it builds.")
                            .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if !suggested.isEmpty {
                            Button("Choose Skills…") {
                                model.sheet = nil
                                model.open(product, tab: .development)
                            }
                            .buttonStyle(.kit(.link))
                        }
                    }
                    .padding(.top, Space.xs)
                }
            }
        }
    }

    private func skillRow(_ name: String, why: String, isPlugin: Bool, state: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Icon(.sparkle, size: 10).foregroundStyle(state == nil ? Ink.text3 : Ink.accent)
            Text(name).kitType(.monoSmall, Ink.text).lineLimit(1).fixedSize()
            if isPlugin { TagBadge("Plugin").fixedSize() }
            if let state { TagBadge(state, tone: state == "Chosen" ? .ok : .muted).fixedSize() }
            Text(why).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).kitType(.section).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func radio(_ on: Bool) -> some View {
        Circle().strokeBorder(on ? Ink.accent : Ink.text3, lineWidth: on ? 4 : 1).frame(width: 14, height: 14) // grid: ok radio ring
    }

    private func stackOption(_ stack: Blueprint.Stack, index: Int, recommended: Bool, disabled: Bool) -> some View {
        let selected = choice == index
        return Button { choice = index } label: {
            HStack(alignment: .top, spacing: Space.sm) {
                if !disabled { radio(selected).padding(.top, 2) }
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.sm) {
                        Text(stack.name).kitType(.labelMedium, Ink.text)
                        if recommended { TagBadge("Recommended", tone: .accent) }
                    }
                    if let why = stack.why { Text(why).kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading) }
                    if let parts = stack.parts, !parts.isEmpty {
                        FlowLayout { ForEach(parts.prefix(8), id: \.self) { Chip($0) } }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.md).contentShape(Rectangle())
            .background(selected && !disabled ? Ink.accent.soft(0.07) : Ink.panel, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous)
                .strokeBorder(selected && !disabled ? Ink.accent : Ink.line, lineWidth: selected && !disabled ? 1.5 : Metric.hairline)) // grid: ok selection ring
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
