import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct AgentFilesTests {
    /// The watch notices a file the agent writes, rewrites, or removes, by name, without reading it.
    @Test func aWrittenFileIsNoticedByName() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agentfiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: ".forgedeck"), withIntermediateDirectories: true)
        var product = Product(name: "Acme")
        var checkout = LocalCheckout()
        checkout.name = "acme"
        checkout.path = folder.path
        product.checkouts = [checkout]

        let empty = AgentFiles.stamps(product)
        #expect(empty.isEmpty)

        let skills = folder.appending(path: SkillSuggestions.relativePath)
        try Data(#"{"skills": []}"#.utf8).write(to: skills)
        let written = AgentFiles.stamps(product)
        #expect(AgentFiles.changed(from: empty, to: written) == [SkillSuggestions.relativePath])
        #expect(AgentFiles.changed(from: written, to: AgentFiles.stamps(product)).isEmpty)

        try Data(#"{"skills": [{"name": "a", "repo": "o/r"}]}"#.utf8).write(to: skills)
        try Data(#"{"commands": []}"#.utf8).write(to: folder.appending(path: RunSetup.relativePath))
        let rewritten = AgentFiles.stamps(product)
        #expect(AgentFiles.changed(from: written, to: rewritten) == [SkillSuggestions.relativePath, RunSetup.relativePath])

        try FileManager.default.removeItem(at: skills)
        #expect(AgentFiles.changed(from: rewritten, to: AgentFiles.stamps(product)) == [SkillSuggestions.relativePath])
    }
}
