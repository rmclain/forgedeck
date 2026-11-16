import ForgeDeckKit
import SwiftUI

extension AppModel {
    /// Opens the install command in a terminal, where it is visible and runs with your own permissions.
    func install(_ spec: ToolSpec) {
        guard let command = Toolbox.installCommand(spec) else {
            return show("No installer for \(spec.name) is available here. See \(spec.homepage).", isError: true)
        }
        Task {
            let outcome = await launcher.run(command: command, in: NSHomeDirectory(), terminalBundleID: terminalForCommands)
            if outcome.didOpen {
                record("tool.install", detail: "tool=\(spec.id) via=\((command.first.map { ($0 as NSString).lastPathComponent }) ?? "")")
                show("Installing \(spec.name) in the terminal. Press Refresh here when it finishes.")
                toolsVersion += 1
            } else if case .failed(let reason, let copy) = outcome {
                if let copy { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copy, forType: .string) }
                show("\(reason)\(copy == nil ? "" : " The command was copied.")", isError: true)
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
    @State private var productID: UUID?

    private var product: Product? { model.product(productID) ?? model.activeProducts.first { !$0.isDemo && $0.hasLocal } }

    var body: some View {
        let _ = model.toolsVersion
        let candidates = model.activeProducts.filter { !$0.isDemo && $0.hasLocal }
        Page {
            PageHeader(title: "Toolbox", subtitle: "Command-line tools that save AI tokens or check your repositories. \(Brand.name) finds them, opens installs in your terminal, and runs a few fixed, read-only actions. Nothing installs on its own.") {
                HStack(spacing: Space.sm) {
                    Text("Run against").kitType(.label, Ink.text3)
                    Menu(product?.name ?? "No checkout") {
                        ForEach(candidates) { candidate in Button(candidate.name) { productID = candidate.id } }
                    }
                    .menuStyle(.button).buttonStyle(.kit(.secondary)).fixedSize().disabled(candidates.isEmpty)
                    IconButton(.sync, label: "Check again for installed tools") { model.toolsVersion += 1 }
                }
            }
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
        let checkout = product?.primaryCheckout
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
                            Button("Install with \(spec.install.first { ExecutableLocator.find($0.command[0]) != nil }?.method.title ?? "")") { model.install(spec) }
                                .buttonStyle(.kit(.primary, compact: true))
                                .help(ShellQuote.join(command.map { ($0 as NSString).lastPathComponent == $0 ? $0 : ($0 as NSString).lastPathComponent }) + ", in your terminal")
                        } else {
                            Text("Install with: \(spec.install.map { $0.command.joined(separator: " ") }.joined(separator: "  or  "))").kitType(.monoSmall, Ink.text3)
                        }
                    }
                    ForEach(spec.actions) { action in
                        Button(action.label) { model.runTool(action, of: spec, product: action.scope == .global ? nil : product, checkout: action.scope == .global ? nil : checkout) }
                            .buttonStyle(.kit(action.safety >= .localWrite ? .ghost : .secondary, compact: true))
                            .disabled(!status.isUsable || (action.scope == .checkout && checkout == nil)
                                      || (action.requiresFile.map { file in checkout.map { !FileManager.default.fileExists(atPath: ($0.path as NSString).appendingPathComponent(file)) } ?? true } ?? false))
                            .help(action.note + (action.requiresFile.map { " Needs \($0)." } ?? ""))
                    }
                }
            }
        }
    }
}

/// The tool actions for one product, on its Actions tab.
struct ProductToolsCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let _ = model.toolsVersion
        let usable = Toolbox.catalog.filter { Toolbox.status($0).isUsable && $0.actions.contains { $0.scope == .checkout } }
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Tools", subtitle: "Read-only checks from the Toolbox") {
                Button("Toolbox") { model.go(.toolbox) }.buttonStyle(.kit(.link))
            }
            .padding(Space.lg)
            if product.isDemo || !product.hasLocal {
                Text(product.isDemo ? "Demo products have no code to check." : "Link a checkout to run tools on it.").kitType(.label, Ink.text2)
                    .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
            } else if usable.isEmpty {
                Text("No tools installed yet. Open the Toolbox to add some.").kitType(.label, Ink.text2).padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
            } else {
                ForEach(product.checkouts) { checkout in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(checkout.name).kitType(.labelMedium).frame(width: 140, alignment: .leading).lineLimit(1)
                        FlowButtons(items: usable.flatMap { spec in spec.actions.filter { $0.scope == .checkout }.map { (spec, $0) } }
                            .filter { _, action in action.requiresFile.map { FileManager.default.fileExists(atPath: (checkout.path as NSString).appendingPathComponent($0)) } ?? true }) { spec, action in
                            model.runTool(action, of: spec, product: product, checkout: checkout)
                        }
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineAbove()
                }
            }
        }
        .card()
    }
}

struct FlowButtons: View {
    let items: [(ToolSpec, ToolAction)]
    let run: (ToolSpec, ToolAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xs) {
                ForEach(items, id: \.1.id) { spec, action in
                    Button("\(spec.name): \(action.label)") { run(spec, action) }
                        .buttonStyle(.kit(action.safety >= .localWrite ? .ghost : .secondary, compact: true))
                        .help(action.note)
                }
            }
        }
    }
}
