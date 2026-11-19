import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ProcessRunnerTests {
    /// A launch that fails (here, a working folder that no longer exists) throws instead of crashing the app.
    @Test func aFailedLaunchThrowsAndDoesNotCrash() async {
        let gone = FileManager.default.temporaryDirectory.appending(path: "forgedeck-gone-\(UUID().uuidString)")
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], workingDirectory: gone, timeout: 5)
        await #expect(throws: (any Error).self) { _ = try await SystemProcessRunner().run(request) }
        for _ in 0..<20 {
            _ = try? await SystemProcessRunner().run(request)
        }
    }

    @Test func aProcessThatFinishesReturnsItsOutput() async throws {
        let result = try await SystemProcessRunner().run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"], timeout: 5))
        #expect(result.ok && result.stdout == "hi\n")
    }
}
