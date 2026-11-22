import ForgeDeckKit
import SwiftUI

// Plans in the Issues tab. Plan with the agent asks it for a step-by-step plan and nothing else; the plan shows up
// here as a checklist. Execute sends the ticked steps and notes to the agent, Revise sends notes back for a new
// version, Discard removes it. Steps tick off as the agent reports them, and the plan moves to Done.

extension AppModel {
    func plans(_ product: Product) -> [FeaturePlan] { product.plans ?? [] }

    func plan(_ id: UUID, in productID: UUID) -> FeaturePlan? {
        product(productID)?.plans?.first { $0.id == id }
    }

    /// The plan made from an issue that is not finished yet, if any.
    func openPlan(for issue: ProductIssue, in product: Product) -> FeaturePlan? {
        plans(product).last { $0.linkedIssueIDs.contains(issue.id) && $0.phase != .done }
    }

    func updatePlan(_ id: UUID, in productID: UUID, _ change: (inout FeaturePlan) -> Void) {
        update(productID) { product in
            guard let index = product.plans?.firstIndex(where: { $0.id == id }) else { return }
            change(&product.plans![index])
        }
    }

    /// Records a new plan waiting for the agent. Separate from starting the agent so the self-test can use it.
    @discardableResult
    func beginPlan(_ request: String, issue: ProductIssue?, in product: Product) -> FeaturePlan? {
        beginPlan(request, issues: issue.map { [$0] } ?? [], in: product)
    }

    @discardableResult
    func beginPlan(_ request: String, issues: [ProductIssue], in product: Product) -> FeaturePlan? {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !product.isDemo, !text.isEmpty else { return nil }
        var plan = FeaturePlan(request: String(text.prefix(ProductIssues.maxNotes)), issueID: issues.count == 1 ? issues.first?.id : nil)
        if issues.count > 1 { plan.issueIDs = issues.map(\.id) }
        plan.startedWith = portfolio.agentProgram(for: product)
        update(product.id) { $0.plans = ($0.plans ?? []) + [plan] }
        record("plan.request", product: product, detail: issues.isEmpty ? "" : "from=issue count=\(issues.count)")
        return plan
    }

    /// Plan with the agent: it reads the code, may ask questions, and writes the plan. It changes nothing else.
    /// One plan for several selected items. Items that already have an open plan are left out and named.
    func planIssues(_ issues: [ProductIssue], in product: Product) {
        guard !issues.isEmpty else { return }
        if issues.count == 1, let issue = issues.first {
            return planFeature(issue.notes.isEmpty ? issue.title : issue.title + "\n" + issue.notes, issue: issue, in: product)
        }
        guard let checkout = checkout(for: product) else { return }
        let planned = issues.filter { openPlan(for: $0, in: product) != nil }
        let fresh = issues.filter { openPlan(for: $0, in: product) == nil }
        guard !fresh.isEmpty else { return show("Every selected item already has a plan. Review them under Plans.") }
        if fresh.count == 1, let issue = fresh.first {
            planFeature(issue.notes.isEmpty ? issue.title : issue.title + "\n" + issue.notes, issue: issue, in: product)
        } else {
            guard let plan = beginPlan(FeaturePlans.request(for: fresh), issues: fresh, in: product) else { return }
            startSetupAgent(product, checkout: checkout, prompt: FeaturePlans.planPrompt(plan, issues: fresh, product: product),
                            title: "Plan: \(fresh.count) issues", audit: "plan.start")
            route = .product(product.id)
            productTab = .issues
        }
        if !planned.isEmpty {
            show("Left out \(planned.count) item\(planned.count == 1 ? "" : "s") that already \(planned.count == 1 ? "has a plan" : "have plans").")
        }
    }

    func planFeature(_ request: String, issue: ProductIssue? = nil, in product: Product) {
        guard let checkout = checkout(for: product) else { return }
        if let issue, let existing = openPlan(for: issue, in: product) {
            if existing.phase == .ready { sheet = .plan(productID: product.id, planID: existing.id) }
            return show("\u{201C}\(issue.title)\u{201D} already has a plan: \(phaseText(existing, in: product)).")
        }
        guard let plan = beginPlan(request, issue: issue, in: product) else { return }
        startSetupAgent(product, checkout: checkout, prompt: FeaturePlans.planPrompt(plan, issue: issue, product: product),
                        title: "Plan: " + shortTitle(plan.name), audit: "plan.start")
        route = .product(product.id)
        productTab = .issues
    }

    private func shortTitle(_ text: String) -> String { text.count > 28 ? String(text.prefix(27)) + "…" : text }

    /// Copies a usable plan file into the plan that asked for it, and says so.
    func applyPlanFiles(_ files: [PlanFile], to productID: UUID) {
        guard !files.isEmpty, let product = product(productID), !product.isDemo, let plans = product.plans,
              plans.contains(where: { $0.phase == .planning }) else { return }
        let result = FeaturePlans.applyFiles(files, to: plans)
        guard !result.ready.isEmpty else { return }
        update(productID) { $0.plans = result.plans }
        for plan in result.ready {
            record("plan.ready", product: product, detail: "steps=\(plan.steps.count)")
        }
        let plan = result.ready[0]
        show("The plan \u{201C}\(plan.name)\u{201D} is ready: \(plan.steps.count) steps. Review it in \(product.name)'s Issues.")
    }

    /// Ticks off the steps the agent reported. A finished plan moves to Done, with the issue it came from.
    func applyPlanProgress(_ reports: [IssueReports.Report], to productID: UUID) {
        guard reports.contains(where: { !$0.steps.isEmpty }), let product = product(productID), !product.isDemo,
              let plans = product.plans, plans.contains(where: { $0.phase == .executing || $0.phase == .ready }) else { return }
        let result = FeaturePlans.applyProgress(reports, to: plans)
        guard result.stepsDone > 0 else { return }
        let finishedIssues = Set(result.finished.flatMap(\.linkedIssueIDs))
        update(productID) { product in
            product.plans = result.plans
            for index in (product.issues ?? []).indices where finishedIssues.contains(product.issues![index].id) && !product.issues![index].isDone {
                let plan = result.finished.first { $0.linkedIssueIDs.contains(product.issues![index].id) }
                product.issues![index].isDone = true
                product.issues![index].doneAt = .now
                product.issues![index].doneBy = plan?.startedWith
                product.issues![index].doneSummary = plan.map { "Done with the plan \u{201C}\($0.name)\u{201D}: \($0.progress.total) steps." }
            }
        }
        record("plan.progress", product: product, detail: "steps=\(result.stepsDone) finished=\(result.finished.count)")
        if let finished = result.finished.first {
            show("\(AgentCatalog.name(finished.startedWith ?? portfolio.agentProgram(for: product))) finished the plan \u{201C}\(finished.name)\u{201D}. Moved to Done."
                 + gitHubHint(finished.linkedIssueIDs.compactMap { id in product.issues?.first { $0.id == id } }))
        } else if let current = result.plans.first(where: { $0.phase == .executing }) {
            show("\(current.progress.done) of \(current.progress.total) steps done in \u{201C}\(current.name)\u{201D}.")
        }
    }

    /// Saves the person's choices, turns the left-out steps into issues, and marks the plan executing.
    /// Separate from sending so the self-test can use it.
    @discardableResult
    func recordExecution(_ planID: UUID, in product: Product, skipped: Set<String>, notes: [String: String]) -> FeaturePlan? {
        guard !product.isDemo, var plan = plan(planID, in: product.id), plan.phase == .ready else { return nil }
        for index in plan.steps.indices {
            let id = plan.steps[index].id
            plan.steps[index].skipped = skipped.contains(id) ? true : nil
            let note = notes[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            plan.steps[index].note = note.isEmpty ? nil : String(note.prefix(1_000))
        }
        guard !plan.chosenSteps.isEmpty else { return nil }
        plan.phase = .executing
        plan.executedAt = .now
        let leftOut = FeaturePlans.issuesForSkippedSteps(plan)
        let saved = plan
        update(product.id) { product in
            if let index = product.plans?.firstIndex(where: { $0.id == planID }) { product.plans![index] = saved }
            if !leftOut.isEmpty { product.issues = leftOut + (product.issues ?? []) }
        }
        record("plan.execute", product: product, detail: "steps=\(plan.chosenSteps.count) skipped=\(skipped.count)")
        return plan
    }

    /// Execute Plan: types the go-ahead into the agent's terminal, or starts a new session with the whole plan.
    func executePlan(_ planID: UUID, in product: Product, skipped: Set<String>, notes: [String: String], note: String) {
        guard let plan = recordExecution(planID, in: product, skipped: skipped, notes: notes) else {
            return show("Tick at least one step to execute.", isError: true)
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let leftOut = plan.steps.filter(\.isSkipped).count
        sendToAgent(product, line: FeaturePlans.executeMessage(plan, note: trimmed.isEmpty ? nil : trimmed),
                    prompt: FeaturePlans.executePrompt(plan, note: trimmed.isEmpty ? nil : trimmed, product: product),
                    title: "Build: " + shortTitle(plan.name), audit: "plan.execute.start",
                    done: "Sent \(plan.chosenSteps.count) steps to \(AgentCatalog.name(portfolio.agentProgram(for: product)))."
                        + (leftOut > 0 ? " \(leftOut) left-out step\(leftOut == 1 ? " is" : "s are") now open issues." : ""))
        sheet = nil
    }

    /// Revise: sends the notes back and waits for a new version of the plan.
    func revisePlan(_ planID: UUID, in product: Product, skipped: Set<String>, notes: [String: String], note: String) {
        guard !product.isDemo, var plan = plan(planID, in: product.id), plan.phase == .ready else { return }
        for index in plan.steps.indices {
            plan.steps[index].skipped = skipped.contains(plan.steps[index].id) ? true : nil
            plan.steps[index].note = notes[plan.steps[index].id].flatMap { $0.isEmpty ? nil : $0 }
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = FeaturePlans.reviseMessage(plan, note: trimmed)
        updatePlan(planID, in: product.id) {
            $0.phase = .planning
            $0.requestedAt = .now
            $0.revisions = ($0.revisions ?? 0) + 1
        }
        let issues = plan.linkedIssueIDs.compactMap { id in product.issues?.first { $0.id == id } }
        sendToAgent(product, line: line,
                    prompt: FeaturePlans.planPrompt(plan, issues: issues, product: product) + "\n\nThis is a revision. " + line,
                    title: "Plan: " + shortTitle(plan.name), audit: "plan.revise",
                    done: "Asked \(AgentCatalog.name(portfolio.agentProgram(for: product))) to revise the plan.")
        sheet = nil
    }

    /// Types one line into the product's running agent and presses Return; with no agent running, starts one.
    private func sendToAgent(_ product: Product, line: String, prompt: String, title: String, audit: String, done: String) {
        guard let current = self.product(product.id), let checkout = checkout(for: current) else { return }
        if let session = agentSession(current), session.isRunning {
            session.view.pasteText(line)
            // The paste lands asynchronously; Return goes after it.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                session.send("\r")
            }
            watchAgentFiles(current) { [weak session] in session?.isRunning == true }
            terminals.select(session)
            record(audit, product: current, detail: "into=running")
            return show(done)
        }
        startSetupAgent(current, checkout: checkout, prompt: prompt, title: title, audit: audit)
    }

    /// Mark Done also moves the plan's open items to Done; Mark Open leaves them as they are.
    func setPlanDone(_ plan: FeaturePlan, _ done: Bool, in product: Product) {
        let linked = Set(plan.linkedIssueIDs)
        let summary = "Done with the plan \u{201C}\(plan.name)\u{201D}."
        update(product.id) { product in
            guard done else { return }
            for index in (product.issues ?? []).indices where linked.contains(product.issues![index].id) && !product.issues![index].isDone {
                product.issues![index].isDone = true
                product.issues![index].doneAt = .now
                product.issues![index].doneBy = nil
                product.issues![index].doneSummary = summary
            }
        }
        updatePlan(plan.id, in: product.id) {
            if done {
                $0.phase = .done
                $0.doneAt = .now
            } else {
                $0.phase = $0.executedAt == nil ? ($0.steps.isEmpty ? .planning : .ready) : .executing
                $0.doneAt = nil
                $0.requestedAt = .now
            }
        }
        record(done ? "plan.done" : "plan.reopen", product: product)
    }

    /// Removes it from this Mac. Work the agent already did stays in the code.
    func deletePlan(_ plan: FeaturePlan, from product: Product) {
        update(product.id) { $0.plans?.removeAll { $0.id == plan.id } }
        record("plan.delete", product: product)
        if case .plan(_, let open) = sheet, open == plan.id { sheet = nil }
        show("Deleted the plan \u{201C}\(plan.name)\u{201D}.")
    }

    func phaseText(_ plan: FeaturePlan, in product: Product? = nil) -> String {
        let agent = AgentCatalog.name(plan.startedWith ?? portfolio.agentProgram(for: product))
        switch plan.phase {
        case .planning: return plan.revisions == nil ? "waiting for \(agent)'s plan" : "waiting for \(agent)'s revision"
        case .ready: return "ready to review"
        case .executing: return "\(plan.progress.done) of \(plan.progress.total) steps done"
        case .done: return "done"
        }
    }
}

/// The plans section of the Issues tab: open plans in the Open list, finished ones in the Done list.
struct PlanRows: View {
    @Environment(AppModel.self) private var model
    let product: Product
    let plans: [FeaturePlan]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.sm) {
                Text("Plans").kitType(.labelMedium, Ink.text2)
                Text("\(plans.count)").kitType(.meta, Ink.text3)
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairlineAbove()
            ForEach(plans) { row($0) }
        }
    }

    private func row(_ plan: FeaturePlan) -> some View {
        let problems = FeaturePlans.problems(model.planFiles[product.id] ?? [], for: plan)
        return HStack(alignment: .top, spacing: Space.md) {
            Icon(plan.phase == .done ? .check : .checklist, size: 13).foregroundStyle(plan.phase == .done ? Ink.ok : Ink.accent)
                .frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.name).kitType(.labelMedium, plan.phase == .done ? Ink.text3 : Ink.text).fixedSize(horizontal: false, vertical: true)
                if let summary = plan.summary, plan.phase != .planning { Text(summary).kitType(.meta, Ink.text2).lineLimit(2) }
                Text(meta(plan)).kitType(.meta, Ink.text3)
                if !problems.isEmpty {
                    Text("The plan file has a problem: \(problems[0]) Tell the agent in its terminal.")
                        .kitType(.meta, Ink.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if plan.phase != .planning { model.sheet = .plan(productID: product.id, planID: plan.id) } }
            phaseControl(plan)
            Menu {
                if plan.phase != .planning { Button("Open") { model.sheet = .plan(productID: product.id, planID: plan.id) } }
                Button(plan.phase == .done ? "Mark Open" : "Mark Done") { model.setPlanDone(plan, plan.phase != .done, in: product) }
                Divider()
                Button("Delete", role: .destructive) { model.deletePlan(plan, from: product) }
            } label: { Icon(.more, size: 13) }
                .menuStyle(.button).buttonStyle(.kit(.icon)).menuIndicator(.hidden).fixedSize()
                .disabled(product.isDemo)
                .help("More for this plan").accessibilityLabel("More for the plan \(plan.name)")
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
        .hairlineAbove()
    }

    @ViewBuilder private func phaseControl(_ plan: FeaturePlan) -> some View {
        switch plan.phase {
        case .planning:
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.mini)
                Text("Planning").kitType(.label, Ink.text2)
            }
            .fixedSize()
            .help("The agent is reading the code and writing the plan. Answer its questions in its terminal.")
        case .ready:
            Button("Review Plan…") { model.sheet = .plan(productID: product.id, planID: plan.id) }
                .buttonStyle(.kit(.secondary, compact: true)).fixedSize()
                .help("Tick the steps to do, add notes, then execute, revise, or discard it")
        case .executing:
            StatusPill("\(plan.progress.done) of \(plan.progress.total)", tone: .accent)
                .help("Steps the agent has reported done")
        case .done:
            EmptyView()
        }
    }

    private func meta(_ plan: FeaturePlan) -> String {
        let agent = AgentCatalog.name(plan.startedWith ?? model.portfolio.agentProgram(for: product))
        var parts: [String] = []
        switch plan.phase {
        case .planning:
            parts.append((plan.revisions == nil ? "Asked \(agent) " : "Asked \(agent) to revise ")
                         + plan.requestedAt.formatted(.relative(presentation: .named)))
        case .ready:
            parts.append("Ready to review · \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")")
            if let questions = plan.questions, !questions.isEmpty { parts.append("\(questions.count) open question\(questions.count == 1 ? "" : "s")") }
        case .executing:
            parts.append("\(agent) is working · \(plan.progress.done) of \(plan.progress.total) steps done")
        case .done:
            parts.append("Done \((plan.doneAt ?? plan.createdAt).formatted(.relative(presentation: .named))) · \(plan.progress.total) steps")
        }
        if plan.linkedIssueIDs.count > 1 {
            parts.append("from \(plan.linkedIssueIDs.count) issues")
        } else if let issueID = plan.issueID, let issue = product.issues?.first(where: { $0.id == issueID }) {
            parts.append("from \u{201C}\(issue.title)\u{201D}")
        }
        return parts.joined(separator: " · ")
    }
}

/// The plan as a checklist. Ready: tick steps, add notes, execute, revise, or discard. Later: progress.
struct PlanSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    let planID: UUID
    @State private var skipped: Set<String> = []
    @State private var notes: [String: String] = [:]
    @State private var noting: Set<String> = []
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        let product = model.product(productID)
        let plan = model.plan(planID, in: productID)
        let agent = AgentCatalog.name(plan?.startedWith ?? model.portfolio.agentProgram(for: product))
        let reviewing = plan?.phase == .ready
        let chosen = (plan?.steps ?? []).filter { !skipped.contains($0.id) }.count
        SheetPanel(width: 720) {
            SheetHeader(icon: .checklist, title: plan?.name ?? "Plan", message: plan.map { message($0, agent: agent) })
            ScrollView {
                if let plan, let product {
                    content(plan, product: product, reviewing: reviewing)
                        .padding(.horizontal, Space.xl).padding(.bottom, Space.sm)
                } else {
                    EmptyState(icon: .checklist, title: "No plan", message: "It was deleted.", compact: true).padding(.horizontal, Space.xl)
                }
            }
            .frame(maxHeight: 600)
            .fixedSize(horizontal: false, vertical: true) // short plans don't leave an empty panel
            SheetFooter(note: reviewing ? (product?.isDemo == true ? "Demo plan. Nothing is sent." : "Left-out steps become open issues.") : "") {
                if reviewing, let plan, let product {
                    Button("Discard Plan") { model.deletePlan(plan, from: product) }
                        .buttonStyle(.kit(.ghost)).disabled(product.isDemo)
                        .help("Delete this plan. Nothing in the code changes.")
                    Spacer(minLength: Space.sm)
                    Button("Revise") { model.revisePlan(plan.id, in: product, skipped: skipped, notes: notes, note: note) }
                        .buttonStyle(.kit(.secondary)).disabled(product.isDemo)
                        .help("Send your notes and unticked steps back to \(agent) for a new version")
                    Button(chosen == plan.steps.count ? "Execute Plan" : "Execute \(chosen) Step\(chosen == 1 ? "" : "s")") {
                        model.executePlan(plan.id, in: product, skipped: skipped, notes: notes, note: note)
                    }
                    .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(product.isDemo || chosen == 0)
                    .help("Send the ticked steps and your notes to \(agent)")
                } else {
                    Button("Close") { model.sheet = nil }.buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            guard !loaded, let plan else { return }
            loaded = true
            skipped = Set(plan.steps.filter(\.isSkipped).map(\.id))
            notes = Dictionary(uniqueKeysWithValues: plan.steps.compactMap { step in step.note.map { (step.id, $0) } })
            noting = Set(notes.keys)
        }
    }

    private func message(_ plan: FeaturePlan, agent: String) -> String {
        switch plan.phase {
        case .planning: "Waiting for \(agent) to write the plan."
        case .ready: "\(agent)'s plan. Nothing changes until you execute it. Untick steps you don't want; add a note to any step."
        case .executing: "\(agent) is working through it: \(plan.progress.done) of \(plan.progress.total) steps done."
        case .done: "Done \((plan.doneAt ?? plan.createdAt).formatted(.relative(presentation: .named)))."
        }
    }

    @ViewBuilder private func content(_ plan: FeaturePlan, product: Product, reviewing: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.sm) {
                TagBadge(phaseLabel(plan), tone: plan.phase == .done ? .ok : .accent)
                if product.isDemo { DemoBadge() }
                if plan.linkedIssueIDs.count > 1 {
                    let titles = plan.linkedIssueIDs.compactMap { id in product.issues?.first { $0.id == id }?.title }
                    Text("From \(plan.linkedIssueIDs.count) issues: " + titles.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
                        .kitType(.meta, Ink.text3).lineLimit(2).help(titles.joined(separator: "\n"))
                } else if let issueID = plan.issueID, let issue = product.issues?.first(where: { $0.id == issueID }) {
                    Text("From the issue \u{201C}\(issue.title)\u{201D}").kitType(.meta, Ink.text3).lineLimit(1)
                }
            }
            if let summary = plan.summary { Text(summary).kitType(.body, Ink.text).fixedSize(horizontal: false, vertical: true) }
            group(reviewing ? "Steps · \(plan.steps.count - skipped.count) of \(plan.steps.count) ticked" : "Steps") {
                VStack(spacing: 0) {
                    ForEach(plan.steps) { step in stepRow(step, reviewing: reviewing, disabled: product.isDemo) }
                }
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous).strokeBorder(Ink.line, lineWidth: Metric.hairline))
            }
            if let questions = plan.questions, !questions.isEmpty { list("Open questions", questions) }
            if let risks = plan.risks, !risks.isEmpty { list("Risks", risks) }
            if reviewing {
                group("Note for the agent") {
                    KitField(placeholder: "Optional. Sent with Execute or Revise.", text: $note).disabled(product.isDemo)
                }
            }
        }
    }

    private func phaseLabel(_ plan: FeaturePlan) -> String {
        switch plan.phase {
        case .planning: "Planning"
        case .ready: "Ready to review"
        case .executing: "Executing"
        case .done: "Done"
        }
    }

    private func stepRow(_ step: FeaturePlan.Step, reviewing: Bool, disabled: Bool) -> some View {
        let isSkipped = reviewing ? skipped.contains(step.id) : step.isSkipped
        return HStack(alignment: .top, spacing: Space.md) {
            if reviewing {
                Toggle(isOn: Binding(get: { !skipped.contains(step.id) },
                                     set: { on in if on { skipped.remove(step.id) } else { skipped.insert(step.id) } })) { EmptyView() }
                    .toggleStyle(.checkbox).labelsHidden().disabled(disabled)
                    .accessibilityLabel("Do step \(step.id): \(step.title)")
                    .help(isSkipped ? "Left out. It becomes an open issue when you execute." : "Included")
            } else {
                Group {
                    if step.isDone { Icon(.check, size: 11, weight: .bold).foregroundStyle(Ink.ok) }
                    else if step.isSkipped { Icon(.xmark, size: 10).foregroundStyle(Ink.text3) }
                    else { Circle().strokeBorder(Ink.text3, lineWidth: 1).frame(width: 10, height: 10) } // grid: ok pending dot
                }
                .frame(width: 14, height: 14).padding(.top, 2)
                .accessibilityLabel(step.isDone ? "Done" : step.isSkipped ? "Left out" : "Not done yet")
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(step.id).kitType(.monoSmall, Ink.text3)
                    Text(step.title).kitType(.labelMedium, isSkipped ? Ink.text3 : Ink.text).strikethrough(isSkipped, color: Ink.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    if step.optional == true { TagBadge("Optional") }
                }
                if let summary = step.summary { Text(summary).kitType(.meta, Ink.text2).fixedSize(horizontal: false, vertical: true) }
                else if let detail = step.detail { Text(detail).kitType(.meta, Ink.text2).fixedSize(horizontal: false, vertical: true) }
                if let files = step.files, !files.isEmpty {
                    Text(files.joined(separator: "  ")).kitType(.monoSmall, Ink.text3).lineLimit(2)
                }
                if reviewing, noting.contains(step.id) {
                    KitField(placeholder: "Note for this step", text: Binding(get: { notes[step.id] ?? "" }, set: { notes[step.id] = $0 }))
                        .disabled(disabled)
                } else if !reviewing, let note = step.note {
                    Text("Your note: \(note)").kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if reviewing, !noting.contains(step.id) {
                Button("Note") { noting.insert(step.id) }
                    .buttonStyle(.kit(.link)).disabled(disabled)
                    .help("Add a note the agent gets with this step")
            }
        }
        .padding(Space.md)
        .hairlineAbove()
    }

    private func list(_ title: String, _ items: [String]) -> some View {
        group(title) {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• " + item).kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).kitType(.section).accessibilityAddTraits(.isHeader)
            content()
        }
    }
}
