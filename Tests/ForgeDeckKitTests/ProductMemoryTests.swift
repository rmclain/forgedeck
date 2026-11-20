import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ProductMemoryTests {
    private func product(_ notes: [MemoryNote] = []) -> Product {
        var product = Product(name: "Acme")
        product.memory = notes
        return product
    }

    @Test func typedTextBecomesOneCleanLine() throws {
        #expect(ProductMemory.make("  \n ", kind: .rule) == nil)
        let note = try #require(ProductMemory.make("  Run make test\n  first  ", kind: .rule))
        #expect(note.text == "Run make test first" && note.kind == .rule && note.addedBy == nil)
        #expect(try #require(ProductMemory.make(String(repeating: "a", count: 900), kind: .note)).text.count == ProductMemory.maxText)
        let secret = try #require(ProductMemory.make("The key is ghp_abcdefghijklmnopqrstuvwxyz0123456789", kind: .note))
        #expect(!secret.text.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    @Test func rulesComeFirstOldestFirst() {
        let now = Date.now
        let notes = [MemoryNote(text: "n1", kind: .note, createdAt: now), MemoryNote(text: "r2", kind: .rule, createdAt: now),
                     MemoryNote(text: "r1", kind: .rule, createdAt: now.addingTimeInterval(-10))]
        #expect(ProductMemory.sorted(notes).map(\.text) == ["r1", "r2", "n1"])
    }

    @Test func thePromptHoldsTheMemoryAndHowToAdd() {
        let empty = ProductMemory.prompt(product())
        #expect(empty.contains("It is empty so far.") && empty.contains(ProductMemory.relativePath))
        let full = ProductMemory.prompt(product([MemoryNote(text: "Use make test.", kind: .rule), MemoryNote(text: "Charts come from reports.")]))
        #expect(full.contains("- Rule: Use make test.") && full.contains("- Note: Charts come from reports.") && full.contains("Follow the rules"))
    }

    @Test func aLongMemoryKeepsEveryRuleAndTheNewestNotes() {
        let now = Date.now
        let long = String(repeating: "x", count: 400)
        var notes = [MemoryNote(text: "the rule", kind: .rule, createdAt: now)]
        notes += (0..<20).map { MemoryNote(text: "\($0) " + long, kind: .note, createdAt: now.addingTimeInterval(Double($0))) }
        let prompt = ProductMemory.prompt(product(notes))
        #expect(prompt.contains("- Rule: the rule") && prompt.contains("- Note: 19 ") && !prompt.contains("- Note: 0 "))
        #expect(prompt.contains("more in the Memory section of the context file"))
        #expect(ProductMemory.contextSection(product(notes)).contains("- Note: 0 "))
    }

    @Test func theAgentsEntriesAreAddedOnceAndCapped() {
        let existing = [MemoryNote(text: "Use make test.", kind: .rule)]
        let entries = [ProductMemory.Entry(text: "use make  TEST", kind: "rule"), ProductMemory.Entry(text: "  "),
                       ProductMemory.Entry(text: "Webhooks retry.", kind: "weird"), ProductMemory.Entry(text: "Webhooks retry", kind: "note"),
                       ProductMemory.Entry(text: "Never push to main.", kind: "RULE")]
        let result = ProductMemory.merge(entries, into: existing, by: "claude")
        #expect(result.added.map(\.text) == ["Webhooks retry.", "Never push to main."])
        #expect(result.added.map(\.kind) == [.note, .rule] && result.added.allSatisfy { $0.addedBy == "claude" } && result.leftOut == 0)
        let full = (0..<ProductMemory.maxItems).map { MemoryNote(text: "n\($0)") }
        let capped = ProductMemory.merge([ProductMemory.Entry(text: "one more")], into: full, by: "claude")
        #expect(capped.added.isEmpty && capped.leftOut == 1 && capped.notes.count == ProductMemory.maxItems)
    }

    @Test func theFileIsReadThenEmptiedUnlessItChanged() throws {
        let folder = try makeTempDir("memory")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: ProductMemory.relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"add\": [{\"kind\": \"rule\", \"text\": \"Use make test.\"}]}".utf8).write(to: file)
        let inbox = try #require(ProductMemory.read(folder: folder.path))
        #expect(inbox.entries == [ProductMemory.Entry(text: "Use make test.", kind: "rule")])
        try Data("{\"add\": [{\"text\": \"written after the read\"}]}".utf8).write(to: file)
        ProductMemory.empty(inbox)
        #expect(ProductMemory.read(folder: folder.path)?.entries.first?.text == "written after the read")
        ProductMemory.empty(try #require(ProductMemory.read(folder: folder.path)))
        #expect(ProductMemory.read(folder: folder.path)?.entries == [])
        try Data("not json".utf8).write(to: file)
        #expect(ProductMemory.read(folder: folder.path) == nil)
    }

    @Test func anUnknownKindLoadsAsANote() throws {
        let data = Data("{\"id\": \"\(UUID().uuidString)\", \"text\": \"x\", \"kind\": \"future\", \"createdAt\": 0}".utf8)
        #expect(try JSONDecoder().decode(MemoryNote.self, from: data).kind == .note)
    }

    @Test func everySessionGetsTheMemoryInItsPromptAndContextFile() throws {
        let root = try makeTempDir("memory-context")
        defer { try? FileManager.default.removeItem(at: root) }
        let acme = product([MemoryNote(text: "Use make test.", kind: .rule)])
        let bundle = try AgentContextBundle.write(for: acme, portfolio: Portfolio(), cache: ObservationCache(), location: ContextLocation(root: root))
        #expect(bundle.pointer.contains("- Rule: Use make test.") && bundle.memoryCount == 1)
        let context = try String(contentsOf: bundle.contextFile, encoding: .utf8)
        #expect(context.contains("## Memory") && context.contains("- Rule: Use make test."))
        #expect(bundle.banner(product: "Acme", program: "claude").contains("Memory"))
        var demo = acme
        demo.isDemo = true
        let demoBundle = try AgentContextBundle.write(for: demo, portfolio: Portfolio(), cache: ObservationCache(), location: ContextLocation(root: root))
        #expect(demoBundle.memory == nil)
    }

    @Test func remoteSessionsMayReadTheMemoryWithoutAsking() {
        #expect(ForgeDeckSkill.allowRules(cli: "forgedeck").contains("Bash(forgedeck memory *)"))
        #expect(ForgeDeckSkill.text(cli: "forgedeck").contains(ProductMemory.relativePath))
    }
}
