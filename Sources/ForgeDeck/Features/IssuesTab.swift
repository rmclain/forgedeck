import ForgeDeckKit
import SwiftUI

// The Issues tab: a to-do list per product. Implement with the agent opens it in a terminal with the item;
// the agent asks about the item before it changes anything. Copying to GitHub is off until turned on here.

extension AppModel {
    /// Shows the product's Issues tab with the cursor in the add field.
    func newIssue(_ product: Product) {
        route = .product(product.id)
        productTab = .issues
        focusIssueField = true
    }

    @discardableResult
    func addIssue(_ text: String, to product: Product) -> Bool {
        guard !product.isDemo, let issue = ProductIssues.make(from: text) else { return false }
        update(product.id) { $0.issues = [issue] + ($0.issues ?? []) }
        record("issue.add", product: product)
        return true
    }

    func updateIssue(_ id: UUID, in product: Product, _ change: (inout ProductIssue) -> Void) {
        update(product.id) { product in
            guard let index = product.issues?.firstIndex(where: { $0.id == id }) else { return }
            change(&product.issues![index])
        }
    }

    func setIssueDone(_ issue: ProductIssue, _ done: Bool, in product: Product) {
        updateIssue(issue.id, in: product) {
            $0.isDone = done
            $0.doneAt = done ? .now : nil
        }
        record(done ? "issue.done" : "issue.reopen", product: product)
    }

    /// Removes it from this Mac. A GitHub issue made from it stays on GitHub.
    func deleteIssue(_ issue: ProductIssue, from product: Product) {
        update(product.id) { $0.issues?.removeAll { $0.id == issue.id } }
        record("issue.delete", product: product, detail: issue.githubNumber.map { "github=#\($0)" } ?? "")
        show(issue.githubNumber == nil ? "Deleted \u{201C}\(issue.title)\u{201D}." : "Deleted \u{201C}\(issue.title)\u{201D} here. Issue #\(issue.githubNumber!) stays on GitHub.")
    }

    /// Opens the agent in the product's folder with the item as its first message.
    func implementIssue(_ issue: ProductIssue, in product: Product) {
        guard let checkout = checkout(for: product) else { return }
        let program = portfolio.settings.aiAgentProgram
        let title = issue.title.count > 32 ? String(issue.title.prefix(31)) + "…" : issue.title
        startSetupAgent(product, checkout: checkout, prompt: ProductIssues.prompt(for: issue, product: product), title: title, audit: "issue.implement")
        updateIssue(issue.id, in: product) {
            $0.startedAt = .now
            $0.startedWith = program
        }
    }

    func setIssuesToGitHub(_ on: Bool, for product: Product) {
        update(product.id) { $0.issuesToGitHub = on ? true : nil }
        record("issue.github.\(on ? "on" : "off")", product: product)
    }

    /// A remote write, so it asks first with press and hold. Runs `gh issue create` with the person's own gh login.
    func copyIssueToGitHub(_ issue: ProductIssue, in product: Product) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. Nothing goes to GitHub.", isError: true) }
        guard product.issuesToGitHub == true, let repo = ProductIssues.repository(product) else {
            return show("Turn on Add to GitHub in \(product.name)'s Issues tab, with a GitHub repository linked.", isError: true)
        }
        guard ExecutableLocator.find("gh") != nil else {
            return show("The GitHub CLI (gh) is not installed. Install it and run gh auth login, then try again.", isError: true)
        }
        sheet = .confirm(ConfirmRequest(
            title: "Add to GitHub?",
            message: "Creates a public record: a new issue in \(repo.owner)/\(repo.name) with this title and notes, as your GitHub account.",
            checks: [.init(label: "Repository", meta: "\(repo.owner)/\(repo.name)", ok: true),
                     .init(label: "Title", meta: issue.title, ok: true),
                     .init(label: "Notes", meta: issue.notes.isEmpty ? "none" : "\(issue.notes.count) characters, secrets redacted", ok: true)],
            footnote: "Uses gh issue create with your gh login. ForgeDeck's own GitHub token stays read-only.",
            confirmLabel: "Add Issue", requiresHold: true, icon: .branch,
            action: { [weak self] in await self?.createGitHubIssue(issue, in: product, repo: repo) }))
    }

    private func createGitHubIssue(_ issue: ProductIssue, in product: Product, repo: Repository) async {
        guard let gh = ExecutableLocator.find("gh") else { return }
        let arguments = ProductIssues.githubCreateArguments(issue, repository: repo)
        let result = try? await SystemProcessRunner().run(ProcessRequest(executable: gh, arguments: arguments, workingDirectory: agentHomeURL,
                                                                         timeout: 60, stdin: Data()))
        guard let result, result.ok, let created = ProductIssues.createdIssue(fromOutput: result.stdout, repository: repo) else {
            let text = ((result?.stderr ?? "") + "\n" + (result?.stdout ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = text.split(separator: "\n").first.map(String.init) ?? "gh did not finish"
            record("issue.github", product: product, detail: "repo=\(repo.owner)/\(repo.name)", outcome: "failed")
            return show("Could not add it to GitHub: \(reason)", isError: true)
        }
        updateIssue(issue.id, in: product) {
            $0.githubNumber = created.number
            $0.githubURL = created.url
        }
        record("issue.github", product: product, detail: "repo=\(repo.owner)/\(repo.name) number=\(created.number)")
        show("Added as issue #\(created.number) in \(repo.owner)/\(repo.name).")
    }
}

struct IssuesTab: View {
    @Environment(AppModel.self) private var model
    let product: Product
    @State private var draft = ""
    @State private var showDone = false
    @State private var editingID: UUID?
    @State private var editTitle = ""
    @State private var editNotes = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        let all = ProductIssues.sorted(product.issues ?? [])
        let open = all.filter { !$0.isDone }
        let done = all.filter(\.isDone)
        let shown = showDone ? done : open
        let agent = AgentCatalog.name(model.portfolio.settings.aiAgentProgram)
        VStack(alignment: .leading, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Issues", subtitle: "A to-do list for \(product.name). \(agent) asks about an item before it starts on it.") {
                    if product.isDemo { DemoBadge() }
                    SegmentedPill(options: [(false, "Open \(open.count)"), (true, "Done \(done.count)")], selection: $showDone, compact: true)
                }
                .padding(Space.lg)
                HStack(spacing: Space.sm) {
                    KitField(placeholder: "Add an issue. A short note is enough.", text: $draft, icon: .plus)
                        .focused($addFocused)
                        .onSubmit(add)
                    Button("Add") { add() }.buttonStyle(.kit(.secondary, compact: true))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || product.isDemo)
                }
                .disabled(product.isDemo)
                .padding(.horizontal, Space.lg).padding(.bottom, Space.lg)
                if shown.isEmpty {
                    Text(showDone ? "Nothing done yet." : "Nothing open. Add what you want to fix or build; \(agent) asks for the details when you start it.")
                        .kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.md).hairlineAbove()
                }
                ForEach(shown) { issue in
                    if editingID == issue.id { editor(issue) } else { row(issue, agent: agent) }
                }
            }
            .card()
            githubCard
        }
        .onChange(of: model.focusIssueField) { _, wanted in
            if wanted { addFocused = true; model.focusIssueField = false }
        }
    }

    private func add() {
        if model.addIssue(draft, to: product) {
            draft = ""
            showDone = false
        }
    }

    private func row(_ issue: ProductIssue, agent: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Toggle(isOn: Binding(get: { issue.isDone }, set: { model.setIssueDone(issue, $0, in: product) })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(product.isDemo)
                .accessibilityLabel(issue.isDone ? "Mark \(issue.title) open" : "Mark \(issue.title) done")
                .help(issue.isDone ? "Mark open" : "Mark done")
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).kitType(.labelMedium, issue.isDone ? Ink.text3 : Ink.text).strikethrough(issue.isDone, color: Ink.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if !issue.notes.isEmpty { Text(issue.notes).kitType(.meta, Ink.text2).lineLimit(2) }
                Text(meta(issue)).kitType(.meta, Ink.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if !product.isDemo { startEditing(issue) } }
            if let number = issue.githubNumber {
                Button("#\(number)") { if let url = issue.githubURL { model.openLink(url) } }
                    .buttonStyle(.kit(.link)).help("Open issue #\(number) on GitHub")
            }
            if !issue.isDone {
                Button("Implement with \(agent)") { model.implementIssue(issue, in: product) }
                    .buttonStyle(.kit(.secondary, compact: true)).fixedSize()
                    .disabled(product.isDemo || !product.hasLocal)
                    .help("Opens \(agent) in \(product.name) with this item. It reads the code and asks you about it before it changes anything.")
            }
            Menu {
                Button("Edit") { startEditing(issue) }
                if product.issuesToGitHub == true, issue.githubNumber == nil {
                    Button("Add to GitHub…") { model.copyIssueToGitHub(issue, in: product) }
                }
                Button(issue.isDone ? "Mark Open" : "Mark Done") { model.setIssueDone(issue, !issue.isDone, in: product) }
                Divider()
                Button("Delete", role: .destructive) { model.deleteIssue(issue, from: product) }
            } label: { Icon(.more, size: 13) }
                .menuStyle(.button).buttonStyle(.kit(.icon)).menuIndicator(.hidden).fixedSize()
                .disabled(product.isDemo)
                .help("More for this item").accessibilityLabel("More for \(issue.title)")
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
        .hairlineAbove()
    }

    private func meta(_ issue: ProductIssue) -> String {
        var parts = ["Added \(issue.createdAt.formatted(.relative(presentation: .named)))"]
        if let done = issue.doneAt, issue.isDone { parts.append("done \(done.formatted(.relative(presentation: .named)))") }
        if let started = issue.startedAt, !issue.isDone {
            parts.append("started with \(AgentCatalog.name(issue.startedWith ?? "")) \(started.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private func startEditing(_ issue: ProductIssue) {
        editTitle = issue.title
        editNotes = issue.notes
        editingID = issue.id
    }

    private func editor(_ issue: ProductIssue) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            KitField(placeholder: "Title", text: $editTitle)
            TextEditor(text: $editNotes).font(KitType.body.font).scrollContentBackground(.hidden).padding(Space.xs)
                .frame(height: 88).background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.controlRadius))
                .overlay(alignment: .topLeading) {
                    if editNotes.isEmpty {
                        Text("Notes: what you saw, where, what done looks like. Optional; the agent asks for what is missing.")
                            .kitType(.label, Ink.text3).padding(Space.sm).allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                Button("Cancel") { editingID = nil }.buttonStyle(.kit(.ghost, compact: true)).keyboardShortcut(.cancelAction)
                Button("Save") {
                    let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    model.updateIssue(issue.id, in: product) {
                        $0.title = String(title.prefix(ProductIssues.maxTitle))
                        $0.notes = String(editNotes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ProductIssues.maxNotes))
                    }
                    editingID = nil
                }
                .buttonStyle(.kit(.secondary, compact: true))
                .disabled(editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.lg)
        .hairlineAbove()
    }

    private var githubCard: some View {
        let repo = ProductIssues.repository(product)
        return HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add to GitHub").kitType(.labelMedium)
                Text(repo.map { "Off: issues stay on this Mac. On: each item's menu can add it as an issue in \($0.owner)/\($0.name), using your gh login, after you confirm." }
                     ?? "Link a GitHub repository in Connections to add items to it as issues.")
                    .kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            Toggle("Add to GitHub", isOn: Binding(get: { product.issuesToGitHub == true }, set: { model.setIssuesToGitHub($0, for: product) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(repo == nil || product.isDemo)
        }
        .padding(Space.lg)
        .card()
    }
}
