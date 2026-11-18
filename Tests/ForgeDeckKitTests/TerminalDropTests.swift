import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct TerminalDropTests {
    /// A dropped file types its path the way Terminal.app does, so a shell and Claude Code read it as one path.
    @Test func droppedPathsAreEscapedLikeTerminal() {
        #expect(TerminalDrop.text(forPaths: ["/Users/me/shot.png"]) == "/Users/me/shot.png ")
        #expect(TerminalDrop.text(forPaths: ["/Users/me/Screen Shot (2).png", "/tmp/a&b"]) == "/Users/me/Screen\\ Shot\\ \\(2\\).png /tmp/a\\&b ")
        #expect(TerminalDrop.escape("it's $HOME") == "it\\'s\\ \\$HOME")
        #expect(TerminalDrop.text(forPaths: []) == "" && TerminalDrop.text(forPaths: [""]) == "")
    }

    @Test func droppedImageDataIsSavedAsAFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "drops-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try TerminalDrop.saveImage(Data([0x89, 0x50, 0x4E, 0x47]), folder: folder)
        #expect(path.hasPrefix(folder.path) && path.hasSuffix(".png") && !path.contains(" "))
        #expect(FileManager.default.contents(atPath: path) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(TerminalDrop.imageFolder(temporary: URL(fileURLWithPath: "/tmp")).path == "/tmp/ForgeDeck Drops")
    }
}
