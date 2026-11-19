import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct ProductFinderTests {
    private func product(_ name: String, slug: String, group: String = "Products", folder: String? = nil, repo: String? = nil) -> Product {
        var product = Product(name: name)
        product.slug = slug
        product.group = group
        var checkout = LocalCheckout()
        checkout.name = "main"
        checkout.path = "/Users/me/Projects/\(folder ?? slug)"
        product.checkouts = [checkout]
        if let repo {
            var repository = Repository()
            repository.owner = "someone"
            repository.name = repo
            product.repositories = [repository]
        }
        return product
    }

    private var products: [Product] {
        [product("Ledger", slug: "ledger"), product("Ledger Guest", slug: "ledger-guest"),
         product("ledger-cloud", slug: "ledger-cloud", folder: "lg-cloud"), product("Harbor Pilot", slug: "harbor-pilot", group: "Mobile Apps"),
         product("harbor-fishing", slug: "harbor-fishing", group: "Mobile Apps", repo: "hf-game")]
    }

    private func name(_ match: ProductFinder.Match) -> String? {
        if case .one(let product) = match { return product.name }
        return nil
    }

    @Test func anExactNameWinsOverLongerNamesThatStartTheSame() {
        #expect(name(ProductFinder.find("ledger", in: products)) == "Ledger")
        #expect(name(ProductFinder.find("Ledger-Cloud", in: products)) == "ledger-cloud")
        #expect(name(ProductFinder.find("ledger cloud", in: products)) == "ledger-cloud")
    }

    @Test func partsOfWordsFolderNamesAndRepositoriesFind() {
        #expect(name(ProductFinder.find("guest", in: products)) == "Ledger Guest")
        #expect(name(ProductFinder.find("harbor fish", in: products)) == "harbor-fishing")
        #expect(name(ProductFinder.find("lg-cloud", in: products)) == "ledger-cloud")
        #expect(name(ProductFinder.find("hf-game", in: products)) == "harbor-fishing")
    }

    @Test func severalThatFitEquallyAreReturnedToAsk() {
        guard case .several(let matches) = ProductFinder.find("harbor", in: products) else { Issue.record("expected several"); return }
        #expect(Set(matches.map(\.slug)) == ["harbor-pilot", "harbor-fishing"])
        #expect(ProductFinder.find("nothing like it", in: products) == .none)
        #expect(ProductFinder.find("   ", in: products) == .none)
    }

    @Test func aNumberPicksFromTheList() {
        #expect(name(ProductFinder.find("2", in: products)) == "Ledger Guest")
        #expect(name(ProductFinder.find("#5", in: products)) == "harbor-fishing")
        #expect(ProductFinder.find("9", in: products) == .none)
    }

    @Test func theListIsGroupedAndLeavesOutDemoArchivedAndFolderless() {
        var portfolio = Portfolio()
        var demo = product("Demo", slug: "demo")
        demo.isDemo = true
        var archived = product("Old", slug: "old")
        archived.lifecycle = .archived
        var remote = product("Remote Only", slug: "remote-only")
        remote.checkouts = []
        portfolio.products = products + [demo, archived, remote]
        let list = ProductFinder.workable(in: portfolio)
        #expect(list.map(\.slug) == ["harbor-pilot", "harbor-fishing", "ledger", "ledger-guest", "ledger-cloud"])
        #expect(ProductFinder.short("/Users/me/Projects/x", home: "/Users/me") == "~/Projects/x")
    }
}
