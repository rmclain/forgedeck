import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct SkillSuggestionsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "fd-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: ".forgedeck"), withIntermediateDirectories: true)
        return url
    }

    private func product(at folder: URL) -> Product {
        var product = Product(name: "Acme")
        var checkout = LocalCheckout()
        checkout.name = "acme"
        checkout.path = folder.path
        product.checkouts = [checkout]
        return product
    }

    @Test func readsSkillsAndPluginsAndChecksEach() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = """
        {"skills": [
          {"name": "design-review", "repo": "example/skills", "why": "Reviews screens"},
          {"name": "tester", "plugin": "tester", "marketplace": "example/plugins", "includes": ["skills", "hooks"]},
          {"name": "bad name", "repo": "not a repo"},
          {"name": "both", "repo": "example/skills", "marketplace": "claude-plugins-official"}
        ]}
        """
        try Data(json.utf8).write(to: folder.appending(path: SkillSuggestions.relativePath))
        let file = SkillSuggestions.read(product(at: folder))
        #expect(file.errors.isEmpty && file.entries.count == 4)
        let checked = file.entries.map(SkillSuggestions.check)
        #expect(checked[0].isValid && !checked[0].entry.isPlugin && !checked[0].runsCode)
        #expect(checked[1].isValid && checked[1].entry.isPlugin && checked[1].runsCode)
        #expect(checked[2].problems.count == 2)
        #expect(!checked[3].isValid)
        #expect(checked[0].entry.link == "https://github.com/example/skills")
    }

    @Test func aBrokenFileSaysWhatItNeeds() {
        let result = SkillSuggestions.parse(Data("{\"plugins\": []}".utf8))
        #expect(result.entries.isEmpty && result.error?.contains("\"skills\"") == true)
    }

    @Test func chosenAndTurnedDownSuggestionsAreNotOfferedAgain() {
        var product = Product(name: "Acme")
        product.agentSkills = [AgentSkill(id: "kept", repo: "example/skills"),
                               AgentSkill(id: "no", repo: "example/skills", isActive: false, isDismissed: true)]
        let entries = ["kept", "no", "new"].map { ProposedSkill(name: $0, repo: "example/skills") }
        #expect(SkillSuggestions.suggestions(for: product, entries: entries).map(\.id) == ["new"])
    }

    @Test func onlyActiveSkillsAreNamedInThePrompt() {
        var product = Product(name: "Acme")
        #expect(SkillSuggestions.promptLine(for: product) == nil)
        product.agentSkills = [AgentSkill(id: "design-review", repo: "example/skills", why: "screens"),
                               AgentSkill(id: "off", repo: "example/skills", isActive: false),
                               AgentSkill(id: "no", repo: "example/skills", isActive: true, isDismissed: true)]
        let line = SkillSuggestions.promptLine(for: product) ?? ""
        #expect(line.contains("design-review (screens)") && !line.contains("off") && !line.contains("no"))
        #expect(SkillSuggestions.activeNames(product) == ["design-review"])
    }

    @Test func pluginInstallIsUserScopeWithoutAutoConfirm() {
        let byName = SkillSuggestions.installArguments(plugin: "tester", marketplace: "claude-plugins-official")
        #expect(byName == ["plugin", "install", "tester@claude-plugins-official", "--scope", "user"])
        let byRepo = SkillSuggestions.installArguments(plugin: "tester", marketplace: "example/plugins")
        #expect(byRepo == ["plugin", "install", "tester", "--marketplace", "example/plugins", "--scope", "user"])
        #expect(!(byName + byRepo).contains("-y") && !(byName + byRepo).contains("--yes"))
    }

    @Test func readsInstalledPluginsAndSkillFolders() throws {
        let list = #"[{"id": "tester@example", "enabled": true}, {"id": "off@example", "enabled": false}, {"id": "plain@x"}]"#
        #expect(SkillSuggestions.installedPlugins(fromListJSON: Data(list.utf8)) == ["tester", "plain"])
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let skill = home.appending(path: ".claude/skills/design-review")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\nname: design-review\n---".utf8).write(to: skill.appending(path: "SKILL.md"))
        try FileManager.default.createDirectory(at: home.appending(path: ".agents/skills/empty"), withIntermediateDirectories: true)
        #expect(SkillSuggestions.installedSkills(home: home) == ["design-review"])
    }

    @Test func olderProductsLoadWithoutSkills() throws {
        let data = try JSONEncoder().encode(Product(name: "Acme"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "agentSkills")
        let product = try JSONDecoder().decode(Product.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(product.agentSkills == nil)
    }
}
