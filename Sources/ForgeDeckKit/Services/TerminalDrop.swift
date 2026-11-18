import Foundation

// What a drop on a built-in terminal types: file paths escaped the way Terminal.app escapes them, so a shell reads
// each as one word and Claude Code recognizes an image path and attaches the image. Image data with no file behind
// it (dragged from a browser or a screenshot preview) is saved to a temporary file first.

public enum TerminalDrop {
    /// Paths escaped with backslashes and joined by spaces, with a trailing space so typing can continue.
    public static func text(forPaths paths: [String]) -> String {
        let words = paths.filter { !$0.isEmpty }.map(escape)
        return words.isEmpty ? "" : words.joined(separator: " ") + " "
    }

    /// Backslash before every character a shell treats specially, like Terminal.app.
    public static func escape(_ path: String) -> String {
        var out = ""
        for character in path {
            if special.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static let special = Set(" \t!\"#$&'()*,;<>?[\\]^`{|}~")

    /// Where dropped image data is saved: a folder of its own in the temporary directory.
    public static func imageFolder(temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        temporary.appending(path: "ForgeDeck Drops", directoryHint: .isDirectory)
    }

    /// Saves PNG data as a new file and returns its path.
    public static func saveImage(_ png: Data, folder: URL = imageFolder(), now: Date = .now) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let url = folder.appending(path: "dropped-\(stamp)-\(UUID().uuidString.prefix(6)).png")
        try png.write(to: url, options: .atomic)
        return url.path
    }
}
