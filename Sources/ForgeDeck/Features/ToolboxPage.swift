import ForgeDeckKit
import SwiftUI

extension AppModel {
    /// Installs a tool in the background. The card shows progress; the output is kept in a run log and opens only if the install fails.
    func install(_ spec: ToolSpec) {
        guard let command = Toolbox.installCommand(spec) else {
            return show("No installer for \(spec.name) is available here. See \(spec.homepage).", isError: true)
        }
        guard !installingTools.contains(spec.id) else { return }
        let via = command.first.map { ($0 as NSString).lastPathComponent } ?? ""
        installingTools.insert(spec.id)
        runLogs.append(RunLog(title: "Install \(spec.name)", productName: "this Mac"))
        let id = runLogs[runLogs.count - 1].id
        show("Installing \(spec.name) with \(via) in the background…")
        runLogs[runLogs.count - 1].task = Task {
            let output: String
            let code: Int32
            do {
                let result = try await Toolbox.install(spec)
                output = [ShellQuote.join([via] + command.dropFirst()), result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                    + (result.timedOut ? "\nStopped after 15 minutes." : "")
                code = result.timedOut ? 124 : result.exitCode
            } catch {
                output = String(describing: error)
                code = 127
            }
            installingTools.remove(spec.id)
            toolsVersion += 1
            record("tool.install", detail: "tool=\(spec.id) via=\(via) exit=\(code)", outcome: code == 0 ? "ok" : "failed")
            if let index = runLogs.firstIndex(where: { $0.id == id }) {
                runLogs[index].output = output
                runLogs[index].exitCode = code
                runLogs[index].isRunning = false
            }
            if code == 0 {
                show("Installed \(spec.name).")
            } else {
                show("\(spec.name) did not install. The output is open.", isError: true)
                if sheet == nil { sheet = .runLog(id) }
            }
        }
    }

    /// Runs a tool action and shows its output in the run log sheet.
    func runTool(_ action: ToolAction, of spec: ToolSpec, product: Product?, checkout: LocalCheckout?) {
        if action.scope == .checkout {
            guard let product, !product.isDemo else { return show("Choose a product with a checkout on this Mac.", isError: true) }
            guard checkout != nil else { return show("\(product.name) has no local checkout.", isError: true) }
        }
        if action.safety >= .localWrite, let product, sheet == nil {
            sheet = .confirm(ConfirmRequest(title: "\(action.label)?", message: "\(spec.name) will write in \(checkout?.name ?? product.name). \(action.note)",
                                            checks: [.init(label: "Folder", meta: abbreviate(checkout?.path ?? ""), ok: true)],
                                            confirmLabel: "Hold to Run") { [weak self] in
                self?.startTool(action, of: spec, product: product, checkout: checkout)
            })
            return
        }
        startTool(action, of: spec, product: product, checkout: checkout)
    }

    private func startTool(_ action: ToolAction, of spec: ToolSpec, product: Product?, checkout: LocalCheckout?) {
        runLogs.append(RunLog(title: "\(spec.name): \(action.label)", productName: product.map { "\($0.name)\(checkout.map { " · \($0.name)" } ?? "")" } ?? "this Mac"))
        let id = runLogs[runLogs.count - 1].id
        sheet = .runLog(id)
        runLogs[runLogs.count - 1].task = Task {
            let output: String
            let code: Int32
            do {
                let result = try await Toolbox.run(action, of: spec, checkout: checkout?.path)
                let text = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                output = text + (result.timedOut ? "\nStopped after 3 minutes." : "") + (result.truncated ? "\nOutput was cut at 400 KB." : "")
                code = result.exitCode
            } catch {
                output = String(describing: error)
                code = 127
            }
            guard let index = runLogs.firstIndex(where: { $0.id == id }) else { return }
            runLogs[index].output = output
            runLogs[index].exitCode = code
            runLogs[index].isRunning = false
            record("tool.run", product: product, detail: "tool=\(spec.id) action=\(action.id) exit=\(code)", outcome: code == 0 ? "ok" : "failed")
        }
    }
}

struct ToolStatusLabel: View {
    let status: Toolbox.Status

    var body: some View {
        switch status {
        case .installed: StatusPill("Installed", tone: .ok)
        case .onDemand: StatusPill("Runs with npx", tone: .accent).help("The first run downloads the pinned package.")
        case .missing: StatusPill("Not installed", tone: .muted)
        case .external: StatusPill("Set up separately", tone: .muted)
        }
    }
}

struct ToolboxPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let _ = model.toolsVersion
        let _ = model.skillsVersion
        Page {
            PageHeader(title: "Toolbox", subtitle: "Command-line tools and agent skills that save AI tokens or check your repositories. \(Brand.name) finds them and installs them when you ask. Nothing installs on its own. Tools run against a repository from that product's page.") {
                IconButton(.sync, label: "Check again for installed tools and skills") { model.toolsVersion += 1; model.skillsVersion += 1; model.refreshMCP() }
            }
            MCPSection()
            SkillsSection()
            ForEach(ToolCategory.allCases, id: \.self) { category in
                VStack(alignment: .leading, spacing: Space.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title).kitType(.cardTitle)
                        Text(category.blurb).kitType(.label, Ink.text2)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Space.md, alignment: .top)], spacing: Space.md) {
                        ForEach(Toolbox.catalog.filter { $0.category == category }) { spec in card(spec) }
                    }
                }
            }
            Text("Tools that \(Brand.name) finds installed are also listed in each agent's CONTEXT.md, so the agent can use them instead of reading whole files.")
                .kitType(.meta, Ink.text3)
        }
    }

    private func card(_ spec: ToolSpec) -> some View {
        let status = Toolbox.status(spec)
        let perRepo = spec.actions.filter { $0.scope == .checkout }
        return SurfaceCard {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Text(spec.name).kitType(.bodyStrong)
                    ToolStatusLabel(status: status)
                    Spacer(minLength: Space.xs)
                    IconButton(.external, label: "Open \(spec.homepage)") { model.openLink(spec.homepage) }
                }
                Text(spec.summary).kitType(.label, Ink.text).fixedSize(horizontal: false, vertical: true)
                Text(spec.why).kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                if case .installed(let path) = status { Text(abbreviate(path)).kitType(.monoSmall, Ink.text3).lineLimit(1) }
                HStack(spacing: Space.xs) {
                    if status == .missing, !spec.install.isEmpty {
                        if let command = Toolbox.installCommand(spec) {
                            if model.installingTools.contains(spec.id) {
                                HStack(spacing: Space.xs) {
                                    ProgressView().controlSize(.small)
                                    Text("Installing…").kitType(.label, Ink.text2)
                                }
                                .accessibilityElement(children: .combine)
                            } else {
                                Button("Install with \(spec.install.first { ExecutableLocator.find($0.command[0]) != nil }?.method.title ?? "")") { model.install(spec) }
                                    .buttonStyle(.kit(.primary, compact: true))
                                    .help(ShellQuote.join(command.map { ($0 as NSString).lastPathComponent }) + ", in the background")
                            }
                        } else {
                            Text("Install with: \(spec.install.map { $0.command.joined(separator: " ") }.joined(separator: "  or  "))").kitType(.monoSmall, Ink.text3)
                        }
                    }
                    ForEach(spec.actions.filter { $0.scope == .global }) { action in
                        Button(action.label) { model.runTool(action, of: spec, product: nil, checkout: nil) }
                            .buttonStyle(.kit(.secondary, compact: true))
                            .disabled(!status.isUsable)
                            .help(action.note)
                    }
                }
                if !perRepo.isEmpty {
                    Text("On each product's page: \(perRepo.map(\.label).joined(separator: ", ")).").kitType(.meta, Ink.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The installed tools that run against a repository, on the product's Overview tab.
struct ProductToolsCard: View {
    @Environment(AppModel.self) private var model
    let product: Product
    @State private var checkoutID: UUID?

    var body: some View {
        let _ = model.toolsVersion
        let usable = Toolbox.catalog.filter { Toolbox.status($0).isUsable && $0.actions.contains { $0.scope == .checkout } }
        let checkout = product.checkout(id: checkoutID) ?? product.primaryCheckout
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Tools", subtitle: checkout.map { "Run on \($0.name). Output opens in a log." } ?? "Checks from the Toolbox") {
                if product.checkouts.count > 1 {
                    Menu(checkout?.name ?? "Checkout") {
                        ForEach(product.checkouts) { item in Button(item.name) { checkoutID = item.id } }
                    }
                    .menuStyle(.button).buttonStyle(.kit(.secondary, compact: true)).fixedSize()
                }
                Button("Toolbox") { model.go(.toolbox) }.buttonStyle(.kit(.link))
            }
            .padding(Space.lg)
            if product.isDemo || checkout == nil {
                Text(product.isDemo ? "Demo products have no code to check." : "Link a checkout to run tools on it.").kitType(.label, Ink.text2)
                    .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
            } else if usable.isEmpty {
                Text("No tools installed yet. Open the Toolbox to add some.").kitType(.label, Ink.text2).padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
            } else if let checkout {
                ForEach(usable) { spec in row(spec, checkout: checkout) }
            }
        }
        .card()
    }

    private func row(_ spec: ToolSpec, checkout: LocalCheckout) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            Text(spec.name).kitType(.labelMedium).frame(width: 120, alignment: .leading).lineLimit(1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(spec.actions.filter { $0.scope == .checkout }) { action in
                        let missing = action.requiresFile.flatMap { FileManager.default.fileExists(atPath: (checkout.path as NSString).appendingPathComponent($0)) ? nil : $0 }
                        Button(action.label) { model.runTool(action, of: spec, product: product, checkout: checkout) }
                            .buttonStyle(.kit(action.safety >= .localWrite ? .ghost : .secondary, compact: true))
                            .disabled(missing != nil)
                            .help(action.note + (missing.map { " Needs \($0) in the checkout." } ?? ""))
                    }
                }
            }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineAbove()
    }
}

/// The Agent Skills section of the Toolbox: popular skill repositories and a field to add any GitHub repository.
struct SkillsSection: View {
    @Environment(AppModel.self) private var model
    @State private var custom = ""

    var body: some View {
        let _ = model.skillsVersion
        let home = model.agentHomeURL
        let installed = AgentSkills.installed(home: home)
        let catalogIDs = Set(AgentSkills.catalog.map(\.id))
        let others = Array(Set(installed.map(\.receipt.repository)).subtracting(catalogIDs)).sorted()
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Skills").kitType(.cardTitle)
                Text("Instructions an agent loads when a task needs them. \(Brand.name) downloads a repository, you pick its skills, and they go into Claude Code's skills folder and the shared agents folder.")
                    .kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Space.md, alignment: .top)], spacing: Space.md) {
                addCard
                ForEach(others, id: \.self) { repository in
                    card(SkillRepository(id: repository, name: repository, summary: "Added from GitHub.", knownSkills: []), installed: installed, home: home)
                }
                ForEach(AgentSkills.catalog) { repository in card(repository, installed: installed, home: home) }
            }
        }
    }

    private var addCard: some View {
        let busy = model.fetchingSkills != nil
        return SurfaceCard {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Add a skill repository").kitType(.bodyStrong)
                Text("Any public GitHub repository with SKILL.md folders. Paste owner/repo, its link, or an npx skills add command.").kitType(.label, Ink.text2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.xs) {
                    KitField(placeholder: "owner/repo or npx skills add …", text: $custom, icon: .search, monospaced: true)
                        .onSubmit { lookUp() }
                    Button("Look Up") { lookUp() }.buttonStyle(.kit(.secondary, compact: true))
                        .disabled(busy || AgentSkills.parseSource(custom) == nil)
                }
                if let source = AgentSkills.parseSource(custom), source.fromCommand {
                    Text(commandSummary(source)).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                }
                if let fetching = model.fetchingSkills { progress("Downloading \(fetching)…") }
            }
        }
    }

    /// What ForgeDeck read from a pasted npx command, shown before it is looked up.
    private func commandSummary(_ source: AgentSkills.Source) -> String {
        var parts = ["Reads the command instead of running npx: \(source.repository)\(source.ref.map { " at \($0)" } ?? "")"]
        if let skills = source.skills { parts.append("skills \(skills.joined(separator: ", "))") }
        if let targets = source.targets { parts.append("for \(SkillTarget.allCases.filter(targets.contains).map(\.title).joined(separator: " and "))") }
        return parts.joined(separator: ", ") + ". Installs for your user, like -g."
    }

    private func lookUp() {
        guard AgentSkills.parseSource(custom) != nil else { return }
        model.lookUpSkills(custom)
        custom = ""
    }

    private func card(_ repository: SkillRepository, installed: [AgentSkills.Installed], home: URL) -> some View {
        let ours = installed.filter { $0.receipt.repository == repository.id }
        let names = Set(ours.map(\.name))
        let present = AgentSkills.present(repository, home: home)
        let fetching = model.fetchingSkills == repository.id
        return SurfaceCard {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Text(repository.name).kitType(.bodyStrong).lineLimit(1)
                    if !names.isEmpty {
                        StatusPill("Added · \(AppModel.count(names.count, "skill"))", tone: .ok)
                    } else if !present.isEmpty {
                        StatusPill("Found on this Mac", tone: .accent).help("\(present.joined(separator: ", ")) is in an agent's skills folder, added some other way. \(Brand.name) never replaces it.")
                    } else {
                        StatusPill("Not added", tone: .muted)
                    }
                    Spacer(minLength: Space.xs)
                    IconButton(.external, label: "Open \(repository.url)") { model.openLink(repository.url) }
                }
                Text(repository.summary).kitType(.label, Ink.text).fixedSize(horizontal: false, vertical: true)
                Text(repository.id).kitType(.monoSmall, Ink.text3)
                if !names.isEmpty {
                    Text(names.sorted().joined(separator: ", ")).kitType(.meta, Ink.text2).lineLimit(2)
                }
                HStack(spacing: Space.xs) {
                    if fetching {
                        progress("Downloading…")
                    } else {
                        Button(names.isEmpty ? "Add Skills…" : "Update…") { model.lookUpSkills(repository.id) }
                            .buttonStyle(.kit(names.isEmpty ? .primary : .secondary, compact: true))
                            .disabled(model.fetchingSkills != nil)
                            .help("Downloads \(repository.id) and lists its skills to choose from")
                    }
                    if !names.isEmpty {
                        Button("Remove…") { model.confirmRemoveSkills(repository.id) }.buttonStyle(.kit(.ghost, compact: true))
                    }
                }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Space.xs) {
            ProgressView().controlSize(.small)
            Text(text).kitType(.label, Ink.text2)
        }
        .accessibilityElement(children: .combine)
    }
}
