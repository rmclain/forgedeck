import Foundation

// The files a setup agent writes in a checkout's .forgedeck folder. While an agent runs, the app compares their size
// and modification time every second and re-reads only these files when one changes, instead of waiting for the
// session to end or for the next full refresh.

public enum AgentFiles {
    public static let relativePaths = [EnvironmentProposals.relativePath, RunSetup.relativePath, SkillSuggestions.relativePath, BlueprintCheck.relativePath,
                                              IssueReports.relativePath, FeaturePlans.relativePath]

    public struct Stamp: Hashable, Sendable {
        public var size: Int
        public var modified: Date
    }

    /// Size and modification time of each file that exists, keyed by its full path. One stat per file, no reads.
    public static func stamps(_ product: Product) -> [String: Stamp] {
        var stamps: [String: Stamp] = [:]
        for checkout in product.checkouts {
            for relative in relativePaths {
                let path = URL(fileURLWithPath: checkout.path).appending(path: relative).path
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
                stamps[path] = Stamp(size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                                     modified: attributes[.modificationDate] as? Date ?? .distantPast)
            }
        }
        return stamps
    }

    /// The relative paths (`.forgedeck/skills.json`, …) that were added, changed, or removed between two stamps.
    public static func changed(from old: [String: Stamp], to new: [String: Stamp]) -> Set<String> {
        let paths = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        return Set(paths.compactMap { path in relativePaths.first { path.hasSuffix("/" + $0) } })
    }
}
