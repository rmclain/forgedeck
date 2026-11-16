import Foundation
import Testing
@testable import ForgeDeckKit

private func sample(_ world: EvidenceWorld, ok: Bool, minute: Int, problem: ObservationProblem? = nil) -> CacheUpdate {
    let at = fixedNow.addingTimeInterval(Double(minute) * 60)
    let health = HealthSample(at: at, ok: ok, latencyMS: ok ? 40 : nil, statusCode: ok ? 200 : (problem == .offline ? nil : 503),
                              problem: ok ? nil : (problem ?? .unavailable))
    return .probe(probe: world.productionProbe.id, environment: world.production.id, product: world.product.id,
                  ProbeOutcome(sample: health, deployment: nil, detail: ""))
}

private func feed(_ cache: inout ObservationCache, _ world: EvidenceWorld, _ results: [Bool], startingAt minute: Int = 0,
                  problem: ObservationProblem? = nil) {
    for (offset, ok) in results.enumerated() {
        let at = fixedNow.addingTimeInterval(Double(minute + offset) * 60)
        cache.apply([sample(world, ok: ok, minute: minute + offset, problem: problem)], portfolio: world.portfolio, now: at)
    }
}

private func healthIncidents(_ cache: ObservationCache) -> [Incident] { cache.incidents.filter { $0.rule == .healthFailing } }
private func events(_ cache: ObservationCache, _ kind: ActivityKind) -> [ActivityEvent] { cache.activity.filter { $0.kind == kind } }

@Suite struct HealthAlertTests {
    @Test func threeConsecutiveFailuresOpenExactlyOneIncident() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        feed(&cache, world, [false, false])
        #expect(healthIncidents(cache).isEmpty)
        #expect(events(cache, .alert).isEmpty)
        // Before the threshold the card says a check is failing, not that the product is down.
        #expect(ProductStatus.badge(world.product, cache: cache, now: fixedNow.addingTimeInterval(120)).label == "Check failing")

        feed(&cache, world, [false], startingAt: 2)
        #expect(healthIncidents(cache).count == 1)
        #expect(events(cache, .alert).count == 1)
        let incident = healthIncidents(cache)[0]
        #expect(incident.isOpen)
        #expect(incident.subject == world.productionProbe.id.uuidString)
        #expect(incident.productID == world.product.id)
        #expect(incident.title == "production status is failing")
        #expect(incident.detail.contains("3 checks in a row failed on Production"))
        #expect(incident.openedAt == fixedNow.addingTimeInterval(120))
        #expect(events(cache, .alert)[0].id == "alert:\(incident.id.uuidString)")
        #expect(ProductStatus.badge(world.product, cache: cache, now: fixedNow.addingTimeInterval(180)).label == "Unhealthy")
    }

    @Test func furtherFailuresAddNothing() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        feed(&cache, world, [false, false, false, false, false])
        #expect(healthIncidents(cache).count == 1)
        #expect(events(cache, .alert).count == 1)
        #expect(events(cache, .recovery).isEmpty)
        #expect(cache.activity.count == 1)
        #expect(cache.health[world.productionProbe.id]?.count == 5)
    }

    @Test func recoveryResolvesTheIncidentAndIsReportedOnce() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        feed(&cache, world, [false, false, false, false, true])
        let incident = healthIncidents(cache)[0]
        #expect(!incident.isOpen)
        #expect(incident.resolvedAt == fixedNow.addingTimeInterval(240))
        #expect(events(cache, .recovery).count == 1)
        #expect(events(cache, .recovery)[0].title == "production status recovered")
        #expect(events(cache, .alert).count == 1)

        feed(&cache, world, [true, true], startingAt: 5)
        #expect(events(cache, .recovery).count == 1)
        #expect(healthIncidents(cache).count == 1)
        #expect(ProductStatus.openIncidents(world.product, cache: cache).isEmpty)
        #expect(ProductStatus.badge(world.product, cache: cache, now: fixedNow.addingTimeInterval(420)).label == "Healthy")
    }

    @Test func aSecondOutageIsItsOwnIncident() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        feed(&cache, world, [false, false, false, true, false, false, false])
        #expect(healthIncidents(cache).count == 2)
        #expect(healthIncidents(cache).filter(\.isOpen).count == 1)
        #expect(events(cache, .alert).count == 2)
        #expect(events(cache, .recovery).count == 1)
    }

    @Test func twoFailuresThenASuccessOpenNothing() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        feed(&cache, world, [false, false, true])
        #expect(cache.incidents.isEmpty)
        #expect(cache.activity.isEmpty)
        // The streak starts over: two more failures are still not three in a row.
        feed(&cache, world, [false, false], startingAt: 3)
        #expect(cache.incidents.isEmpty)
        feed(&cache, world, [false], startingAt: 5)
        #expect(healthIncidents(cache).count == 1)
    }

    @Test func anOfflineMacOpensNoIncident() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        feed(&cache, world, [false, false, false, false, false], problem: .offline)
        #expect(cache.incidents.isEmpty)
        #expect(cache.activity.isEmpty)

        // One offline sample inside the window breaks the streak too.
        var mixed = ObservationCache()
        feed(&mixed, world, [false])
        feed(&mixed, world, [false], startingAt: 1, problem: .offline)
        feed(&mixed, world, [false], startingAt: 2)
        #expect(mixed.incidents.isEmpty)
        feed(&mixed, world, [false, false], startingAt: 3)
        #expect(healthIncidents(mixed).count == 1)
    }

    @Test func eachProbeHasItsOwnIncident() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        feed(&cache, world, [false, false, false])
        for minute in 0..<3 {
            let at = fixedNow.addingTimeInterval(Double(minute) * 60)
            cache.apply([.probe(probe: world.stagingProbe.id, environment: world.staging.id, product: world.product.id,
                                ProbeOutcome(sample: HealthSample(at: at, ok: false, statusCode: 500, problem: .unavailable), deployment: nil, detail: ""))],
                        portfolio: world.portfolio, now: at)
        }
        #expect(healthIncidents(cache).count == 2)
        #expect(Set(healthIncidents(cache).map(\.subject)) == [world.productionProbe.id.uuidString, world.stagingProbe.id.uuidString])
    }

    @Test func acknowledgeAndSnoozeChangeNeedsAttention() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        feed(&cache, world, [false, false, false])
        let id = healthIncidents(cache)[0].id
        let now = fixedNow.addingTimeInterval(300)
        #expect(cache.incidents[0].needsAttention(now: now))
        #expect(PortfolioPulse.insights(portfolio: world.portfolio, cache: cache, now: now).contains { $0.id == "incident-\(id)" })

        AlertEngine.snooze(id, for: 3_600, cache: &cache, now: now)
        #expect(!cache.incidents[0].needsAttention(now: now.addingTimeInterval(1_800)))
        #expect(cache.incidents[0].needsAttention(now: now.addingTimeInterval(3_601)))
        #expect(cache.incidents[0].isOpen)
        #expect(!PortfolioPulse.insights(portfolio: world.portfolio, cache: cache, now: now.addingTimeInterval(60)).contains { $0.id == "incident-\(id)" })

        AlertEngine.acknowledge(id, cache: &cache, now: now)
        #expect(!cache.incidents[0].needsAttention(now: now.addingTimeInterval(7_200)))
        #expect(cache.incidents[0].acknowledgedAt == now)
        // Acknowledged is not resolved: the card still shows it.
        #expect(cache.incidents[0].isOpen)
        #expect(ProductStatus.badge(world.product, cache: cache, now: now).label == "Unhealthy")
        // Unknown ids are ignored.
        AlertEngine.acknowledge(UUID(), cache: &cache, now: now)
        AlertEngine.snooze(UUID(), for: 60, cache: &cache, now: now)
        #expect(cache.incidents.count == 1)
    }

    @Test func aResolvedIncidentNeedsNoAttention() {
        var incident = Incident()
        #expect(incident.needsAttention(now: fixedNow))
        incident.resolvedAt = fixedNow
        #expect(!incident.isOpen)
        #expect(!incident.needsAttention(now: fixedNow))
    }
}

@Suite struct PortfolioAlertTests {
    @Test func aFailingPipelineAlertsOnceAcrossRefreshes() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        for minute in 0..<4 {
            let at = fixedNow.addingTimeInterval(Double(minute) * 300)
            let snapshot = world.remote(head: shaA, at: at, runs: [workflowRun(id: 1, sha: shaA, conclusion: "failure", at: fixedNow)])
            cache.apply([.remote(repository: world.repo.id, product: world.product.id, .success(snapshot))], portfolio: world.portfolio, now: at)
        }
        #expect(cache.incidents.filter { $0.rule == .pipelineBroken }.count == 1)
        #expect(events(cache, .alert).count == 1)
        // A failure on another branch is not the default branch pipeline.
        var other = ObservationCache()
        other.apply([.remote(repository: world.repo.id, product: world.product.id,
                             .success(world.remote(head: shaA, at: fixedNow, runs: [workflowRun(id: 2, sha: shaB, conclusion: "failure", at: fixedNow, branch: "feature")])))],
                    portfolio: world.portfolio, now: fixedNow)
        #expect(other.incidents.isEmpty)
    }

    @Test func anExpiringCredentialAlertsAndRotationResolvesIt() {
        var world = EvidenceWorld()
        var variable = VariableDefinition()
        variable.key = "STRIPE_KEY"
        variable.scope = .product(world.product.id)
        variable.isSecret = true
        var reference = CredentialReference.keychain()
        reference.createdAt = fixedNow.addingTimeInterval(-86_400)
        reference.expiresAt = fixedNow.addingTimeInterval(3 * 86_400)
        variable.credential = reference
        world.portfolio.variables = [variable]

        var cache = ObservationCache()
        AlertEngine.evaluate(portfolio: world.portfolio, cache: &cache, now: fixedNow)
        AlertEngine.evaluate(portfolio: world.portfolio, cache: &cache, now: fixedNow.addingTimeInterval(60))
        let incidents = cache.incidents.filter { $0.rule == .secretExpiring }
        #expect(incidents.count == 1)
        #expect(incidents.first?.title == "STRIPE_KEY needs rotation")
        #expect(events(cache, .alert).count == 1)

        world.portfolio.variables[0].credential?.expiresAt = fixedNow.addingTimeInterval(90 * 86_400)
        AlertEngine.evaluate(portfolio: world.portfolio, cache: &cache, now: fixedNow.addingTimeInterval(120))
        #expect(cache.incidents.filter { $0.rule == .secretExpiring && $0.isOpen }.isEmpty)
        #expect(events(cache, .recovery).count == 1)
    }

    @Test func aRotationReminderThatIsDueAlerts() {
        var world = EvidenceWorld()
        var variable = VariableDefinition()
        variable.key = "API_KEY"
        variable.scope = .product(world.product.id)
        variable.isSecret = true
        var reference = CredentialReference.keychain()
        reference.createdAt = fixedNow.addingTimeInterval(-100 * 86_400)
        reference.rotationIntervalDays = 90
        variable.credential = reference
        world.portfolio.variables = [variable]
        var cache = ObservationCache()
        AlertEngine.evaluate(portfolio: world.portfolio, cache: &cache, now: fixedNow)
        #expect(cache.incidents.map(\.rule) == [.secretExpiring])
        #expect(cache.incidents[0].detail == "The rotation reminder is due.")
    }

    @Test func demoAndArchivedProductsRaiseNoAlerts() {
        var world = EvidenceWorld()
        var cache = ObservationCache()
        cache.remotes[world.repo.id] = world.remote(head: shaA, at: fixedNow, runs: [workflowRun(id: 1, sha: shaA, conclusion: "failure", at: fixedNow)])
        world.portfolio.products[0].isDemo = true
        AlertEngine.evaluate(portfolio: world.portfolio, cache: &cache, now: fixedNow)
        #expect(cache.incidents.isEmpty)
        world.portfolio.products[0].isDemo = false
        world.portfolio.products[0].lifecycle = .archived
        AlertEngine.evaluate(portfolio: world.portfolio, cache: &cache, now: fixedNow)
        #expect(cache.incidents.isEmpty)
        world.portfolio.products[0].lifecycle = .active
        AlertEngine.evaluate(portfolio: world.portfolio, cache: &cache, now: fixedNow)
        #expect(cache.incidents.count == 1)
    }

    /// BUG (AlertEngine.swift, AlertEngine.evaluate): the GitHub auth-failure incident uses the fixed subject
    /// "github" for every product and repository. A product whose cached remote has no problem resolves the
    /// incident another product just opened in the same pass, so refreshing one product after the token was
    /// revoked opens and closes the incident (one alert and one recovery event) on every refresh, and no open
    /// incident remains. Fix: use a per-repository subject (repo.id), or resolve only when no repository in
    /// the portfolio still reports `.unauthorized`.
    @Test func anAuthFailureOnOneProductIsNotResolvedByAnother() {
        let failing = EvidenceWorld()
        let healthy = EvidenceWorld()
        var portfolio = Portfolio()
        portfolio.products = [failing.product, healthy.product]
        var cache = ObservationCache()
        cache.apply([.remote(repository: failing.repo.id, product: failing.product.id, .success(failing.remote(head: shaA, at: fixedNow))),
                     .remote(repository: healthy.repo.id, product: healthy.product.id, .success(healthy.remote(head: shaB, at: fixedNow)))],
                    portfolio: portfolio, now: fixedNow)
        let later = fixedNow.addingTimeInterval(60)
        cache.apply([.remote(repository: failing.repo.id, product: failing.product.id, .failure(.unauthorized, "401"))], portfolio: portfolio, now: later)
        #expect(cache.incidents.filter { $0.rule == .authFailure && $0.isOpen }.count == 1)
        #expect(events(cache, .recovery).isEmpty)
    }
}
