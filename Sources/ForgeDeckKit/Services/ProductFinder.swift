import Foundation

// Finds the product a person means from a few words, a number from the short list, or part of a name, so an agent
// in a remote session doesn't have to guess between similar names or ask for a full path.

public enum ProductFinder {
    /// What a query found.
    public enum Match: Equatable, Sendable {
        case one(Product)
        /// Several fit equally well: ask which one.
        case several([Product])
        case none
    }

    /// The products an agent can work on, in the order the numbered list shows them: by group, then name.
    public static func workable(in portfolio: Portfolio) -> [Product] {
        ForgeRemote.products(in: portfolio).sorted {
            let groups = $0.group.localizedCaseInsensitiveCompare($1.group)
            return groups == .orderedSame ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : groups == .orderedAscending
        }
    }

    /// Lowercased words: letters and digits only, so "Ledger-Cloud" and "ledger cloud" are the same words.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The names a product goes by: its name, slug, folders, and repositories.
    static func names(_ product: Product) -> [String] {
        [product.name, product.slug]
            + product.checkouts.flatMap { [$0.name, URL(fileURLWithPath: $0.path).lastPathComponent] }
            + product.repositories.map(\.name)
    }

    /// How well a query fits one product: 3 exact name, 2 every word starts a word of one name, 1 every word appears somewhere.
    static func score(_ query: [String], _ product: Product) -> Int {
        let joined = query.joined()
        let names = names(product).filter { !$0.isEmpty }
        if names.contains(where: { words($0).joined() == joined }) { return 3 }
        if names.contains(where: { name in
            let parts = words(name)
            return query.allSatisfy { word in parts.contains { $0.hasPrefix(word) } }
        }) { return 2 }
        let everything = (names + [product.group, product.tagline]).flatMap(words)
        if query.allSatisfy({ word in everything.contains { $0.contains(word) } }) { return 1 }
        return 0
    }

    /// A number from the list, or words. The best score wins when only one product has it.
    public static func find(_ query: String, in products: [Product]) -> Match {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) {
            return products.indices.contains(number - 1) ? .one(products[number - 1]) : .none
        }
        let query = words(trimmed)
        guard !query.isEmpty else { return .none }
        let scored = products.map { ($0, score(query, $0)) }.filter { $0.1 > 0 }
        guard let best = scored.map(\.1).max() else { return .none }
        let top = scored.filter { $0.1 == best }.map(\.0)
        return top.count == 1 ? .one(top[0]) : .several(top)
    }

    /// `~/…` for a path under the home folder.
    public static func short(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
