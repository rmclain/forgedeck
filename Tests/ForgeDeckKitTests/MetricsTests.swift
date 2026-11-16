import Foundation
import Testing
@testable import ForgeDeckKit

private let metricsPath = "/_forgedeck/v1/metrics"
private let leadsPath = "/_forgedeck/v1/leads"

private func makeSource(baseURL: String = "https://metrics.acme.example") -> MetricSource {
    var source = MetricSource()
    source.name = "Companion"
    source.baseURL = baseURL
    return source
}

private func item(_ id: String, at: String = "2026-01-02T03:04:05Z", kind: String = "lead", extra: String = "") -> String {
    "{\"id\": \"\(id)\", \"kind\": \"\(kind)\", \"occurred_at\": \"\(at)\", \"title\": \"Event \(id)\"\(extra)}"
}

private func page(_ items: [String], next: String? = nil) -> String {
    "{\"items\": [\(items.joined(separator: ","))]\(next.map { ", \"next_cursor\": \"\($0)\"" } ?? "")}"
}

private func lead(_ id: String, at: Date, kind: BusinessEventKind = .lead, product: UUID? = nil, source: UUID? = nil) -> LeadEvent {
    var event = LeadEvent()
    event.id = id
    event.kind = kind
    event.occurredAt = at
    event.receivedAt = at
    event.title = "Event \(id)"
    if let product { event.productID = product }
    if let source { event.sourceID = source }
    return event
}

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Suite struct MetricsConnectorTests {
    @Test func metricsAreParsedIntoReportedSamples() async {
        let http = MockHTTPClient()
        http.on("\(metricsPath)?window=24h", json: """
        {"schema_version": "1.0", "observed_at": "2020-01-01T00:00:00Z", "window": "24h", "source": "Stripe", "metrics": {"mrr_cents": 184200, "leads": 5}}
        """)
        let source = makeSource()
        let productID = UUID()
        let result = await CompanionMetricsConnector(http: http, ttl: 600).metrics(source, productID: productID, window: "24h", bearer: "metrics-token")
        guard case .success(let samples) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(samples.map(\.key) == ["leads", "mrr_cents"])
        #expect(samples.map(\.value) == [5, 184_200])
        #expect(samples.allSatisfy { $0.window == "24h" && $0.sourceLabel == "Stripe" && $0.sourceID == source.id && $0.productID == productID })
        #expect(samples.allSatisfy { $0.provenance.level == .reported && $0.provenance.source == .metricsAPI })
        // The observation time is when this Mac got the answer, not what the server claims.
        #expect(samples.allSatisfy { abs($0.provenance.observedAt.timeIntervalSinceNow) < 60 })
        let request = http.requests.first
        #expect(request?.url?.absoluteString == "https://metrics.acme.example/_forgedeck/v1/metrics?window=24h")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer metrics-token")
    }

    @Test func anUnsupportedWindowIsRefusedWithoutARequest() async {
        let http = MockHTTPClient()
        for window in ["1y", "1h", "", "24h; drop"] {
            let result = await CompanionMetricsConnector(http: http).metrics(makeSource(), productID: UUID(), window: window, bearer: nil)
            #expect(result.problem == .unsupported, "\(window)")
        }
        #expect(http.requests.isEmpty)
        #expect(CompanionMetricsConnector.windows == ["24h", "7d", "30d", "90d"])
    }

    @Test func theSourceNameIsUsedWhenTheBodyNamesNone() async {
        let http = MockHTTPClient()
        http.on(metricsPath, json: "{\"schema_version\": \"1.0\", \"metrics\": {\"signups\": 2}}")
        let result = await CompanionMetricsConnector(http: http).metrics(makeSource(), productID: UUID(), window: "7d", bearer: nil)
        #expect(result.value?.first?.sourceLabel == "Companion")
        #expect(result.value?.first?.window == "7d")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func baseURLFormsResolveToTheContractRoot() async {
        for base in ["https://metrics.acme.example", "https://metrics.acme.example/", "https://metrics.acme.example/_forgedeck/v1",
                     "https://metrics.acme.example/_forgedeck/v1/"] {
            let http = MockHTTPClient()
            http.on(metricsPath, json: "{\"schema_version\": \"1.0\", \"metrics\": {}}")
            let result = await CompanionMetricsConnector(http: http).metrics(makeSource(baseURL: base), productID: UUID(), window: "24h", bearer: nil)
            #expect(result.problem == nil, "\(base)")
            #expect(http.requests.first?.url?.path == metricsPath, "\(base)")
        }
        let http = MockHTTPClient()
        http.on("/api/_forgedeck/v1/metrics", json: "{\"schema_version\": \"1.0\", \"metrics\": {}}")
        let nested = await CompanionMetricsConnector(http: http).metrics(makeSource(baseURL: "https://acme.example/api"), productID: UUID(), window: "24h", bearer: nil)
        #expect(nested.problem == nil)
    }

    @Test func metricFailuresAreTyped() async {
        for (status, problem) in [(401, ObservationProblem.unauthorized), (403, .forbidden), (404, .notFound), (429, .rateLimited), (502, .unavailable)] {
            let http = MockHTTPClient()
            http.on(metricsPath, status: status, json: "{}")
            #expect(await CompanionMetricsConnector(http: http).metrics(makeSource(), productID: UUID(), window: "24h", bearer: "t").problem == problem)
        }
        let malformed = MockHTTPClient()
        malformed.on(metricsPath, json: "{\"schema_version\": \"1.0\", \"metrics\": \"lots\"}")
        #expect(await CompanionMetricsConnector(http: malformed).metrics(makeSource(), productID: UUID(), window: "24h", bearer: nil).problem == .malformed)
        let offline = MockHTTPClient()
        offline.on(metricsPath, .error(.notConnectedToInternet))
        #expect(await CompanionMetricsConnector(http: offline).metrics(makeSource(), productID: UUID(), window: "24h", bearer: nil).problem == .offline)
        let insecure = MockHTTPClient()
        #expect(await CompanionMetricsConnector(http: insecure).metrics(makeSource(baseURL: "http://metrics.acme.example"), productID: UUID(), window: "24h", bearer: "t").problem == .notConfigured)
        #expect(insecure.requests.isEmpty)
    }

    @Test func eventsFollowNextCursorAcrossPages() async {
        let http = MockHTTPClient()
        http.on("\(leadsPath)?limit=100", json: page([item("1"), item("2")], next: "c2"))
        http.on("\(leadsPath)?cursor=c2&limit=100", json: page([item("3", kind: "paid_conversion", extra: ", \"value_cents\": 4900, \"source\": \"Stripe\"")], next: "c3"))
        http.on("\(leadsPath)?cursor=c3&limit=100", json: page([item("4", kind: "something_new")]))
        let source = makeSource()
        let productID = UUID()
        let result = await CompanionMetricsConnector(http: http).events(source, productID: productID, bearer: "t", maxPages: 5)
        guard case .success(let events) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(events.map(\.id) == (1...4).map { "\(source.id.uuidString):\($0)" })
        #expect(events.map(\.kind) == [.lead, .lead, .paidConversion, .custom])
        #expect(events[2].valueCents == 4_900)
        #expect(events[2].sourceLabel == "Stripe")
        #expect(events[0].sourceLabel == "Companion")
        #expect(events.allSatisfy { $0.productID == productID && $0.sourceID == source.id })
        #expect(events[0].occurredAt == date("2026-01-02T03:04:05Z"))
        #expect(http.requests.count == 3)
        #expect(http.requests.map { $0.url?.query } == ["limit=100", "cursor=c2&limit=100", "cursor=c3&limit=100"])
    }

    @Test func maxPagesCapsTheNumberOfRequests() async {
        let http = MockHTTPClient()
        http.on("\(leadsPath)?limit=100", json: page([item("1")], next: "a"))
        http.on("\(leadsPath)?cursor=a&limit=100", json: page([item("2")], next: "b"))
        http.on("\(leadsPath)?cursor=b&limit=100", json: page([item("3")], next: "c"))
        let result = await CompanionMetricsConnector(http: http).events(makeSource(), productID: UUID(), bearer: nil, maxPages: 2)
        #expect(result.value?.count == 2)
        #expect(http.requests.count == 2)
    }

    @Test func aCursorThatRepeatsDoesNotLoopForever() async {
        let http = MockHTTPClient()
        http.on("\(leadsPath)?limit=100", json: page([item("1"), item("2")], next: "same"))
        http.on("\(leadsPath)?cursor=same&limit=100", json: page([item("1"), item("2")], next: "same"))
        let result = await CompanionMetricsConnector(http: http).events(makeSource(), productID: UUID(), bearer: nil, maxPages: 50)
        #expect(http.requests.count == 2)
        #expect(result.problem == nil)

        // The repeated page is read twice and counted once.
        var cache = ObservationCache()
        let fresh = cache.merge(leads: result.value ?? [])
        #expect(fresh.count == 2)
        #expect(cache.leads.count == 2)
        #expect(cache.merge(leads: result.value ?? []).isEmpty)
        #expect(cache.leads.count == 2)
    }

    @Test func malformedEventsAreSkippedAndReportedAsPartial() async {
        let http = MockHTTPClient()
        http.on(leadsPath, json: page([item("1"), item("", at: "2026-01-02T03:04:05Z"), item("3", at: "not a date"),
                                       "{\"id\": \"4\", \"title\": \"no time\"}", item("5", at: "2026-01-03T00:00:00.250Z")]))
        let result = await CompanionMetricsConnector(http: http).events(makeSource(), productID: UUID(), bearer: nil)
        guard case .partial(let events, let missing) = result else { Issue.record("expected partial, got \(result)"); return }
        #expect(events.map { $0.id.split(separator: ":").last.map(String.init) } == ["1", "5"])
        #expect(missing == ["3 malformed events"])
    }

    @Test func eventFailures() async {
        let unauthorized = MockHTTPClient()
        unauthorized.on(leadsPath, status: 401, json: "{}")
        #expect(await CompanionMetricsConnector(http: unauthorized).events(makeSource(), productID: UUID(), bearer: "t").problem == .unauthorized)

        let malformed = MockHTTPClient()
        malformed.on(leadsPath, json: "{\"events\": []}")
        #expect(await CompanionMetricsConnector(http: malformed).events(makeSource(), productID: UUID(), bearer: nil).problem == .malformed)

        // A page that fails after a good one keeps what was read.
        let later = MockHTTPClient()
        later.on("\(leadsPath)?limit=100", json: page([item("1")], next: "n"))
        later.on("\(leadsPath)?cursor=n&limit=100", status: 503, json: "{}")
        let result = await CompanionMetricsConnector(http: later).events(makeSource(), productID: UUID(), bearer: nil)
        guard case .partial(let events, let missing) = result else { Issue.record("expected partial, got \(result)"); return }
        #expect(events.count == 1)
        #expect(missing == ["later pages (Unavailable)"])
    }

    @Test func contactsAreMaskedOnArrival() async throws {
        let http = MockHTTPClient()
        http.on(leadsPath, json: page([item("1", extra: ", \"contact\": \"jane.doe@example.com\""),
                                       item("2", extra: ", \"contact\": \"+1 555 010 9999\""), item("3")]))
        let result = await CompanionMetricsConnector(http: http).events(makeSource(), productID: UUID(), bearer: nil)
        let events = try #require(result.value)
        #expect(events[0].maskedContact == "j***@e***.com")
        #expect(events[1].maskedContact?.hasPrefix("+") == true)
        #expect(events[2].maskedContact == nil)

        var cache = ObservationCache()
        cache.merge(leads: events)
        let stored = String(decoding: try JSONCoding.encoder().encode(cache), as: UTF8.self)
        for raw in ["jane.doe@example.com", "jane.doe", "example.com", "555 010 9999", "555 010"] {
            #expect(!stored.contains(raw), "the cache holds \(raw)")
        }
    }
}

@Suite struct MetricsCacheTests {
    private func sample(_ world: EvidenceWorld, source: UUID, key: String, value: Double, window: String = "24h", at: Date) -> MetricSample {
        var sample = MetricSample()
        sample.productID = world.product.id
        sample.sourceID = source
        sample.key = key
        sample.window = window
        sample.value = value
        sample.sourceLabel = "Companion"
        sample.provenance = Provenance(observedAt: at, source: .metricsAPI, level: .reported, ttl: 900)
        return sample
    }

    @Test func aFailedRefreshKeepsTheOldNumbersAsStaleNotZero() {
        var world = EvidenceWorld()
        let source = makeSource()
        let productionIndex = world.portfolio.products[0].environments.firstIndex { $0.tier == .production }!
        world.portfolio.products[0].environments[productionIndex].metricSources = [source]
        let syncKey = "metrics:\(source.id.uuidString)"
        var cache = ObservationCache()
        cache.apply([.metrics(source: source.id, .success([sample(world, source: source.id, key: "leads", value: 7, at: fixedNow),
                                                           sample(world, source: source.id, key: "mrr_cents", value: 184_200, window: "30d", at: fixedNow)]))],
                    portfolio: world.portfolio, now: fixedNow)
        #expect(cache.metrics.count == 2)
        #expect(cache.sync[syncKey]?.lastSuccess == fixedNow)
        #expect(cache.sync[syncKey]?.lastProblem == nil)
        let before = cache.metrics
        let points = cache.points

        let later = fixedNow.addingTimeInterval(2 * 3_600)
        cache.apply([.metrics(source: source.id, .failure(.unavailable, "The server failed (503)."))], portfolio: world.portfolio, now: later)

        #expect(cache.metrics == before)
        #expect(cache.points == points)
        let leads = MetricMath.latest(cache.metrics, productID: world.product.id, key: "leads", window: "24h")
        #expect(leads.map(\.value) == [7])
        #expect(leads.first?.provenance.observedAt == fixedNow)
        #expect(leads.first?.provenance.effectiveLevel(now: later) == .stale)
        #expect(leads.first?.provenance.effectiveLevel(now: fixedNow.addingTimeInterval(60)) == .reported)
        #expect(cache.sync[syncKey]?.lastProblem == .unavailable)
        #expect(cache.sync[syncKey]?.lastAttempt == later)
        #expect(cache.sync[syncKey]?.lastSuccess == fixedNow)
        // The stall is an incident, and it says the numbers are stale.
        let stalled = cache.incidents.filter { $0.rule == .leadIngestStalled }
        #expect(stalled.count == 1)
        #expect(stalled.first?.detail.contains("stale") == true)

        // A good answer replaces the value and clears the problem.
        let recovered = later.addingTimeInterval(600)
        cache.apply([.metrics(source: source.id, .success([sample(world, source: source.id, key: "leads", value: 9, at: recovered)]))],
                    portfolio: world.portfolio, now: recovered)
        #expect(MetricMath.latest(cache.metrics, key: "leads", window: "24h").map(\.value) == [9])
        #expect(cache.metrics.count == 2)
        #expect(cache.sync[syncKey]?.lastProblem == nil)
        #expect(cache.incidents.filter { $0.rule == .leadIngestStalled && $0.isOpen }.isEmpty)
    }

    @Test func anOfflineMacDoesNotRaiseAStallIncident() {
        var world = EvidenceWorld()
        let source = makeSource()
        world.portfolio.products[0].environments[2].metricSources = [source]
        var cache = ObservationCache()
        cache.apply([.metrics(source: source.id, .success([sample(world, source: source.id, key: "leads", value: 7, at: fixedNow)]))],
                    portfolio: world.portfolio, now: fixedNow)
        cache.apply([.metrics(source: source.id, .failure(.offline, "offline"))], portfolio: world.portfolio, now: fixedNow.addingTimeInterval(7_200))
        #expect(cache.incidents.isEmpty)
        #expect(cache.metrics.first?.value == 7)
    }

    @Test func aFailureBeforeAnySuccessLeavesNoNumberAtAll() {
        let world = EvidenceWorld()
        let source = UUID()
        var cache = ObservationCache()
        cache.apply([.metrics(source: source, .failure(.unauthorized, "401"))], portfolio: world.portfolio, now: fixedNow)
        #expect(cache.metrics.isEmpty)
        #expect(cache.points.isEmpty)
        #expect(cache.sync["metrics:\(source.uuidString)"]?.lastSuccess == nil)
        #expect(cache.sync["metrics:\(source.uuidString)"]?.lastProblem == .unauthorized)
    }

    @Test func dailyPointsAreReplacedPerDayNotAppended() {
        let world = EvidenceWorld()
        let source = UUID()
        var cache = ObservationCache()
        for (offset, value) in [(0.0, 5.0), (3_600.0, 6.0), (7_200.0, 8.0)] {
            let at = fixedNow.addingTimeInterval(offset)
            cache.apply([.metrics(source: source, .success([sample(world, source: source, key: "leads", value: value, at: at)]))],
                        portfolio: world.portfolio, now: at)
        }
        #expect(cache.metrics.count == 1)
        // Three refreshes inside one or two calendar days never make three points.
        #expect(cache.points.count <= 2)
        #expect(cache.points.last?.value == 8)
    }

    @Test func theFirstLeadSyncIsQuietAndLaterEventsReachTheFeed() {
        let world = EvidenceWorld()
        let source = UUID()
        var cache = ObservationCache()
        let history = (0..<5).map { lead("\(source.uuidString):h\($0)", at: fixedNow.addingTimeInterval(Double(-$0) * 3_600), product: world.product.id, source: source) }
        cache.apply([.leads(source: source, product: world.product.id, .success(history))], portfolio: world.portfolio, now: fixedNow)
        #expect(cache.leads.count == 5)
        #expect(cache.activity.isEmpty)

        let later = fixedNow.addingTimeInterval(600)
        var purchase = lead("\(source.uuidString):p1", at: later, kind: .paidConversion, product: world.product.id, source: source)
        purchase.valueCents = 4_900
        purchase.sourceLabel = "Stripe"
        let incoming = history + [lead("\(source.uuidString):n1", at: later, product: world.product.id, source: source), purchase]
        cache.apply([.leads(source: source, product: world.product.id, .success(incoming))], portfolio: world.portfolio, now: later)
        #expect(cache.leads.count == 7)
        #expect(cache.activity.count == 2)
        #expect(Set(cache.activity.map(\.kind)) == [.lead, .purchase])
        #expect(cache.activity.first { $0.kind == .purchase }?.detail == "Stripe · $49")

        // The same page again is neither counted nor announced twice.
        cache.apply([.leads(source: source, product: world.product.id, .success(incoming))], portfolio: world.portfolio, now: later.addingTimeInterval(60))
        #expect(cache.leads.count == 7)
        #expect(cache.activity.count == 2)
        // A failed sync keeps the leads.
        cache.apply([.leads(source: source, product: world.product.id, .failure(.timeout, "slow"))], portfolio: world.portfolio, now: later.addingTimeInterval(120))
        #expect(cache.leads.count == 7)
        #expect(cache.sync["leads:\(source.uuidString)"]?.lastProblem == .timeout)
    }

    @Test func moneyFormatting() {
        #expect(Money.format(cents: 4_900) == "$49")
        #expect(Money.format(cents: 4_950) == "$49.50")
        #expect(Money.format(cents: 184_200_00) == "$184,200")
        #expect(Money.format(cents: 0) == "$0")
    }
}

@Suite struct MetricMathTests {
    @Test func countUsesAWindowEndingNow() {
        let product = UUID()
        let events = [lead("a", at: fixedNow.addingTimeInterval(-3_600), product: product),
                      lead("b", at: fixedNow.addingTimeInterval(-25 * 3_600), product: product),
                      lead("c", at: fixedNow.addingTimeInterval(-6 * 86_400), product: product),
                      lead("future", at: fixedNow.addingTimeInterval(3_600), product: product),
                      lead("edge", at: fixedNow.addingTimeInterval(-86_400), product: product),
                      lead("now", at: fixedNow, product: product)]
        #expect(MetricMath.count(events, kinds: [.lead], within: 86_400, now: fixedNow) == 2)
        #expect(MetricMath.count(events, kinds: [.lead], within: 7 * 86_400, now: fixedNow) == 5)
        #expect(MetricMath.count(events, kinds: [.lead], within: 3_600, now: fixedNow) == 1)
        #expect(MetricMath.count(events, kinds: [.signup], within: 7 * 86_400, now: fixedNow) == 0)
        #expect(MetricMath.count([], kinds: [.lead], within: 86_400, now: fixedNow) == 0)
    }

    @Test func countFiltersByKindAndProductAndDedupesByID() {
        let mine = UUID(), theirs = UUID()
        let at = fixedNow.addingTimeInterval(-60)
        let events = [lead("a", at: at, product: mine), lead("a", at: at, product: mine), lead("a", at: at, product: mine),
                      lead("b", at: at, kind: .signup, product: mine), lead("c", at: at, product: theirs),
                      lead("d", at: at, kind: .paidConversion, product: mine)]
        #expect(MetricMath.count(events, kinds: [.lead], productID: mine, within: 86_400, now: fixedNow) == 1)
        #expect(MetricMath.count(events, kinds: [.lead, .signup], productID: mine, within: 86_400, now: fixedNow) == 2)
        #expect(MetricMath.count(events, kinds: [.lead], within: 86_400, now: fixedNow) == 2)
        #expect(MetricMath.count(events, kinds: Set(BusinessEventKind.allCases), within: 86_400, now: fixedNow) == 4)
    }

    @Test func changeIsNilWithoutPreviousData() {
        #expect(MetricMath.change(current: 10, previous: nil) == nil)
        #expect(MetricMath.change(current: 10, previous: 0) == nil)
        #expect(MetricMath.change(current: 0, previous: nil) == nil)
        #expect(MetricMath.change(current: 15, previous: 10) == 0.5)
        #expect(MetricMath.change(current: 5, previous: 10) == -0.5)
        #expect(MetricMath.change(current: 0, previous: 10) == -1)
    }

    private func calendar(offsetHours: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetHours * 3_600)!
        return calendar
    }

    @Test func dailyCountsAreNilBeforeTheFirstEventAndZeroAfter() {
        let utc = calendar(offsetHours: 0)
        let now = date("2026-03-11T20:00:00Z")
        let events = [lead("a", at: date("2026-03-08T09:00:00Z")), lead("b", at: date("2026-03-08T18:00:00Z")),
                      lead("c", at: date("2026-03-10T01:00:00Z"))]
        let counts = MetricMath.dailyCounts(events, kinds: [.lead], days: 6, now: now, calendar: utc)
        // Mar 6, 7: before anything was known. Mar 9 and 11: known, and empty.
        #expect(counts == [nil, nil, 2, 0, 1, 0])
        #expect(MetricMath.dailyCounts([], kinds: [.lead], days: 3, now: now, calendar: utc) == [nil, nil, nil])
        #expect(MetricMath.dailyCounts(events, kinds: [.signup], days: 3, now: now, calendar: utc) == [nil, nil, nil])
        #expect(MetricMath.dailyCounts(events, kinds: [.lead], days: 0, now: now, calendar: utc).isEmpty)
    }

    @Test func dailyCountsUseTheCalendarsTimeZone() {
        // 23:30 on March 10 in UTC-8 is 07:30 on March 11 in UTC.
        let event = lead("late-evening", at: date("2026-03-11T07:30:00Z"))
        let now = date("2026-03-11T20:00:00Z")       // noon on March 11 in UTC-8
        #expect(MetricMath.dailyCounts([event], kinds: [.lead], days: 3, now: now, calendar: calendar(offsetHours: -8)) == [nil, 1, 0])
        #expect(MetricMath.dailyCounts([event], kinds: [.lead], days: 3, now: now, calendar: calendar(offsetHours: 0)) == [nil, nil, 1])
        // Far east of UTC the same instant is already the evening of March 11, and "now" is March 12.
        #expect(MetricMath.dailyCounts([event], kinds: [.lead], days: 3, now: now, calendar: calendar(offsetHours: 12)) == [nil, 1, 0])
    }

    @Test func aLateArrivalLandsOnItsOwnDay() {
        let utc = calendar(offsetHours: 0)
        let now = date("2026-03-11T20:00:00Z")
        var cache = ObservationCache()
        cache.merge(leads: [lead("today", at: date("2026-03-11T10:00:00Z"))])
        #expect(MetricMath.dailyCounts(cache.leads, kinds: [.lead], days: 3, now: now, calendar: utc) == [nil, nil, 1])

        // Delivered now, but it happened two days ago.
        var late = lead("late", at: date("2026-03-09T15:00:00Z"))
        late.receivedAt = now
        let fresh = cache.merge(leads: [late, lead("today", at: date("2026-03-11T10:00:00Z"))])
        #expect(fresh.map(\.id) == ["late"])
        #expect(MetricMath.dailyCounts(cache.leads, kinds: [.lead], days: 3, now: now, calendar: utc) == [1, 0, 1])
        #expect(MetricMath.count(cache.leads, kinds: [.lead], within: 86_400, now: now) == 1)
        #expect(cache.leads.map(\.id) == ["today", "late"])
    }

    @Test func dailyCountsDedupeByID() {
        let utc = calendar(offsetHours: 0)
        let at = date("2026-03-11T10:00:00Z")
        let counts = MetricMath.dailyCounts([lead("x", at: at), lead("x", at: at), lead("y", at: at)], kinds: [.lead], days: 1,
                                            now: date("2026-03-11T20:00:00Z"), calendar: utc)
        #expect(counts == [2])
    }

    @Test func leadMergeIsBoundedAndNewestFirst() {
        var cache = ObservationCache()
        let events = (0..<(ObservationCache.maxLeads + 50)).map { lead("e\($0)", at: fixedNow.addingTimeInterval(Double($0))) }
        cache.merge(leads: events)
        #expect(cache.leads.count == ObservationCache.maxLeads)
        #expect(cache.leads.first?.id == "e\(ObservationCache.maxLeads + 49)")
    }
}
