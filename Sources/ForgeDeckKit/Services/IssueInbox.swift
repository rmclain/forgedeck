import Foundation

// Items added from the command line. The app is the only writer of portfolio.json, so `forgedeck issue add`
// writes each new item as its own file in <data folder>/inbox/issues, and the app moves it into the product's
// Issues list within seconds (or when it next starts). One file per item: the CLI never appends to a file the app
// is reading, and a half-written file is never seen, because each one is written under a temporary name and renamed.

public enum IssueInbox {
    public struct Entry: Codable, Hashable, Sendable {
        public var productID: UUID
        /// For messages, and to find the product if its id ever changed. The id wins.
        public var productSlug: String
        public var issue: ProductIssue
        /// "cli" today.
        public var source: String

        public init(productID: UUID, productSlug: String, issue: ProductIssue, source: String = "cli") {
            self.productID = productID
            self.productSlug = productSlug
            self.issue = issue
            self.source = source
        }
    }

    public struct Pending: Hashable, Sendable {
        public var url: URL
        public var entry: Entry
    }

    public static func directory(_ location: StoreLocation) -> URL {
        location.directory.appending(path: "inbox/issues", directoryHint: .isDirectory)
    }

    /// Queues an item for the product. Returns the item as the app will save it (same id).
    @discardableResult
    public static func add(_ issue: ProductIssue, to product: Product, location: StoreLocation) throws -> Entry {
        let folder = directory(location)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entry = Entry(productID: product.id, productSlug: product.slug, issue: issue)
        let data = try JSONCoding.encoder(pretty: false).encode(entry)
        let name = "\(issue.createdAt.timeIntervalSince1970)-\(issue.id.uuidString)"
        let temporary = folder.appending(path: ".\(name).tmp")
        try data.write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: folder.appending(path: "\(name).json"))
        return entry
    }

    /// Items waiting for the app, oldest first. Files that cannot be read are returned in `unreadable`.
    public static func pending(_ location: StoreLocation) -> (items: [Pending], unreadable: [URL]) {
        let folder = directory(location)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return ([], []) }
        var items: [Pending] = [], unreadable: [URL] = []
        let decoder = JSONCoding.decoder()
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = folder.appending(path: name)
            if let data = try? Data(contentsOf: url), let entry = try? decoder.decode(Entry.self, from: data) {
                items.append(Pending(url: url, entry: entry))
            } else {
                unreadable.append(url)
            }
        }
        return (items.sorted { $0.entry.issue.createdAt < $1.entry.issue.createdAt }, unreadable)
    }

    /// The folder's modification date: changes when a file is added or removed. One stat, no reads.
    public static func stamp(_ location: StoreLocation) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: directory(location).path))?[.modificationDate] as? Date
    }

    public struct Outcome: Sendable {
        /// Items added, by product id, in the order they were queued.
        public var added: [UUID: [ProductIssue]] = [:]
        /// Queued for a product that is gone or is a demo. Dropped.
        public var dropped: [Entry] = []
        public var count: Int { added.values.reduce(0) { $0 + $1.count } }
    }

    /// Puts the queued items at the top of each product's list. An item whose id is already there is skipped,
    /// so a file that was applied but not yet deleted (the app quit in between) is not added twice.
    public static func apply(_ pending: [Pending], to portfolio: inout Portfolio) -> Outcome {
        var outcome = Outcome()
        for item in pending {
            let entry = item.entry
            guard let index = portfolio.products.firstIndex(where: { $0.id == entry.productID })
                    ?? portfolio.products.firstIndex(where: { $0.slug == entry.productSlug && !entry.productSlug.isEmpty }),
                  !portfolio.products[index].isDemo else {
                outcome.dropped.append(entry)
                continue
            }
            var issues = portfolio.products[index].issues ?? []
            guard !issues.contains(where: { $0.id == entry.issue.id }) else { continue }
            var issue = entry.issue
            issue.isDone = false
            issues.insert(issue, at: 0)
            portfolio.products[index].issues = issues
            outcome.added[portfolio.products[index].id, default: []].append(issue)
        }
        return outcome
    }

    public static func remove(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
