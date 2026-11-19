import AppKit
import ForgeDeckKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, launching, remote, data, cli, diagnostics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .launching: "Launching"
        case .remote: "Forge Remote"
        case .data: "Privacy & Data"
        case .cli: "Command Line"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .launching: "terminal"
        case .remote: "iphone.radiowaves.left.and.right"
        case .data: "lock.shield"
        case .cli: "chevron.left.forwardslash.chevron.right"
        case .diagnostics: "stethoscope"
        }
    }
}

@Observable
final class SettingsState {
    static let shared = SettingsState()
    var tab: SettingsTab = .general
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var state = SettingsState.shared
        TabView(selection: $state.tab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab).tabItem { Label(tab.title, systemImage: tab.symbol) }.tag(tab)
            }
        }
        .frame(width: 600)
        .noInitialFocus()
    }

    @ViewBuilder private func page(_ tab: SettingsTab) -> some View {
        @Bindable var model = model
        Form {
            switch tab {
            case .general:
                Section("Appearance") {
                    Picker("Appearance", selection: $model.portfolio.settings.appearance) {
                        Text("Match the Mac").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    TextField("Workspace name", text: Binding(get: { model.organizationName }, set: { name in
                        if model.portfolio.organizations.isEmpty { model.portfolio.organizations = [Organization(name: name)] } else { model.portfolio.organizations[0].name = name }
                    }))
                    Toggle("Show \(Brand.name) in the menu bar", isOn: $model.portfolio.settings.showMenuBarExtra)
                }
                Section {
                    Toggle("Check sources in the background", isOn: $model.portfolio.settings.pollingEnabled)
                    Picker("Every", selection: $model.portfolio.settings.pollingIntervalSeconds) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("1 hour").tag(3_600)
                    }
                    .disabled(!model.portfolio.settings.pollingEnabled)
                } header: { Text("Refresh") } footer: {
                    Text("Local Git state is read from disk. GitHub, status endpoints, and metrics sources are read-only network requests. Archived and demo products are never polled.")
                }
                Section("Keyboard") {
                    LabeledContent("Command palette", value: "⌘K")
                    LabeledContent("Open in terminal", value: "⌘O")
                    LabeledContent("Open in editor", value: "⌘⇧O")
                    LabeledContent("Refresh this page", value: "⌘R")
                    LabeledContent("Production / Staging context", value: "⌘⇧E")
                    LabeledContent("Pages", value: "⌘1 – ⌘8")
                }
            case .launching:
                let terminals = model.launcher.installed(KnownApps.terminals)
                let editors = model.launcher.installed(KnownApps.editors)
                Section {
                    Picker("Open terminals", selection: Binding(get: { model.portfolio.settings.terminalPlacement ?? "embedded" },
                                                                set: { model.portfolio.settings.terminalPlacement = $0 })) {
                        Text("Inside \(Brand.name)").tag("embedded")
                        Text("In the terminal app below").tag("external")
                    }
                    Picker("Terminal app", selection: $model.portfolio.settings.preferredTerminalBundleID) {
                        ForEach(terminals) { Text($0.verified ? $0.name : "\($0.name) (not verified)").tag($0.bundleID) }
                    }
                    Picker("Editor", selection: $model.portfolio.settings.preferredEditorBundleID) {
                        ForEach(editors) { Text($0.name).tag($0.bundleID) }
                    }
                    Picker("AI agent", selection: $model.portfolio.settings.aiAgentProgram) {
                        ForEach(AgentCatalog.all) { spec in
                            Text(ExecutableLocator.find(spec.program) == nil ? "\(spec.name) (not installed)" : spec.name).tag(spec.program)
                        }
                    }
                    AgentModelPicker(agent: model.portfolio.settings.aiAgentProgram)
                } header: { Text("Open with") } footer: {
                    Text("The model applies each time the agent starts from \(Brand.name); Default uses the agent's own setting. Folders open through macOS, so no Automation or Accessibility permission is needed. Ghostty, Warp, and Zed follow their documentation and were not exercised on a test Mac. An AI agent starts in the project folder: \(Brand.name) sends it nothing.")
                }
                Section {
                    ForEach(model.portfolio.settings.projectRoots, id: \.self) { root in
                        LabeledContent(abbreviate(root)) {
                            Button("Remove") { model.portfolio.settings.projectRoots.removeAll { $0 == root } }
                        }
                    }
                    Button("Add Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url, !model.portfolio.settings.projectRoots.contains(url.path) {
                            model.portfolio.settings.projectRoots.append(url.path)
                        }
                    }
                } header: { Text("Code folders") } footer: {
                    Text("A list of the folders you keep projects in, for your own reference. Nothing is scanned until you choose folders in Add Product.")
                }
            case .remote:
                ForgeRemoteSettingsView()
            case .data:
                Section {
                    Toggle("Ask for Touch ID or password before using production secrets", isOn: $model.portfolio.settings.requireAuthForProductionSecrets)
                    Picker("Hide a revealed secret after", selection: $model.portfolio.settings.revealTimeoutSeconds) {
                        Text("15 seconds").tag(15)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                    }
                    Picker("Keep observations for", selection: $model.portfolio.settings.cacheRetentionDays) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                } header: { Text("Privacy") } footer: {
                    Text("Secret values live in the macOS Keychain and nowhere else. \(Brand.name) has no account, no server, and sends no telemetry.")
                }
                Section {
                    LabeledContent("Data folder") {
                        Button(abbreviate(model.store.location.directory.path)) { NSWorkspace.shared.activateFileViewerSelecting([model.store.location.directory]) }
                            .buttonStyle(.link)
                    }
                    LabeledContent("Configuration") {
                        HStack {
                            Button("Export…") { model.exportConfiguration() }
                            Button("Import…") { model.importConfiguration() }
                        }
                    }
                    LabeledContent("Cached observations") { Button("Clear Cache") { model.clearCache() } }
                    LabeledContent("Demo products") {
                        HStack {
                            Button("Add 3") { model.addDemo(count: 3) }
                            Button("Add All 8") { model.addDemo(count: 8) }
                            Button("Remove") { model.removeDemo() }.disabled(!model.hasDemo)
                        }
                    }
                } header: { Text("Data") } footer: {
                    Text("An export holds products, environments, and variable names. Every credential becomes a placeholder to enter again. Clearing the cache keeps products and settings.")
                }
            case .cli:
                Section {
                    LabeledContent("Status", value: model.cliInstalledPath.map { "Installed at \(abbreviate($0))" } ?? "Not installed")
                    LabeledContent("Install") { Button(model.cliInstalledPath == nil ? "Install in ~/.local/bin" : "Reinstall") { model.installCLI() } }
                } header: { Text("\(Brand.cliName) command") } footer: {
                    Text("Creates one link to this app's binary. Your shell profile is not changed: add ~/.local/bin to PATH yourself if it is not there. The command shares the app's code signature, so it reads the same Keychain items.")
                }
                Section {
                    let _ = model.skillVersion
                    LabeledContent("Claude Code", value: model.isSkillInstalled ? "Installed in ~/.claude/skills/\(ForgeDeckSkill.name)" : "Not installed")
                    LabeledContent("Skill") {
                        HStack {
                            Button(model.isSkillInstalled ? "Update" : "Install") { model.installSkill() }
                            if model.isSkillInstalled { Button("Remove") { model.removeSkill() } }
                        }
                    }
                } header: { Text("Agent skill") } footer: {
                    Text("A short skill that tells Claude Code how to find a product and read only the context a task needs, through \(Brand.cliName). Claude Code loads its one-line description in every session and reads the rest only when you mention a product. It adds two commands: /\u{2060}products lists your products, numbered, and /\u{2060}product <number or name> puts the session on one. Forge Remote always has them, and \(Brand.name) keeps them up to date.")
                }
                Section("Examples") {
                    ForEach(["\(Brand.cliName) list", "\(Brand.cliName) find <part of a name>", "\(Brand.cliName) status <product> --json", "\(Brand.cliName) open <product>",
                             "\(Brand.cliName) env list <product> --environment development",
                             "\(Brand.cliName) exec --product <product> --environment development --profile tests -- npm test", "\(Brand.cliName) doctor"], id: \.self) { line in
                        Text(line).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    }
                }
            case .diagnostics:
                Section("This Mac") {
                    if let steps = model.doctorSteps[DoctorTarget.toolchain.id] {
                        ForEach(steps) { step in LabeledContent(step.title, value: step.detail) }
                    } else {
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                    Button("Check Again") { model.runDoctor(.toolchain) }
                }
                Section("Data") {
                    let problems = IntegrityChecker.problems(in: model.portfolio)
                    LabeledContent("Integrity", value: problems.isEmpty ? "References are sound" : problems.joined(separator: "; "))
                    LabeledContent("Products", value: "\(model.products.count)")
                    LabeledContent("Schema", value: "version \(Portfolio.currentSchemaVersion)")
                    LabeledContent("Audit log") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.location.auditURL]) }
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? CLI.version) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"))")
                    UpdatesRow()
                }
            }
        }
        .formStyle(.grouped)
        .fitsContent(max: 620)
        .onChange(of: model.portfolio.settings) { model.save() }
        .onAppear { if tab == .diagnostics, model.doctorSteps[DoctorTarget.toolchain.id] == nil, !Runtime.isAutomated { model.runDoctor(.toolchain) } }
    }
}

/// Settings › Forge Remote: a Claude Code Remote Control server that can reach every product.
struct ForgeRemoteSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        let settings = model.remoteSettings
        let installed = ExecutableLocator.find(ForgeRemote.program) != nil
        Section {
            Toggle("Turn on Forge Remote", isOn: Binding(get: { settings.enabled }, set: { model.setRemote(enabled: $0) }))
                .disabled(!installed && !settings.enabled)
            LabeledContent("Status") {
                HStack(spacing: Space.sm) {
                    Text(model.remoteStatus).foregroundStyle(Ink.text2).lineLimit(2)
                    if model.remoteSession != nil { Button("Show Terminal") { model.showRemoteTerminal() } }
                }
            }
        } header: { Text("Forge Remote") } footer: {
            Text("Runs Claude Code's Remote Control in the background, in a Forge Session folder. Sessions start almost empty and find products through the forgedeck skill, reading only what a task needs. Open the Claude app or claude.ai/code, pick the session, and name a product. Start a new session for each product. Only Claude Code has Remote Control; other agents keep working from the product pages.")
        }
        Section {
            LabeledContent("Session name") {
                TextField("", text: $name, prompt: Text("Forge Session"))
                    .labelsHidden()
                    .onSubmit { commitName() }
            }
            Picker("Approvals", selection: Binding(get: { settings.mode }, set: { mode in
                model.updateRemote { $0.permissionMode = mode.rawValue }
                model.restartRemote()
            })) {
                ForEach(ForgeRemoteSettings.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Keep this Mac awake while it runs", isOn: Binding(get: { settings.keepAwake }, set: { awake in
                model.updateRemote { $0.keepAwake = awake }
                model.restartRemote()
            }))
            LabeledContent("Forge Session folder") {
                Button(abbreviate(model.remoteWorkspace.folder.path)) { NSWorkspace.shared.activateFileViewerSelecting([model.remoteWorkspace.briefingFile]) }
                    .buttonStyle(.link)
            }
        } header: { Text("Sessions") } footer: {
            Text("Approvals come to your phone. Changing them restarts Forge Remote, which ends sessions that are open. The Mac stays awake but still sleeps when the lid closes. Production secrets need Touch ID at this Mac, so a remote session cannot use them. It runs while \(Brand.name) is open and starts again when \(Brand.name) opens.")
        }
        .onAppear { name = settings.name }
        .onDisappear { commitName() }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed != model.remoteSettings.name else { return }
        model.updateRemote { $0.name = trimmed.isEmpty ? "Forge Session" : trimmed }
        model.restartRemote()
    }
}

/// The model for one agent: the agent's own list when it has one, a few suggestions, or any name typed in.
struct AgentModelPicker: View {
    @Environment(AppModel.self) private var model
    let agent: String
    @State private var options: [(id: String, name: String)] = []
    @State private var custom = ""

    private var current: String { model.portfolio.settings.agentModels?[agent] ?? "" }

    private func set(_ value: String) {
        var models = model.portfolio.settings.agentModels ?? [:]
        models[agent] = value.isEmpty ? nil : value
        model.portfolio.settings.agentModels = models.isEmpty ? nil : models
    }

    var body: some View {
        LabeledContent("Model") {
            HStack {
                Picker("", selection: Binding(get: { current }, set: { set($0) })) {
                    Text("Default").tag("")
                    ForEach(options, id: \.id) { option in Text(option.name == option.id ? option.id : "\(option.name)").tag(option.id) }
                    if !current.isEmpty, !options.contains(where: { $0.id == current }) { Text(current).tag(current) }
                }
                .labelsHidden()
                TextField("or type a model", text: $custom).frame(width: 140).onSubmit { set(custom.trimmingCharacters(in: .whitespaces)); custom = "" }
            }
        }
        .task(id: agent) {
            guard let spec = AgentCatalog.spec(agent) else { return }
            options = Runtime.isAutomated ? spec.suggestedModels.map { (id: $0, name: $0) } : await AgentCatalog.models(spec)
        }
    }
}

// MARK: Menu bar

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let products = model.activeProducts
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Brand.name).kitType(.section)
                Spacer()
                Text(PortfolioPulse.headline(portfolio: model.portfolio, cache: model.cache, now: model.now)).kitType(.meta, Ink.text3).lineLimit(1)
            }
            .padding(Space.md)
            if !model.attentionIncidents.isEmpty {
                ForEach(model.attentionIncidents.prefix(3)) { incident in
                    HStack(spacing: Space.sm) {
                        Dot(color: Ink.err)
                        Text("\(model.product(incident.productID)?.name ?? ""): \(incident.title)").kitType(.label).lineLimit(1)
                        Spacer(minLength: Space.xs)
                        Button("Acknowledge") { model.acknowledge(incident) }.buttonStyle(.kit(.secondary, compact: true))
                    }
                    .padding(.horizontal, Space.md).padding(.vertical, Space.xs)
                }
                Ink.line.frame(height: Metric.hairline).padding(.vertical, Space.xs)
            }
            let favorites = products.filter(\.isFavorite).isEmpty ? Array(products.prefix(5)) : products.filter(\.isFavorite)
            if favorites.isEmpty {
                Text("No products yet").kitType(.label, Ink.text3).padding(Space.md)
            }
            ForEach(favorites) { product in
                HStack(spacing: Space.sm) {
                    ProjectIcon(product, size: 20)
                    Text(product.name).kitType(.labelMedium).lineLimit(1)
                    StatusPill(model.badge(product))
                    Spacer(minLength: Space.xs)
                    IconButton(.terminal, label: "Open \(product.name) in the terminal") { model.openTerminal(product) }.disabled(product.isDemo || !product.hasLocal)
                }
                .padding(.horizontal, Space.md).padding(.vertical, Space.xs)
            }
            Ink.line.frame(height: Metric.hairline).padding(.vertical, Space.xs)
            HStack {
                Button("Open \(Brand.name)") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.kit(.secondary, compact: true))
                Button("Refresh") { Task { await model.refreshAll() } }.buttonStyle(.kit(.secondary, compact: true))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.kit(.ghost, compact: true))
            }
            .padding(Space.md)
        }
        .frame(width: 340)
        .background(Ink.window)
    }
}

/// Settings › About: automatic checks, Check Now, and the last result.
struct UpdatesRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(UpdateSettings.autoKey) private var automatic = true

    private var status: String {
        if model.updateBusy { return model.updateProgress ?? "Checking…" }
        switch model.updateStatus {
        case .available(let release): return "\(release.version) is available"
        case .upToDate: return "Up to date"
        case .noDownload(let why), .failed(let why): return why
        case nil:
            let last = UserDefaults.standard.object(forKey: UpdateSettings.lastCheckKey) as? Date
            return last.map { "Checked \(RelativeTime.short($0, now: model.now))" } ?? "Not checked yet"
        }
    }

    var body: some View {
        if UpdateChecker.isValidRepository(UpdateSettings.repository) {
            Toggle("Check for updates once a day", isOn: $automatic)
                .help("Asks GitHub for the newest release of \(UpdateSettings.repository). Nothing about this Mac or your data is sent.")
            LabeledContent("Updates") {
                HStack(spacing: Space.sm) {
                    Text(status).foregroundStyle(Ink.text2).lineLimit(1)
                    if let release = model.availableUpdate {
                        Button("Install \(release.version)…") { model.sheet = .update(release) }
                    } else {
                        Button("Check Now") { Task { await model.checkForUpdates(userInitiated: true) } }.disabled(model.updateBusy)
                    }
                }
            }
        } else {
            LabeledContent("Updates", value: "This build has no update source. Rebuild with ./build.sh")
        }
    }
}
