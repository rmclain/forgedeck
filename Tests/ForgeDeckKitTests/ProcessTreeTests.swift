import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ProcessTreeTests {
    /// A shell with a child in its own process group and a child that ignores hang-up and terminate,
    /// like a dev server or an agent's helper. Quitting must end all of them.
    @Test func quittingEndsTheWholeTreeEvenWhatIgnoresSignals() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "set -m; sleep 60 & (trap '' HUP TERM; sleep 61) & wait"]
        try process.run()
        let shell = process.processIdentifier
        var tree: [pid_t] = []
        for _ in 0..<40 where tree.count < 3 {
            try await Task.sleep(for: .milliseconds(50))
            tree = ProcessInspector.descendants(of: shell)
        }
        #expect(tree.count >= 2)
        #expect(tree.contains { getpgid($0) != getpgid(shell) })
        let killed = ProcessInspector.end([shell] + tree, grace: 0.5)
        #expect(killed >= 1)
        process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(100))
        #expect(tree.allSatisfy { !ProcessInspector.isRunning($0) })
    }

    @Test func neverSignalsItselfOrLaunchd() {
        #expect(ProcessInspector.end([getpid(), 1, 0], grace: 0) == 0)
        #expect(ProcessInspector.isRunning(getpid()))
        #expect(ProcessInspector.children(of: 0).isEmpty)
    }
}
