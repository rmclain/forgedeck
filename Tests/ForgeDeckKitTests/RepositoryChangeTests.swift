import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct RepositoryChangeTests {
    func product() -> (Product, UUID) {
        var repo = Repository()
        repo.owner = "xyz"
        repo.name = "repo1"
        repo.webURL = "https://github.com/xyz/repo1"
        repo.cloneURL = "git@github.com:xyz/repo1.git"
        var product = Product(name: "Repo", group: "Products")
        product.repositories = [repo]
        product.links = [ProductLink(label: "Repository", url: "https://github.com/xyz/repo1", kind: .repository),
                         ProductLink(label: "Site", url: "https://github.com/xyz/repo1", kind: .site)]
        return (product, repo.id)
    }

    @Test func pointsTheSameEntryAtTheNewOwner() throws {
        var (product, id) = product()
        let outcome = try RepositoryChange.apply("abc/repo1", repositoryID: id, in: &product).get()
        #expect(outcome.from == "xyz/repo1" && outcome.to == "abc/repo1")
        let repo = try #require(product.repositories.first)
        #expect(repo.id == id)
        #expect(repo.fullName == "abc/repo1")
        #expect(repo.webURL == "https://github.com/abc/repo1")
        #expect(repo.cloneURL == "git@github.com:abc/repo1.git")
        #expect(product.links[0].url == "https://github.com/abc/repo1")
        #expect(product.links[1].url == "https://github.com/xyz/repo1", "only repository links follow")
    }

    @Test func aTypedURLKeepsItsFormWithoutCredentials() throws {
        var (product, id) = product()
        _ = try RepositoryChange.apply("https://ghp_secretvalue1234567890abcdef@github.com/abc/repo2.git", repositoryID: id, in: &product).get()
        let repo = try #require(product.repositories.first)
        #expect(repo.fullName == "abc/repo2")
        #expect(!repo.cloneURL.contains("ghp_secretvalue"))
    }

    @Test func refusesBadSameAndDuplicateTargets() {
        var (product, id) = product()
        var other = Repository()
        other.owner = "abc"
        other.name = "api"
        product.repositories.append(other)
        #expect(RepositoryChange.apply("not a repo", repositoryID: id, in: &product) == .failure(.unreadable))
        #expect(RepositoryChange.apply("xyz/repo1", repositoryID: id, in: &product) == .failure(.unchanged))
        #expect(RepositoryChange.apply("ABC/api", repositoryID: id, in: &product) == .failure(.alreadyLinked("abc/api")))
        #expect(RepositoryChange.apply("abc/repo1", repositoryID: UUID(), in: &product) == .failure(.notFound))
        #expect(product.repositories[0].fullName == "xyz/repo1")
    }

    @Test func originKeepsTheCheckoutsFormAndSkipsOtherRemotes() throws {
        let (product, _) = product()
        let old = try #require(product.repositories.first)
        let target = try #require(RepositoryURL.parse("abc/repo1"))
        #expect(RepositoryChange.originURL(current: "git@github.com:xyz/repo1.git", old: old, new: target) == "git@github.com:abc/repo1.git")
        #expect(RepositoryChange.originURL(current: "https://github.com/xyz/repo1.git", old: old, new: target) == "https://github.com/abc/repo1.git")
        #expect(RepositoryChange.originURL(current: "https://token@github.com/xyz/repo1", old: old, new: target) == "https://github.com/abc/repo1.git")
        #expect(RepositoryChange.originURL(current: "git@github.com:someone/fork.git", old: old, new: target) == nil)
    }

    @Test func setOriginRewritesTheRemote() async throws {
        let root = try makeTempDir("origin")
        defer { removeTemp(root) }
        let repo = try TestRepo.create(at: root.appending(path: "repo"))
        try git(["remote", "add", "origin", "git@github.com:xyz/repo1.git"], in: repo.url)
        let service = GitService(git: URL(fileURLWithPath: "/usr/bin/git"))
        #expect(await service.setOrigin(path: repo.path, url: "git@github.com:abc/repo1.git"))
        #expect(await service.origin(path: repo.path) == "git@github.com:abc/repo1.git")
        #expect(await service.setOrigin(path: repo.path, url: "--upload-pack=x") == false)
    }
}
