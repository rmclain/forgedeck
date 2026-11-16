import Foundation
import Testing
@testable import ForgeDeckKit

// What ForgeDeck may claim about an environment, and what it may not.

private func node(_ stage: ChainNode.Stage, _ world: EvidenceWorld, _ cache: ObservationCache, now: Date) -> ChainNode {
    DriftAnalyzer.chain(product: world.product, cache: cache, now: now).first { $0.stage == stage }!
}

private func relation(_ from: ChainNode.Stage, _ world: EvidenceWorld, _ cache: ObservationCache, now: Date) -> DriftAnalyzer.Relation {
    DriftAnalyzer.relations(product: world.product, cache: cache, now: now).first { $0.from == from }!
}

@Suite struct EvidenceTruthTests {
    @Test func aNewGitHubHeadDoesNotMoveProduction() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.deployment(world.observation(world.production, sha: shaA, version: "v1.0.0", at: fixedNow)),
                     .remote(repository: world.repo.id, product: world.product.id, .success(world.remote(head: shaA, at: fixedNow)))],
                    portfolio: world.portfolio, now: fixedNow)
        let later = fixedNow.addingTimeInterval(300)
        cache.apply([.remote(repository: world.repo.id, product: world.product.id, .success(world.remote(head: shaB, at: later)))],
                    portfolio: world.portfolio, now: later)

        let github = node(.github, world, cache, now: later)
        let production = node(.production, world, cache, now: later)
        #expect(github.sha == shaB)
        #expect(production.sha == shaA)
        #expect(production.version == "v1.0.0")
        #expect(production.level == .verified)
        #expect(production.sourceTitle == FactSource.runtimeProbe.title)
        #expect(production.observedAt == fixedNow)
        // The gap is reported as a gap, not as a number nobody measured.
        let gap = DriftAnalyzer.relations(product: world.product, cache: cache, now: later).first { $0.from == .github && $0.to == .production }
        #expect(gap?.comparison == .notEnoughHistory)
        // The commit is news. A deploy is not, because none was observed.
        #expect(cache.activity.contains { $0.kind == .commit && $0.id.hasSuffix(shaB) })
        #expect(!cache.activity.contains { $0.kind == .deploy })
        #expect(cache.deployments.count == 1)
    }

    @Test func greenCIWithAFailedDeployOpensAnIncidentAndKeepsTheRunningVersion() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.deployment(world.observation(world.production, sha: shaA, version: "v1.0.0", at: fixedNow))],
                    portfolio: world.portfolio, now: fixedNow)
        let later = fixedNow.addingTimeInterval(120)
        let snapshot = world.remote(head: shaB, at: later, runs: [workflowRun(id: 1, sha: shaB, conclusion: "success", at: later)],
                                    deployments: [reportedDeployment(id: 5, environment: "Production", sha: shaB, state: "failure", at: later)])
        let update = CacheUpdate.remote(repository: world.repo.id, product: world.product.id, .success(snapshot))
        cache.apply([update], portfolio: world.portfolio, now: later)

        #expect(cache.remotes[world.repo.id]?.defaultBranchRun?.succeeded == true)
        let incidents = cache.incidents.filter { $0.rule == .deployFailed }
        #expect(incidents.count == 1)
        #expect(incidents.first?.isOpen == true)
        #expect(incidents.first?.subject == world.production.id.uuidString)
        #expect(incidents.first?.detail.contains("The running version did not change") == true)
        #expect(!cache.incidents.contains { $0.rule == .pipelineBroken })

        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: later)
        #expect(evidence.observation?.sha == shaA)
        #expect(evidence.level == .verified)
        #expect(node(.production, world, cache, now: later).version == "v1.0.0")
        #expect(ProductStatus.badge(world.product, cache: cache, now: later).label == "Deploy failed")

        // The same answer again changes nothing.
        let activity = cache.activity.count
        cache.apply([update], portfolio: world.portfolio, now: later.addingTimeInterval(60))
        #expect(cache.incidents.filter { $0.rule == .deployFailed }.count == 1)
        #expect(cache.activity.count == activity)
    }

    @Test func aLaterSuccessfulDeployRecordResolvesTheIncidentButStaysReported() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.deployment(world.observation(world.production, sha: shaA, at: fixedNow))], portfolio: world.portfolio, now: fixedNow)
        let failedAt = fixedNow.addingTimeInterval(60)
        cache.apply([.remote(repository: world.repo.id, product: world.product.id, .success(world.remote(
            head: shaB, at: failedAt, deployments: [reportedDeployment(id: 5, environment: "production", sha: shaB, state: "failure", at: failedAt)])))],
                    portfolio: world.portfolio, now: failedAt)
        let fixedAt = fixedNow.addingTimeInterval(180)
        cache.apply([.remote(repository: world.repo.id, product: world.product.id, .success(world.remote(
            head: shaB, at: fixedAt, deployments: [reportedDeployment(id: 6, environment: "production", sha: shaB, state: "success", at: fixedAt)])))],
                    portfolio: world.portfolio, now: fixedAt)

        #expect(cache.incidents.filter { $0.rule == .deployFailed && $0.isOpen }.isEmpty)
        #expect(cache.activity.filter { $0.kind == .recovery }.count == 1)
        // CI says B was deployed. The server last said A, and that is still the stronger evidence.
        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: fixedAt)
        #expect(evidence.observation?.sha == shaA)
        #expect(evidence.level == .verified)
    }

    @Test func stagingAndProductionDifferWithoutAMeasuredCount() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.deployment(world.observation(world.staging, sha: shaB, at: fixedNow)),
                     .deployment(world.observation(world.production, sha: shaA, at: fixedNow))], portfolio: world.portfolio, now: fixedNow)
        let unmeasured = relation(.staging, world, cache, now: fixedNow)
        #expect(unmeasured.to == .production)
        #expect(unmeasured.comparison == .notEnoughHistory)
        #expect(unmeasured.sentence.contains("Not enough history"))
        #expect(unmeasured.sentence.contains("bbbbbbb") && unmeasured.sentence.contains("aaaaaaa"))
        // No drift alert is raised from a number nobody counted.
        #expect(!cache.incidents.contains { $0.rule == .productionDrift })
        #expect(PortfolioPulse.insights(portfolio: world.portfolio, cache: cache, now: fixedNow).allSatisfy { !$0.id.hasPrefix("drift-") })
    }

    @Test func stagingToProductionUsesTheMeasuredComparison() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.deployment(world.observation(world.staging, sha: shaB, at: fixedNow)),
                     .deployment(world.observation(world.production, sha: shaA, at: fixedNow)),
                     .comparison(key: DriftAnalyzer.comparisonKey(shaB, shaA), .ahead(3))], portfolio: world.portfolio, now: fixedNow)
        let measured = relation(.staging, world, cache, now: fixedNow)
        #expect(measured.comparison == .ahead(3))
        #expect(measured.sentence == "Staging is 3 commits ahead of Production.")
        let drift = cache.incidents.filter { $0.rule == .productionDrift }
        #expect(drift.count == 1)
        #expect(drift.first?.title == "Production is 3 commits behind staging")
        #expect(ProductStatus.badge(world.product, cache: cache, now: fixedNow).label == "Deploy pending")

        // Production catches up: the same commit on both is "same" without asking git.
        let later = fixedNow.addingTimeInterval(600)
        cache.apply([.deployment(world.observation(world.staging, sha: shaB, at: later)),
                     .deployment(world.observation(world.production, sha: shaB, at: later))], portfolio: world.portfolio, now: later)
        #expect(relation(.staging, world, cache, now: later).comparison == .same)
        #expect(cache.incidents.filter { $0.rule == .productionDrift && $0.isOpen }.isEmpty)
        #expect(ProductStatus.badge(world.product, cache: cache, now: later).label == "Healthy")
    }

    @Test func aComparisonForOtherCommitsIsNotBorrowed() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.comparisons[DriftAnalyzer.comparisonKey(shaC, shaA)] = .ahead(9)
        cache.comparisons[DriftAnalyzer.comparisonKey(shaA, shaB)] = .behind(2)
        cache.deployments = [world.observation(world.staging, sha: shaB, at: fixedNow), world.observation(world.production, sha: shaA, at: fixedNow)]
        #expect(relation(.staging, world, cache, now: fixedNow).comparison == .notEnoughHistory)
    }

    @Test func instancesOnTwoRevisionsAreAMixedRollout() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.deployment(world.observation(world.production, sha: shaA, at: fixedNow, instances: [shaA, shaB, shaA]))],
                    portfolio: world.portfolio, now: fixedNow)
        let production = node(.production, world, cache, now: fixedNow)
        #expect(production.isMixed)
        #expect(cache.deployments[0].isMixed)
        let badge = ProductStatus.badge(world.product, cache: cache, now: fixedNow)
        #expect(badge.label == "Mixed rollout")
        #expect(badge.tone == .warn)

        var uniform = ObservationCache()
        uniform.record(world.observation(world.production, sha: shaA, at: fixedNow, instances: [shaA, shaA]))
        #expect(!node(.production, world, uniform, now: fixedNow).isMixed)
        #expect(ProductStatus.badge(world.product, cache: uniform, now: fixedNow).label == "Healthy")
    }

    @Test func noEvidenceIsUnknown() {
        let connected = EvidenceWorld()
        let empty = ObservationCache()
        let evidence = DriftAnalyzer.evidence(environment: connected.production, product: connected.product, cache: empty, now: fixedNow)
        #expect(evidence.level == .unknown)
        #expect(evidence.observation == nil)
        #expect(evidence.problem == nil)
        #expect(evidence.problemDetail == "Not checked yet.")
        let production = node(.production, connected, empty, now: fixedNow)
        #expect(production.level == .unknown)
        #expect(production.sha == nil && production.version == nil)
        #expect(production.headline == "Unknown")
        #expect(ProductStatus.badge(connected.product, cache: empty, now: fixedNow).label == "No signal")
        #expect(ProductStatus.cells(connected.product, cache: empty, now: fixedNow).map(\.value) == ["Not inspected", "Not fetched", "Unknown"])

        let bare = EvidenceWorld(connected: false)
        let unconfigured = DriftAnalyzer.evidence(environment: bare.production, product: bare.product, cache: empty, now: fixedNow)
        #expect(unconfigured.level == .unknown)
        #expect(unconfigured.problem == .notConfigured)
        #expect(ProductStatus.cells(bare.product, cache: empty, now: fixedNow).last?.value == "Not connected")
        // Every stage of an empty cache is unknown, and no relation claims anything.
        #expect(DriftAnalyzer.chain(product: bare.product, cache: empty, now: fixedNow).allSatisfy { $0.level == .unknown })
        #expect(DriftAnalyzer.relations(product: bare.product, cache: empty, now: fixedNow).allSatisfy { $0.comparison == .unknown })
    }

    @Test func aVerifiedObservationPastItsExpiryIsStale() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.record(world.observation(world.production, sha: shaA, version: "v1.0.0", at: fixedNow, ttl: 900))
        #expect(DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: fixedNow.addingTimeInterval(899)).level == .verified)
        let late = fixedNow.addingTimeInterval(901)
        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: late)
        #expect(evidence.level == .stale)
        #expect(evidence.observation?.sha == shaA)
        #expect(node(.production, world, cache, now: late).level == .stale)
        let cell = ProductStatus.cells(world.product, cache: cache, now: late).last
        #expect(cell?.value == "v1.0.0 · stale")
        #expect(cell?.tone == .muted)
        #expect(ProductStatus.badge(world.product, cache: cache, now: late).label == "No signal")
        #expect(PortfolioPulse.insights(portfolio: world.portfolio, cache: cache, now: late).contains { $0.id == "stale-\(world.product.id)" })
    }

    @Test func aNewerUnauthorizedFailureDemotesVerifiedToStale() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.deployment(world.observation(world.staging, sha: shaA, at: fixedNow)),
                     .deployment(world.observation(world.production, sha: shaA, at: fixedNow))], portfolio: world.portfolio, now: fixedNow)
        let later = fixedNow.addingTimeInterval(60)
        var failure = world.observation(world.production, sha: nil, level: .unknown, at: later, problem: .unauthorized)
        failure.detail = "The status endpoint rejected the token."
        cache.apply([.deployment(failure)], portfolio: world.portfolio, now: later)

        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: later)
        #expect(evidence.level == .stale)
        #expect(evidence.problem == .unauthorized)
        #expect(evidence.problemDetail == "The status endpoint rejected the token.")
        #expect(evidence.observation?.sha == shaA)

        let production = node(.production, world, cache, now: later)
        #expect(production.level == .stale)
        #expect(production.problem == .unauthorized)
        // Same commit on both sides, but the sentence admits the production side is stale.
        let staging = relation(.staging, world, cache, now: later)
        #expect(staging.sentence.contains("(stale evidence)"))
        let cell = ProductStatus.cells(world.product, cache: cache, now: later).last
        #expect(cell?.value == "aaaaaaa · stale")
        #expect(cell?.tone == .muted)
        #expect(ProductStatus.badge(world.product, cache: cache, now: later).label != "Healthy")

        // A good answer after the failure restores it.
        let recovered = later.addingTimeInterval(60)
        cache.apply([.deployment(world.observation(world.production, sha: shaA, at: recovered))], portfolio: world.portfolio, now: recovered)
        let again = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: recovered)
        #expect(again.level == .verified)
        #expect(again.problem == nil)
    }

    @Test func onlyAFailureIsUnknownWithItsReason() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        var failure = world.observation(world.production, sha: nil, level: .unknown, at: fixedNow, problem: .unauthorized)
        failure.detail = "401"
        cache.record(failure)
        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: fixedNow)
        #expect(evidence.level == .unknown)
        #expect(evidence.observation == nil)
        #expect(evidence.problem == .unauthorized)
        let production = node(.production, world, cache, now: fixedNow)
        #expect(production.sha == nil)
        #expect(production.headline == "Authentication required")
        let cell = ProductStatus.cells(world.product, cache: cache, now: fixedNow).last
        #expect(cell?.value == "Authentication required")
        #expect(cell?.tone == .warn)
        #expect(relation(.staging, world, cache, now: fixedNow).comparison == .unknown)
    }

    @Test func aReportedRecordNeverOutranksAFreshVerifiedObservation() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.record(world.observation(world.production, sha: shaA, at: fixedNow))
        // Newer, but only a record.
        cache.record(world.observation(world.production, sha: shaB, source: .deploymentRecord, level: .reported,
                                       at: fixedNow.addingTimeInterval(300), deployState: "success"))
        let now = fixedNow.addingTimeInterval(400)
        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: now)
        #expect(evidence.observation?.sha == shaA)
        #expect(evidence.level == .verified)
        #expect(evidence.observation?.provenance.source == .runtimeProbe)
        #expect(ProductStatus.cells(world.product, cache: cache, now: now).last?.value == "aaaaaaa")
    }

    @Test func aRecordAloneIsReportedNotVerified() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.record(world.observation(world.production, sha: shaB, source: .deploymentRecord, level: .reported, at: fixedNow, deployState: "success"))
        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: fixedNow)
        #expect(evidence.level == .reported)
        let cell = ProductStatus.cells(world.product, cache: cache, now: fixedNow).last
        #expect(cell?.value == "bbbbbbb · reported")
        #expect(cell?.tone == .accent)
        cache.record(world.observation(world.staging, sha: shaB, at: fixedNow))
        #expect(relation(.staging, world, cache, now: fixedNow).sentence.contains("(reported, not verified)"))
    }

    @Test func anUnfinishedOrFailedDeployRecordIsNotTheRunningVersion() {
        let world = EvidenceWorld()
        for state in ["in_progress", "queued", "pending", "failure", "error", "inactive", "unknown"] {
            var cache = ObservationCache()
            cache.record(world.observation(world.production, sha: shaB, source: .deploymentRecord, level: .reported, at: fixedNow, deployState: state))
            let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: fixedNow)
            #expect(evidence.observation == nil, "\(state)")
            #expect(evidence.level == .unknown, "\(state)")
        }
    }

    @Test func localGitHubAndProductionStayDistinct() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.git(checkout: world.checkout.id, world.gitSnapshot(head: shaA, at: fixedNow)),
                     .remote(repository: world.repo.id, product: world.product.id, .success(world.remote(head: shaB, at: fixedNow))),
                     .deployment(world.observation(world.production, sha: shaC, at: fixedNow))], portfolio: world.portfolio, now: fixedNow)
        let chain = DriftAnalyzer.chain(product: world.product, cache: cache, now: fixedNow)
        #expect(chain.map(\.stage) == [.local, .github, .staging, .production])
        #expect(chain.map(\.sha) == [shaA, shaB, nil, shaC])
        #expect(chain.map(\.level) == [.verified, .verified, .unknown, .verified])
        #expect(chain.map(\.sourceTitle) == ["Local checkout", "GitHub API", "—", "Runtime status endpoint"])
        let relations = DriftAnalyzer.relations(product: world.product, cache: cache, now: fixedNow)
        #expect(relations.map(\.comparison) == [.notEnoughHistory, .notEnoughHistory, .unknown])
        #expect(!relations.contains { $0.comparison == .same })
        let cells = ProductStatus.cells(world.product, cache: cache, now: fixedNow)
        #expect(cells.map(\.value) == ["main · clean", "main · bbbbbbb", "ccccccc"])
        #expect(!cells.contains { $0.value == "In sync" })
    }

    @Test func inSyncNeedsTheSameCommit() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.git[world.checkout.id] = world.gitSnapshot(head: shaA, at: fixedNow)
        cache.remotes[world.repo.id] = world.remote(head: shaA, at: fixedNow)
        #expect(ProductStatus.cells(world.product, cache: cache, now: fixedNow)[1].value == "In sync")
        // Once the GitHub observation expires, it is no longer claimed.
        let late = fixedNow.addingTimeInterval(1_000)
        #expect(ProductStatus.cells(world.product, cache: cache, now: late)[1].value == "Stale · aaaaaaa")
        #expect(node(.github, world, cache, now: late).level == .stale)
    }
}

@Suite struct RemoteCacheTests {
    @Test func aFailedFetchKeepsTheLastHeadAndRecordsTheProblem() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.remote(repository: world.repo.id, product: world.product.id, .success(world.remote(head: shaA, at: fixedNow)))],
                    portfolio: world.portfolio, now: fixedNow)
        let later = fixedNow.addingTimeInterval(60)
        cache.apply([.remote(repository: world.repo.id, product: world.product.id, .failure(.unauthorized, "401"))], portfolio: world.portfolio, now: later)

        let remote = cache.remotes[world.repo.id]
        #expect(remote?.headSHA == shaA)
        #expect(remote?.problem == .unauthorized)
        #expect(remote?.provenance.observedAt == fixedNow)
        let sync = cache.sync["github:\(world.repo.id.uuidString)"]
        #expect(sync?.lastAttempt == later)
        #expect(sync?.lastSuccess == fixedNow)
        #expect(sync?.lastProblem == .unauthorized)
        #expect(node(.github, world, cache, now: later).problem == .unauthorized)
        #expect(node(.github, world, cache, now: fixedNow.addingTimeInterval(2_000)).level == .stale)

        #expect(cache.incidents.filter { $0.rule == .authFailure && $0.isOpen }.count == 1)
        #expect(ProductStatus.badge(world.product, cache: cache, now: later).label == "Sign-in needed")
        let recovered = later.addingTimeInterval(60)
        cache.apply([.remote(repository: world.repo.id, product: world.product.id, .success(world.remote(head: shaA, at: recovered)))],
                    portfolio: world.portfolio, now: recovered)
        #expect(cache.incidents.filter { $0.rule == .authFailure && $0.isOpen }.isEmpty)
        #expect(cache.remotes[world.repo.id]?.problem == nil)
    }

    @Test func aFailedFirstFetchIsUnknownNotEmpty() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.remote(repository: world.repo.id, product: world.product.id, .failure(.rateLimited, "wait"))], portfolio: world.portfolio, now: fixedNow)
        let github = node(.github, world, cache, now: fixedNow)
        #expect(github.sha == nil)
        #expect(github.level == .unknown)
        #expect(github.problem == .rateLimited)
        #expect(ProductStatus.cells(world.product, cache: cache, now: fixedNow)[1].value == "Rate limited")
        #expect(cache.sync["github:\(world.repo.id.uuidString)"]?.lastSuccess == nil)
    }

    @Test func theFirstFetchAnnouncesNothingAndLaterChangesAreNews() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        var pr = PullRequestSummary()
        pr.number = 7
        pr.title = "Existing"
        var first = world.remote(head: shaA, at: fixedNow, runs: [workflowRun(id: 1, sha: shaA, conclusion: "failure", at: fixedNow)])
        first.pullRequests = [pr]
        cache.apply([.remote(repository: world.repo.id, product: world.product.id, .success(first))], portfolio: world.portfolio, now: fixedNow)
        // History is not news: only the alert for the failing pipeline exists.
        #expect(cache.activity.map(\.kind) == [.alert])
        #expect(cache.incidents.filter { $0.rule == .pipelineBroken && $0.isOpen }.count == 1)
        #expect(ProductStatus.badge(world.product, cache: cache, now: fixedNow).label == "Build failed")

        let later = fixedNow.addingTimeInterval(300)
        var newPR = PullRequestSummary()
        newPR.number = 8
        newPR.title = "Add export"
        newPR.author = "maya"
        newPR.updatedAt = later
        var second = world.remote(head: shaB, at: later, runs: [workflowRun(id: 1, sha: shaA, conclusion: "failure", at: fixedNow),
                                                                workflowRun(id: 2, sha: shaB, conclusion: "success", at: later)])
        second.pullRequests = [pr, newPR]
        let update = CacheUpdate.remote(repository: world.repo.id, product: world.product.id, .success(second))
        cache.apply([update], portfolio: world.portfolio, now: later)
        #expect(cache.activity.filter { $0.kind == .commit }.count == 1)
        #expect(cache.activity.filter { $0.kind == .pullRequest }.map(\.title) == ["PR #8 opened: Add export"])
        #expect(cache.activity.filter { $0.kind == .recovery }.count == 1)
        #expect(cache.incidents.filter { $0.rule == .pipelineBroken && $0.isOpen }.isEmpty)

        // Applying the same snapshot again adds no events.
        let count = cache.activity.count
        cache.apply([update], portfolio: world.portfolio, now: later.addingTimeInterval(60))
        #expect(cache.activity.count == count)
    }

    @Test func updatesForUnknownProductsOrRepositoriesAreIgnored() {
        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.apply([.remote(repository: UUID(), product: world.product.id, .success(world.remote(head: shaA, at: fixedNow))),
                     .remote(repository: world.repo.id, product: UUID(), .success(world.remote(head: shaA, at: fixedNow))),
                     .probe(probe: UUID(), environment: world.production.id, product: world.product.id,
                            ProbeOutcome(sample: HealthSample(at: fixedNow, ok: false), deployment: nil, detail: ""))],
                    portfolio: world.portfolio, now: fixedNow)
        #expect(cache.remotes.isEmpty && cache.health.isEmpty && cache.sync.isEmpty)
    }
}

@Suite struct RuntimeProbeFlowTests {
    private func companionJSON(sha: String, version: String) -> String {
        "{\"schema_version\": \"1.0\", \"environment\": \"production\", \"release\": {\"commit_sha\": \"\(sha)\", \"version\": \"\(version)\"}, \"health\": {\"state\": \"healthy\"}}"
    }

    private func probeOnce(_ connector: HTTPProbeConnector, _ world: EvidenceWorld, into cache: inout ObservationCache) async {
        let outcome = await connector.status(world.productionProbe, bearer: nil, expectedTier: .production)
        cache.apply([.probe(probe: world.productionProbe.id, environment: world.production.id, product: world.product.id, outcome)],
                    portfolio: world.portfolio, now: .now)
    }

    @Test func aProbeAnswerBecomesVerifiedEvidenceAndAReleaseChangeIsAnnouncedOnce() async {
        let world = EvidenceWorld()
        let http = MockHTTPClient()
        http.on("/_forgedeck/v1/status", json: companionJSON(sha: shaA, version: "v1.0.0"))
        http.on("/_forgedeck/v1/status", json: companionJSON(sha: shaB, version: "v1.1.0"))
        let connector = HTTPProbeConnector(http: http, ttl: 900)
        var cache = ObservationCache()

        await probeOnce(connector, world, into: &cache)
        var evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: .now)
        #expect(evidence.level == .verified)
        #expect(evidence.observation?.sha == shaA)
        #expect(evidence.observation?.productID == world.product.id)
        #expect(evidence.observation?.environmentID == world.production.id)
        #expect(cache.activity.isEmpty)
        #expect(ProductStatus.badge(world.product, cache: cache).label == "Healthy")

        await probeOnce(connector, world, into: &cache)
        await probeOnce(connector, world, into: &cache)
        evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: .now)
        #expect(evidence.observation?.sha == shaB)
        #expect(evidence.observation?.version == "v1.1.0")
        let deploys = cache.activity.filter { $0.kind == .deploy }
        #expect(deploys.count == 1)
        #expect(deploys.first?.title == "Production now runs v1.1.0")
        #expect(deploys.first?.detail.contains("aaaaaaa") == true)
        #expect(cache.deployments.count == 2)
        #expect(cache.health[world.productionProbe.id]?.count == 3)
    }

    @Test func aRevokedTokenAfterAGoodAnswerIsStaleWithTheReason() async {
        let world = EvidenceWorld()
        let http = MockHTTPClient()
        http.on("/_forgedeck/v1/status", json: companionJSON(sha: shaA, version: "v1.0.0"))
        http.on("/_forgedeck/v1/status", status: 401, json: "{}")
        let connector = HTTPProbeConnector(http: http, ttl: 900)
        var cache = ObservationCache()
        for _ in 0..<2 {
            let outcome = await connector.status(world.productionProbe, bearer: "token", expectedTier: .production)
            cache.apply([.probe(probe: world.productionProbe.id, environment: world.production.id, product: world.product.id, outcome)],
                        portfolio: world.portfolio, now: .now)
        }
        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: .now)
        #expect(evidence.level == .stale)
        #expect(evidence.problem == .unauthorized)
        #expect(evidence.observation?.sha == shaA)
        #expect(cache.sync["probe:\(world.productionProbe.id.uuidString)"]?.lastProblem == .unauthorized)
    }

    @Test func aStagingBuildOnTheProductionURLNeverBecomesProductionEvidence() async {
        let world = EvidenceWorld()
        let http = MockHTTPClient()
        http.on("/_forgedeck/v1/status", json: "{\"schema_version\": \"1.0\", \"environment\": \"staging\", \"release\": {\"commit_sha\": \"\(shaB)\"}, \"health\": {\"state\": \"healthy\"}}")
        let outcome = await HTTPProbeConnector(http: http).status(world.productionProbe, bearer: nil, expectedTier: .production)
        var cache = ObservationCache()
        cache.apply([.probe(probe: world.productionProbe.id, environment: world.production.id, product: world.product.id, outcome)],
                    portfolio: world.portfolio, now: .now)
        let evidence = DriftAnalyzer.evidence(environment: world.production, product: world.product, cache: cache, now: .now)
        #expect(evidence.observation == nil)
        #expect(evidence.level == .unknown)
        #expect(evidence.problem == .malformed)
        #expect(DriftAnalyzer.chain(product: world.product, cache: cache).last?.sha == nil)
    }
}

@Suite struct StatusPresentationTests {
    @Test func headlinePrefersVersionThenCommitThenTheGap() {
        var node = ChainNode(stage: .production, title: "Production", sha: shaA, version: "v2.0.0", level: .verified, sourceTitle: "x", detail: "")
        #expect(node.headline == "v2.0.0")
        node.version = nil
        #expect(node.headline == "aaaaaaa")
        node.sha = nil
        node.level = .unknown
        #expect(node.headline == "Unknown")
        node.problem = .hostKeyChanged
        #expect(node.headline == "Host key changed")
    }

    @Test func badgesNeverSayHealthyWithoutASignal() {
        var idea = Product(name: "Idea")
        idea.lifecycle = .idea
        #expect(ProductStatus.badge(idea, cache: ObservationCache(), now: fixedNow).label == "Not connected")
        idea.checkouts = [LocalCheckout()]
        #expect(ProductStatus.badge(idea, cache: ObservationCache(), now: fixedNow).label == "Idea")
        var archived = Product(name: "Old")
        archived.lifecycle = .archived
        #expect(ProductStatus.badge(archived, cache: ObservationCache(), now: fixedNow).label == "Archived")

        let world = EvidenceWorld()
        var cache = ObservationCache()
        cache.record(world.observation(world.production, sha: shaA, at: fixedNow, health: .unknown))
        #expect(ProductStatus.badge(world.product, cache: cache, now: fixedNow).label == "No signal")
        cache.record(world.observation(world.production, sha: shaB, at: fixedNow.addingTimeInterval(1), health: .degraded))
        #expect(ProductStatus.badge(world.product, cache: cache, now: fixedNow.addingTimeInterval(2)).label == "Degraded")
        cache.record(world.observation(world.production, sha: shaC, at: fixedNow.addingTimeInterval(3), health: .unhealthy))
        #expect(ProductStatus.badge(world.product, cache: cache, now: fixedNow.addingTimeInterval(4)).label == "Unhealthy")
    }

    @Test func pulseHeadlineCountsOnlyWhatReports() {
        var portfolio = Portfolio()
        #expect(PortfolioPulse.headline(portfolio: portfolio, cache: ObservationCache(), now: fixedNow).hasPrefix("Add a product"))
        let world = EvidenceWorld()
        portfolio = world.portfolio
        #expect(PortfolioPulse.headline(portfolio: portfolio, cache: ObservationCache(), now: fixedNow) == "1 product, none connected to a health source yet.")
        var cache = ObservationCache()
        cache.record(world.observation(world.production, sha: shaA, at: fixedNow))
        #expect(PortfolioPulse.headline(portfolio: portfolio, cache: cache, now: fixedNow) == "All 1 products report healthy.")
    }
}
