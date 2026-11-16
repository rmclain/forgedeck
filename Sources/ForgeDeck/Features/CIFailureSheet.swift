import ForgeDeckKit
import SwiftUI

extension AppModel {
    /// The GitHub repository for CI: the product's first GitHub repository.
    func ciRepository(_ product: Product) -> Repository? {
        product.repositories.first { $0.provider == "github" && !$0.owner.isEmpty }
    }

    /// Finds the run (the given one, or the newest failed deploy, else the newest failure) and fetches its failing log.
    /// Uses ForgeDeck's GitHub token when one is connected, otherwise the `gh` CLI's own sign-in.
    func loadCIFailure(_ product: Product, runID: Int?) async throws -> CIFailureReport {
        guard let repo = ciRepository(product) else { throw CIError.noRepository }
        if let token = await engine.githubToken(portfolio) {
            let connector = GitHubConnector(token: token)
            let runs: [CIRun]
            switch await connector.runs(owner: repo.owner, name: repo.name) {
            case .success(let found), .partial(let found, _): runs = found
            case .failure(_, let detail, _): throw CIError.noAccess(detail)
            }
            guard let run = runID.flatMap({ id in runs.first { $0.id == id } }) ?? CILogDigest.pick(runs) else { throw CIError.noFailedRun }
            return try await connector.report(owner: repo.owner, name: repo.name, run: run)
        }
        let source = GHActionsSource()
        let runs = try await source.runs(repository: repo.fullName)
        guard let run = runID.flatMap({ id in runs.first { $0.id == id } }) ?? CILogDigest.pick(runs) else { throw CIError.noFailedRun }
        return try await source.report(repository: repo.fullName, run: run)
    }

    func ciBrief(_ report: CIFailureReport, product: Product) throws -> URL {
        let checkout = product.checkouts.first { $0.repositoryID == ciRepository(product)?.id } ?? product.primaryCheckout
        return try CIFixPrompt.write(report, product: product, checkout: checkout, git: checkout.flatMap { cache.git[$0.id] }, location: contextLocation)
    }

    /// Starts the agent in the checkout with the failure brief as its first message.
    func fixWithAgent(_ report: CIFailureReport, product: Product) {
        guard let checkout = product.checkouts.first(where: { $0.repositoryID == ciRepository(product)?.id }) ?? checkout(for: product) else { return }
        let program = portfolio.settings.aiAgentProgram
        guard let url = ExecutableLocator.find(program) else { return show("\(program) is not installed. Choose another agent in Settings.", isError: true) }
        do {
            let brief = try ciBrief(report, product: product)
            let bundle = try AgentContextBundle.write(for: product, checkout: checkout, portfolio: portfolio, cache: cache, location: contextLocation, mcp: mcpInfo(product))
            let command = CIFixPrompt.command(program: url, bundle: bundle, brief: brief, run: report.run, model: portfolio.settings.model(for: program))
            sheet = nil
            if terminalsInApp {
                runInTerminal(command, kind: .agent, title: "Fix \(report.run.workflow) · \(product.name)", product: product, checkout: checkout, directory: checkout.path)
            } else {
                Task {
                    let outcome = await launcher.run(command: command, in: checkout.path, terminalBundleID: terminalForCommands)
                    if !outcome.didOpen, case .failed(let reason, _) = outcome { show(reason, isError: true) }
                }
            }
            record("ci.fix", product: product, detail: "run=\(report.run.id) workflow=\(report.run.workflow) agent=\(program)")
        } catch {
            show("Could not write the brief: \(error.localizedDescription)", isError: true)
        }
    }
}

struct CIFailureSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    let runID: Int?
    @State private var report: CIFailureReport?
    @State private var error: String?
    @State private var loading = true

    private func load() {
        guard let product = model.product(productID) else { return }
        loading = true
        error = nil
        Task {
            do {
                report = try await model.loadCIFailure(product, runID: runID)
                model.record("ci.logs", product: product, detail: "run=\(report?.run.id ?? 0)")
            } catch {
                self.error = String(describing: error)
            }
            loading = false
        }
    }

    var body: some View {
        let product = model.product(productID)
        let agent = model.portfolio.settings.aiAgentProgram
        SheetPanel(width: 760, stripe: report.map { $0.run.isDeployment ? Ink.prod : Ink.err }) {
            SheetHeader(icon: .error, tone: .err, title: report.map { "\($0.run.workflow) failed" } ?? "Last CI failure",
                        message: report.map { "\($0.repository) · \($0.run.branch) · \(shortSHA($0.run.sha)) · \(RelativeTime.short($0.run.createdAt)) · from \($0.source)" }
                            ?? "Reading the newest failed run\(product.map { " for \($0.name)" } ?? "")…")
            VStack(alignment: .leading, spacing: Space.md) {
                if loading {
                    LoadingState(rows: 4, label: "Fetching the failing log")
                } else if let error {
                    ErrorState(title: "No log", detail: error, retry: load)
                } else if let report {
                    HStack(spacing: Space.xs) {
                        if report.run.isDeployment { TagBadge("Deploy", tone: .prod) }
                        ForEach(report.failedJobs, id: \.id) { job in
                            Chip("\(job.name)\(job.failedSteps.first.map { " › \($0)" } ?? "")")
                        }
                        Spacer()
                        Text("\(report.totalLines) lines → ~\(report.approxTokens) tokens").kitType(.meta, Ink.text3)
                    }
                    ScrollView {
                        Text(report.excerpt).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.text2)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Space.md)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 300)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous).strokeBorder(Ink.line, lineWidth: Metric.hairline))
                }
            }
            .padding(.horizontal, Space.xl)
            SheetFooter(note: "Read-only. Secrets and timestamps are removed. The agent is told not to push or deploy.") {
                if let report {
                    Button("Open Run") { model.openLink(report.run.url) }.buttonStyle(.kit(.secondary))
                    Button("Copy Prompt") {
                        guard let product, let brief = try? model.ciBrief(report, product: product),
                              let text = try? String(contentsOf: brief, encoding: .utf8) else { return }
                        model.copy(text, message: "Copied the fix prompt (~\(text.utf8.count / 4) tokens)")
                    }
                    .buttonStyle(.kit(.secondary))
                    .help("The brief with the log excerpt and the task, ready to paste into any assistant")
                }
                Button("Close") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                if let report, let product {
                    Button { model.fixWithAgent(report, product: product) } label: {
                        HStack(spacing: Space.xs) { Icon(.sparkle, size: 11); Text("Fix with \(AgentCatalog.name(agent))") }
                    }
                    .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(!product.hasLocal || product.isDemo)
                    .help(product.hasLocal ? "Starts \(agent) in the checkout with the failure brief as its first message" : "Clone or link a checkout first")
                }
            }
        }
        .onAppear(perform: load)
    }
}
