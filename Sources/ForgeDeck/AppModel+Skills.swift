import AppKit
import ForgeDeckKit
import SwiftUI

/// A fetched skill repository waiting for the person to pick what to add.
struct SkillPlan: Identifiable {
    let id = UUID()
    var repository: String
    var commit: String
    /// The shallow clone. Deleted when the sheet closes.
    var folder: URL
    var skills: [FoundSkill]
    /// The tag, branch, or commit asked for, if any.
    var ref: String? = nil
    /// Skills an npx command named. nil: the recommended ones are ticked.
    var preselect: [String]? = nil
    /// Agents an npx command named. nil: Claude Code, plus the shared folder when it exists.
    var targets: Set<SkillTarget>? = nil
}

extension AppModel {
    /// The home folder for agent skills and MCP configs. The self-test points this at a temporary folder.
    var agentHomeURL: URL { agentHome ?? FileManager.default.homeDirectoryForCurrentUser }

    /// Downloads a repository with a shallow clone, finds its skills, and opens the sheet to pick them.
    /// Takes owner/repo, a GitHub link, or a pasted `npx skills add …` command. The command is read, never run.
    func lookUpSkills(_ input: String) {
        guard let source = AgentSkills.parseSource(input) else {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return show(text.contains(" ") ? "ForgeDeck reads npx skills add and npx skills use commands for GitHub repositories. This one could not be read."
                                           : SkillError.badRepository(text).description, isError: true)
        }
        let repository = source.repository
        guard fetchingSkills == nil else { return }
        fetchingSkills = repository
        let folder = FileManager.default.temporaryDirectory.appending(path: "ForgeDeck-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
        Task {
            defer { fetchingSkills = nil }
            do {
                let commit = try await AgentSkills.fetch(repository, ref: source.ref, into: folder.appending(path: "repo"))
                let root = folder.appending(path: "repo")
                let skills = AgentSkills.discover(in: root)
                guard !skills.isEmpty else {
                    try? FileManager.default.removeItem(at: folder)
                    return show("\(repository) has no skills: no folder in it holds a SKILL.md.", isError: true)
                }
                let missing = (source.skills ?? []).filter { name in !skills.contains { $0.answers(to: name) } }
                record("skill.fetch", detail: "repo=\(repository) ref=\(source.ref ?? "default") commit=\(commit.prefix(12)) found=\(skills.count) command=\(source.fromCommand)")
                sheet = .skills(SkillPlan(repository: repository, commit: commit, folder: root, skills: skills, ref: source.ref,
                                          preselect: source.skills, targets: source.targets))
                if !missing.isEmpty { show("\(repository) has no skill named \(missing.joined(separator: ", ")).", isError: true) }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                show((error as? SkillError)?.description ?? error.localizedDescription, isError: true)
            }
        }
    }

    /// Copies the chosen skills into each chosen agent folder.
    func installSkills(_ plan: SkillPlan, names: Set<String>, targets: Set<SkillTarget>) {
        var added: [String] = [], updated: [String] = [], kept: [String] = [], failed: [String] = []
        for skill in plan.skills where names.contains(skill.name) {
            for target in SkillTarget.allCases where targets.contains(target) {
                do {
                    switch try AgentSkills.install(skill, from: plan.folder, repository: plan.repository, commit: plan.commit, target: target, home: agentHomeURL) {
                    case .installed: added.append(skill.name)
                    case .updated: updated.append(skill.name)
                    case .keptExisting: kept.append(skill.name)
                    }
                } catch {
                    failed.append("\(skill.name): \((error as? SkillError)?.description ?? error.localizedDescription)")
                }
            }
        }
        discardSkillClone(plan)
        skillsVersion += 1
        if !added.isEmpty || !updated.isEmpty { skillsChanged() }
        let where_ = SkillTarget.allCases.filter(targets.contains).map(\.title).joined(separator: " and ")
        record("skill.install", detail: "repo=\(plan.repository) commit=\(plan.commit.prefix(12)) targets=\(targets.map(\.rawValue).sorted().joined(separator: ",")) added=\(Set(added).count) updated=\(Set(updated).count) kept=\(Set(kept).count) failed=\(failed.count)",
               outcome: failed.isEmpty ? "ok" : "failed")
        var parts: [String] = []
        if !added.isEmpty { parts.append("Added \(Self.count(Set(added).count, "skill")) to \(where_).") }
        if !updated.isEmpty { parts.append("Updated \(Self.count(Set(updated).count, "skill")).") }
        if !kept.isEmpty { parts.append("Kept your own \(Set(kept).sorted().joined(separator: ", ")).") }
        if !failed.isEmpty { parts.append("\(failed.count) failed: \(failed[0])") }
        show(parts.isEmpty ? "Nothing was added." : parts.joined(separator: " "), isError: !failed.isEmpty)
    }

    func discardSkillClone(_ plan: SkillPlan) {
        // The clone lives in its own temporary folder; remove that folder, never anything above it.
        let parent = plan.folder.deletingLastPathComponent()
        guard parent.lastPathComponent.hasPrefix("ForgeDeck-skills-") else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    /// Moves the skills ForgeDeck installed from a repository to the Trash, after a confirmation.
    func confirmRemoveSkills(_ repository: String) {
        let installed = AgentSkills.installed(home: agentHomeURL).filter { $0.receipt.repository == repository }
        guard !installed.isEmpty else { return }
        sheet = .confirm(ConfirmRequest(
            title: "Remove skills from \(repository)",
            message: "Moves the \(Self.count(installed.count, "skill folder")) \(Brand.name) added to the Trash. Skills you added some other way are not touched.",
            checks: installed.map { .init(label: $0.name, meta: $0.target.detail + "/\($0.name)", ok: true) },
            confirmLabel: "Move to Trash",
            icon: .trash) { [weak self] in self?.removeSkills(installed) })
    }

    private func removeSkills(_ installed: [AgentSkills.Installed]) {
        var removed = 0
        for skill in installed {
            if (try? AgentSkills.remove(skill.name, target: skill.target, home: agentHomeURL)) != nil { removed += 1 }
        }
        skillsVersion += 1
        record("skill.remove", detail: "repo=\(installed.first?.receipt.repository ?? "") removed=\(removed)")
        show(removed == installed.count ? "Moved \(Self.count(removed, "skill")) to the Trash." : "Moved \(removed) of \(installed.count) skills to the Trash.",
             isError: removed != installed.count)
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

// MARK: Sheet

struct SkillsSheet: View {
    @Environment(AppModel.self) private var model
    let plan: SkillPlan
    @State private var chosen: Set<String> = []
    @State private var targets: Set<SkillTarget> = [.claude]
    @State private var listHeight: CGFloat = 0

    var body: some View {
        SheetPanel(width: 600) {
            SheetHeader(icon: .sparkle, tone: .accent, title: "Add skills from \(plan.repository)",
                        message: "Found \(AppModel.count(plan.skills.count, "skill")) at \(plan.ref.map { "\($0), " } ?? "")commit \(String(plan.commit.prefix(7))). Skills are instructions your agents follow, and some include scripts the agent may run. Add only repositories you trust.")
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Add to").kitType(.labelMedium, Ink.text2)
                ForEach(SkillTarget.allCases) { target in
                    Toggle(isOn: Binding(get: { targets.contains(target) }, set: { if $0 { targets.insert(target) } else { targets.remove(target) } })) {
                        HStack(spacing: Space.xs) {
                            Text(target.title).kitType(.label)
                            Text(target.detail).kitType(.meta, Ink.text3).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .help(target.readers)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.sm)
            HStack {
                Text("Skills").kitType(.labelMedium, Ink.text2)
                Spacer()
                Button(chosen.count == plan.skills.count ? "Select None" : "Select All") {
                    chosen = chosen.count == plan.skills.count ? [] : Set(plan.skills.map(\.name))
                }
                .buttonStyle(.kit(.link))
            }
            .padding(.horizontal, Space.xl)
            // Short lists take their own height; long ones scroll.
            ScrollView {
                list.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(360, max(listHeight, 60))) // grid: ok fits the list up to a scroll limit
            .background(Ink.panel2.opacity(0.5), in: RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous))
            .padding(.horizontal, Space.xl)
            SheetFooter(note: "Copied from a shallow clone. Nothing in the repository runs. Folders you added yourself are kept.") {
                Button("Cancel") { model.discardSkillClone(plan); model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Add Skills" : "Add \(AppModel.count(chosen.count, "Skill"))") {
                    model.sheet = nil
                    model.installSkills(plan, names: chosen, targets: targets)
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || targets.isEmpty)
            }
        }
        .onAppear {
            if let named = plan.preselect {
                chosen = Set(plan.skills.filter { skill in named.contains(where: skill.answers) }.map(\.name))
            } else {
                chosen = Set(plan.skills.filter(\.recommended).map(\.name))
            }
            if let wanted = plan.targets {
                targets = wanted
            } else if FileManager.default.fileExists(atPath: SkillTarget.agents.directory(home: model.agentHomeURL).path) {
                targets.insert(.agents)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(plan.skills) { skill in row(skill) }
        }
    }

    private func row(_ skill: FoundSkill) -> some View {
        let notes = SkillTarget.allCases.filter(targets.contains).compactMap { target -> (String, Tone)? in
            switch AgentSkills.state(of: skill.name, target: target, home: model.agentHomeURL) {
            case .new: nil
            case .installed(let receipt): (receipt.repository == plan.repository ? "Update in \(target.title)" : "Replaces the copy from \(receipt.repository)", .accent)
            case .foreign: ("Yours in \(target.title), kept", .muted)
            }
        }
        return HStack(alignment: .top, spacing: Space.sm) {
            Toggle("", isOn: Binding(get: { chosen.contains(skill.name) }, set: { if $0 { chosen.insert(skill.name) } else { chosen.remove(skill.name) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Add \(skill.name)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(skill.name).kitType(.labelStrong)
                    ForEach(notes, id: \.0) { note in TagBadge(note.0, tone: note.1) }
                    if !skill.recommended { TagBadge("Outside skills/", tone: .muted).help("Found at \(skill.sources[0]). It may be a template or an example.") }
                }
                if !skill.summary.isEmpty { Text(skill.summary).kitType(.meta, Ink.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                Text(skill.source(for: targets.contains(.claude) ? .claude : .agents)).kitType(.monoSmall, Ink.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
        .hairlineBelow()
    }
}
