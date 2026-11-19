import Foundation

// Plans in the Issues tab. Plan with the agent starts it with the feature and a plan ID; the agent reads the code,
// may ask questions, and writes `.forgedeck/plan.json` without changing anything else. The app checks the file as
// untrusted input and copies it into the product's record, where the person ticks the steps to do, adds notes, and
// executes, revises, or discards it. Progress comes back through `.forgedeck/issues-done.json`.

public struct FeaturePlan: Codable, Identifiable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable { case planning, ready, executing, done }

    public struct Step: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var detail: String?
        public var files: [String]?
        public var optional: Bool?
        /// The person's choices before executing.
        public var skipped: Bool?
        public var note: String?
        /// Reported by the agent while executing.
        public var doneAt: Date?
        public var summary: String?

        public init(id: String, title: String, detail: String? = nil, files: [String]? = nil, optional: Bool? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
            self.files = files
            self.optional = optional
        }

        public var isSkipped: Bool { skipped == true }
        public var isDone: Bool { doneAt != nil }
    }

    public var id = UUID()
    /// What the person asked for: a typed feature or an issue's title and notes.
    public var request: String
    public var issueID: UUID?
    public var phase: Phase = .planning
    public var createdAt = Date.now
    /// When the agent was last asked for a plan (first time or a revision). Only a file written after it counts.
    public var requestedAt = Date.now
    public var startedWith: String?
    public var title: String?
    public var summary: String?
    public var steps: [Step] = []
    public var questions: [String]?
    public var risks: [String]?
    public var revisions: Int?
    public var executedAt: Date?
    public var doneAt: Date?

    public init(id: UUID = UUID(), request: String, issueID: UUID? = nil, createdAt: Date = .now) {
        self.id = id
        self.request = request
        self.issueID = issueID
        self.createdAt = createdAt
        self.requestedAt = createdAt
    }

    /// The agent's title once it wrote one, otherwise the first line of the request.
    public var name: String {
        if let title, !title.isEmpty { return title }
        let first = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? request
        return first.count > 80 ? String(first.prefix(79)) + "…" : first
    }

    public var chosenSteps: [Step] { steps.filter { !$0.isSkipped } }
    public var progress: (done: Int, total: Int) { (chosenSteps.filter(\.isDone).count, chosenSteps.count) }
}

/// What `.forgedeck/plan.json` held, checked.
public struct PlanFile: Hashable, Sendable {
    public var planID: UUID?
    public var title: String?
    public var summary: String?
    public var steps: [FeaturePlan.Step]
    public var questions: [String]
    public var risks: [String]
    public var written: Date
    public var problems: [String]
    public var isUsable: Bool { problems.isEmpty && planID != nil && !steps.isEmpty }
}

public enum FeaturePlans {
    public static let relativePath = ".forgedeck/plan.json"
    static let maxBytes = 64 * 1024
    public static let maxSteps = 30
    static let maxTitle = 200
    static let maxDetail = 1_500
    static let maxSummary = 2_000
    static let maxFiles = 20
    static let maxNotes = 10

    // MARK: Reading

    public static func read(_ product: Product) -> [PlanFile] {
        product.checkouts.compactMap { read(folder: $0.path) }
    }

    public static func read(folder: String) -> PlanFile? {
        let url = URL(fileURLWithPath: folder).appending(path: relativePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let written = attributes[.modificationDate] as? Date ?? .distantPast
        let empty = { (problem: String) in
            PlanFile(planID: nil, steps: [], questions: [], risks: [], written: written, problems: [problem])
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else { return empty("\(relativePath) is not a regular file.") }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxBytes else { return empty("\(relativePath) is larger than 64 KB.") }
        guard let data = try? Data(contentsOf: url) else { return empty("\(relativePath) could not be read.") }
        return parse(data, written: written)
    }

    public static func parse(_ data: Data, written: Date) -> PlanFile {
        struct File: Decodable {
            struct Step: Decodable { var id: String?; var title: String?; var detail: String?; var files: [String]?; var optional: Bool? }
            var plan: String?
            var title: String?
            var summary: String?
            var steps: [Step]?
            var questions: [String]?
            var risks: [String]?
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            return PlanFile(planID: nil, steps: [], questions: [], risks: [], written: written,
                            problems: ["\(relativePath) is not valid JSON in the plan format."])
        }
        var problems: [String] = []
        let planID = file.plan.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
        if planID == nil { problems.append("It has no plan ID, or the ID is not the one \(Brand.name) sent.") }
        let raw = file.steps ?? []
        if raw.isEmpty { problems.append("It has no steps.") }
        if raw.count > maxSteps { problems.append("It has \(raw.count) steps; the most is \(maxSteps).") }
        var seen = Set<String>()
        var steps: [FeaturePlan.Step] = []
        for (index, step) in raw.prefix(maxSteps).enumerated() {
            let label = "Step \(index + 1)"
            let id = (step.id ?? "").trimmingCharacters(in: .whitespaces)
            let title = (step.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty || id.count > 20 || !id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) {
                problems.append("\(label) needs a short id made of letters, numbers, dots, dashes, or underscores.")
            } else if !seen.insert(id).inserted {
                problems.append("\(label) repeats the id \(id).")
            }
            if title.isEmpty { problems.append("\(label) has no title.") }
            if title.count > maxTitle { problems.append("\(label)'s title is longer than \(maxTitle) characters.") }
            if (step.detail ?? "").count > maxDetail { problems.append("\(label)'s detail is longer than \(maxDetail) characters.") }
            let files = (step.files ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if files.count > maxFiles { problems.append("\(label) lists more than \(maxFiles) files.") }
            if files.contains(where: { !isRelativePath($0) }) { problems.append("\(label) lists a file outside the project folder.") }
            if [title, step.detail ?? ""].contains(where: Redactor.looksLikeSecret) || files.contains(where: Redactor.looksLikeSecret) {
                problems.append("\(label) holds text that looks like a secret.")
            }
            let detail = step.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            steps.append(FeaturePlan.Step(id: id, title: String(title.prefix(maxTitle)), detail: detail?.isEmpty == false ? detail : nil,
                                          files: files.isEmpty ? nil : Array(files.prefix(maxFiles)), optional: step.optional == true ? true : nil))
        }
        let clean = { (list: [String]?, name: String) -> [String] in
            let items = (list ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if items.count > maxNotes { problems.append("It lists more than \(maxNotes) \(name).") }
            if items.contains(where: Redactor.looksLikeSecret) { problems.append("Its \(name) hold text that looks like a secret.") }
            return items.prefix(maxNotes).map { String($0.prefix(500)) }
        }
        let questions = clean(file.questions, "questions")
        let risks = clean(file.risks, "risks")
        let summary = file.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let summary, Redactor.looksLikeSecret(summary) || Redactor.looksLikeSecret(file.title ?? "") {
            problems.append("The title or summary holds text that looks like a secret.")
        }
        if (summary ?? "").count > maxSummary { problems.append("The summary is longer than \(maxSummary) characters.") }
        let title = file.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlanFile(planID: planID, title: title?.isEmpty == false ? String(title!.prefix(maxTitle)) : nil,
                        summary: summary?.isEmpty == false ? String(summary!.prefix(maxSummary)) : nil,
                        steps: steps, questions: questions, risks: risks, written: written, problems: problems)
    }

    static func isRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.hasPrefix("~") && !path.split(separator: "/").contains("..") && !path.contains("://")
    }

    // MARK: Applying

    /// A plan waiting for the agent takes the first usable file with its ID written after it was asked for.
    /// Returns the plans and the ones that became ready.
    public static func applyFiles(_ files: [PlanFile], to plans: [FeaturePlan]) -> (plans: [FeaturePlan], ready: [FeaturePlan]) {
        var plans = plans
        var ready: [FeaturePlan] = []
        for file in files where file.isUsable {
            guard let index = plans.firstIndex(where: { $0.id == file.planID && $0.phase == .planning }),
                  file.written >= plans[index].requestedAt else { continue }
            plans[index].title = file.title
            plans[index].summary = file.summary
            plans[index].steps = file.steps
            plans[index].questions = file.questions.isEmpty ? nil : file.questions
            plans[index].risks = file.risks.isEmpty ? nil : file.risks
            plans[index].phase = .ready
            ready.append(plans[index])
        }
        return (plans, ready)
    }

    /// The problems with a file meant for a plan that is still waiting, so the row can say why nothing showed up.
    public static func problems(_ files: [PlanFile], for plan: FeaturePlan) -> [String] {
        guard plan.phase == .planning else { return [] }
        return files.first { $0.written >= plan.requestedAt && ($0.planID == plan.id || $0.planID == nil) && !$0.isUsable }?.problems ?? []
    }

    /// Marks steps the agent reported done. A plan whose chosen steps are all done moves to done.
    public static func applyProgress(_ reports: [IssueReports.Report], to plans: [FeaturePlan], now: Date = .now)
        -> (plans: [FeaturePlan], stepsDone: Int, finished: [FeaturePlan]) {
        var plans = plans
        var count = 0
        var finished: [FeaturePlan] = []
        let redactor = Redactor()
        for report in reports {
            for entry in report.steps {
                guard let planID = UUID(uuidString: entry.plan.trimmingCharacters(in: .whitespaces)),
                      let p = plans.firstIndex(where: { $0.id == planID && $0.phase == .executing }),
                      let executed = plans[p].executedAt, report.written >= executed,
                      let s = plans[p].steps.firstIndex(where: { $0.id == entry.step.trimmingCharacters(in: .whitespaces) }),
                      !plans[p].steps[s].isSkipped, !plans[p].steps[s].isDone else { continue }
                let summary = redactor.redact(entry.summary ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                plans[p].steps[s].doneAt = now
                plans[p].steps[s].summary = summary.isEmpty ? nil : String(summary.prefix(IssueReports.maxSummary))
                count += 1
                if plans[p].progress.done == plans[p].progress.total {
                    plans[p].phase = .done
                    plans[p].doneAt = now
                    finished.append(plans[p])
                }
            }
        }
        return (plans, count, finished)
    }

    /// The issues made from the steps the person left out, so they aren't lost.
    public static func issuesForSkippedSteps(_ plan: FeaturePlan, now: Date = .now) -> [ProductIssue] {
        plan.steps.filter(\.isSkipped).map { step in
            let notes = [step.detail, "Left out of the plan \u{201C}\(plan.name)\u{201D}."].compactMap { $0 }.joined(separator: "\n\n")
            return ProductIssue(title: String(step.title.prefix(ProductIssues.maxTitle)), notes: String(notes.prefix(ProductIssues.maxNotes)), createdAt: now)
        }
    }

    // MARK: Messages to the agent

    /// The agent's first message: plan only, change nothing.
    public static func planPrompt(_ plan: FeaturePlan, issue: ProductIssue?, product: Product) -> String {
        let redactor = Redactor()
        var lines = ["\(Brand.name) asks for a plan for \(product.name), before anything is built:",
                     "\"" + redactor.redact(plan.request).trimmingCharacters(in: .whitespacesAndNewlines) + "\""]
        if let issue {
            let notes = redactor.redact(issue.notes).trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty, !plan.request.contains(notes) { lines += ["Notes: " + notes] }
            if let number = issue.githubNumber, let repo = ProductIssues.repository(product) {
                lines += ["It is GitHub issue #\(number). Read it with `gh issue view \(number) --repo \(repo.owner)/\(repo.name) --comments` if it helps."]
            }
        }
        lines += ["Plan ID: \(plan.id.uuidString)",
                  "",
                  "1. Read the code this touches, and recent commits if they help.",
                  "2. If something important is unclear, ask up to four short numbered questions in one message and wait for the answers. "
                      + "Skip what the code already answers.",
                  "3. Write `\(relativePath)` in this folder:",
                  "   {\"plan\": \"\(plan.id.uuidString)\", \"title\": \"Short name for the feature\", \"summary\": \"Two or three sentences: the approach.\",",
                  "    \"steps\": [{\"id\": \"1\", \"title\": \"What this step does\", \"detail\": \"What changes and how you'll check it\", "
                      + "\"files\": [\"src/example.ts\"], \"optional\": false}],",
                  "    \"questions\": [\"Anything still open\"], \"risks\": [\"What could break\"]}",
                  "   Steps go in the order you would do them, each small enough to finish and test on its own, usually 3 to 12. "
                      + "Ids are \"1\", \"2\", and so on. Files are paths relative to this folder. Mark a step optional when the feature works without it.",
                  "   The person reviews it in \(Brand.name), unticks steps they don't want, and adds notes.",
                  "4. Then say the plan is ready in \(Brand.name) and stop. Until \(Brand.name) sends the go-ahead, change no code and no file other than `\(relativePath)`.",
                  "Do not push, deploy, or open, close, or comment on GitHub issues."]
        return lines.joined(separator: "\n")
    }

    /// What to report as each step finishes, for both execute messages.
    static func progressInstruction(_ plan: FeaturePlan) -> String {
        "After each step, run the tests, then add {\"plan\": \"\(plan.id.uuidString)\", \"step\": \"<step id>\", \"summary\": \"One sentence: what changed.\"} "
            + "to the \"steps\" list in `\(IssueReports.relativePath)` in this folder, keeping what is already there; "
            + "\(Brand.name) ticks the step off. Report only steps that are really finished."
    }

    /// One line, typed into the agent's running terminal: a newline would send it early.
    public static func executeMessage(_ plan: FeaturePlan, note: String?) -> String {
        let flat = { (text: String) in text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        let chosen = plan.chosenSteps.map { "\($0.id) (\(flat($0.title)))" }.joined(separator: ", ")
        let skipped = plan.steps.filter(\.isSkipped).map(\.id)
        var text = "\(Brand.name): the plan \(plan.id.uuidString) is approved. Do these steps in order: \(chosen)."
        if !skipped.isEmpty { text += " Skip step\(skipped.count == 1 ? "" : "s") \(skipped.joined(separator: ", ")); don't do them." }
        let notes = plan.chosenSteps.compactMap { step in step.note.flatMap { $0.isEmpty ? nil : "step \(step.id): \(flat($0))" } }
        if !notes.isEmpty { text += " My notes: " + notes.joined(separator: "; ") + "." }
        if let note, !note.isEmpty { text += " Overall: \(flat(note))" + (note.hasSuffix(".") ? "" : ".") }
        return text + " " + progressInstruction(plan) + " Do not push, deploy, or touch GitHub issues."
    }

    /// The first message of a new session when the planning terminal is gone: the whole plan, then the go-ahead.
    public static func executePrompt(_ plan: FeaturePlan, note: String?, product: Product) -> String {
        var lines = ["\(Brand.name) sends an approved plan for \(product.name): \u{201C}\(plan.name)\u{201D}."]
        if let summary = plan.summary { lines += [summary] }
        lines += ["", "Steps to do, in order:"]
        for step in plan.chosenSteps {
            lines.append("\(step.id). \(step.title)" + (step.detail.map { " — \($0)" } ?? ""))
            if let files = step.files, !files.isEmpty { lines.append("   Files: " + files.joined(separator: ", ")) }
            if let note = step.note, !note.isEmpty { lines.append("   The person's note: " + note) }
        }
        let skipped = plan.steps.filter(\.isSkipped)
        if !skipped.isEmpty { lines += ["", "Left out, don't do: " + skipped.map { "\($0.id). \($0.title)" }.joined(separator: "; ")] }
        if let note, !note.isEmpty { lines += ["", "The person's note: " + note] }
        lines += ["", "Read the code first. " + progressInstruction(plan), "Do not push, deploy, or open, close, or comment on GitHub issues."]
        return lines.joined(separator: "\n")
    }

    /// One line, typed into the running terminal: what to change in the plan.
    public static func reviseMessage(_ plan: FeaturePlan, note: String) -> String {
        let flat = note.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let steps = plan.steps.compactMap { step in step.note.flatMap { $0.isEmpty ? nil : "step \(step.id): \($0)" } }
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
        var text = "\(Brand.name): please revise the plan \(plan.id.uuidString)."
        if !flat.isEmpty { text += " \(flat)" + (flat.hasSuffix(".") ? "" : ".") }
        if !steps.isEmpty { text += " Notes on steps: " + steps.joined(separator: "; ") + "." }
        let skipped = plan.steps.filter(\.isSkipped).map(\.id)
        if !skipped.isEmpty { text += " I unticked step\(skipped.count == 1 ? "" : "s") \(skipped.joined(separator: ", "))." }
        return text + " Write the new version to `\(relativePath)` with the same plan ID, and change no code until \(Brand.name) sends the go-ahead."
    }
}
