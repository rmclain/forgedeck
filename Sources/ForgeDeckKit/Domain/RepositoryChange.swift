import Foundation

// Pointing a product's repository somewhere else: a transfer (xyz/repo1 to abc/repo1), a rename, or a fork that
// became the main repository. The entry keeps its id, so linked checkouts, components, and issues stay attached.

extension Repository {
    /// The clone URL ForgeDeck keeps for a repository. A typed URL keeps its form with any credentials masked;
    /// the owner/repo shorthand becomes an SSH URL.
    public static func cloneURL(for url: RepositoryURL, typed: String) -> String {
        typed.contains("@") || typed.contains("://") ? Redactor().redact(typed) : "git@\(url.host):\(url.owner)/\(url.name).git"
    }

    public func points(to url: RepositoryURL) -> Bool {
        owner.lowercased() == url.owner.lowercased() && name.lowercased() == url.name.lowercased()
    }
}

public enum RepositoryChange {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unreadable, unchanged, alreadyLinked(String), notFound

        public var description: String {
            switch self {
            case .unreadable: "That is not a repository URL. Use owner/repo, https://github.com/owner/repo, or git@github.com:owner/repo.git."
            case .unchanged: "The repository already points there."
            case .alreadyLinked(let name): "\(name) is already linked to this product."
            case .notFound: "That repository is no longer linked to this product."
            }
        }
    }

    public struct Outcome: Equatable, Sendable {
        public var from: String
        public var to: String
        public var oldWebURL: String
    }

    /// Points one repository of the product at `typed`. Repository links that went to the old page follow it.
    public static func apply(_ typed: String, repositoryID: UUID, in product: inout Product) -> Result<Outcome, Problem> {
        guard let url = RepositoryURL.parse(typed) else { return .failure(.unreadable) }
        guard let index = product.repositories.firstIndex(where: { $0.id == repositoryID }) else { return .failure(.notFound) }
        let old = product.repositories[index]
        if old.points(to: url), old.webURL == url.webURL { return .failure(.unchanged) }
        if let other = product.repositories.first(where: { $0.id != repositoryID && $0.points(to: url) }) {
            return .failure(.alreadyLinked(other.fullName))
        }
        var repo = old
        repo.provider = url.provider
        repo.owner = url.owner
        repo.name = url.name
        repo.webURL = url.webURL
        repo.cloneURL = Repository.cloneURL(for: url, typed: typed)
        product.repositories[index] = repo
        for i in product.links.indices where product.links[i].kind == .repository && sameWebURL(product.links[i].url, old.webURL) {
            product.links[i].url = url.webURL
        }
        return .success(Outcome(from: old.fullName, to: repo.fullName, oldWebURL: old.webURL))
    }

    /// The new `origin` for a checkout whose origin pointed at the old repository, or nil when it pointed elsewhere.
    /// It keeps the checkout's form (HTTPS or SSH) so the login it uses keeps working, and never carries credentials.
    public static func originURL(current: String, old: Repository, new url: RepositoryURL) -> String? {
        guard let parsed = RepositoryURL.parse(current), old.points(to: parsed) else { return nil }
        let https = current.lowercased().hasPrefix("https://") || current.lowercased().hasPrefix("http://")
        return https ? "https://\(url.host)/\(url.owner)/\(url.name).git" : "git@\(url.host):\(url.owner)/\(url.name).git"
    }

    private static func sameWebURL(_ a: String, _ b: String) -> Bool {
        func clean(_ s: String) -> String {
            var s = s.lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            if s.hasSuffix(".git") { s.removeLast(4) }
            return s
        }
        return clean(a) == clean(b)
    }
}
