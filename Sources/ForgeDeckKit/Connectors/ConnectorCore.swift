import Foundation

// The connector contract. A connector declares what it can do, returns one of a small
// set of typed outcomes, and never throws for an ordinary provider failure.
// Views never call a connector: the app's refresh layer does, and stores the result
// in the observation cache with its provenance.

public enum ConnectorResult<Value: Sendable>: Sendable {
    case success(Value)
    /// Usable, but some parts could not be read. `missing` names them.
    case partial(Value, missing: [String])
    case failure(ObservationProblem, detail: String, retryAfter: TimeInterval?)

    public var value: Value? {
        switch self {
        case .success(let value), .partial(let value, _): value
        case .failure: nil
        }
    }

    public var problem: ObservationProblem? {
        if case .failure(let problem, _, _) = self { problem } else { nil }
    }

    public var detail: String {
        switch self {
        case .success: ""
        case .partial(_, let missing): "Not available: \(missing.joined(separator: ", "))"
        case .failure(_, let detail, _): detail
        }
    }

    public static func failure(_ problem: ObservationProblem, _ detail: String = "") -> ConnectorResult {
        .failure(problem, detail: detail, retryAfter: nil)
    }
}

public enum ConnectorCapability: String, Sendable, CaseIterable {
    case repositories, branches, pullRequests, issues, workflowRuns, releases, reportedDeployments
    case runtimeStatus, health, metrics, leadEvents, logs, containerStatus, hostStatus
}

public protocol Connector: Sendable {
    static var provider: ProviderKind { get }
    static var capabilities: [ConnectorCapability] { get }
}

// The capability protocols. A new provider implements the ones it supports;
// no view changes, because views read the cache.
public protocol RepositoryProvider: Connector {
    func snapshot(owner: String, name: String, environments: [String]) async -> ConnectorResult<RemoteSnapshot>
}

public protocol RuntimeProbe: Connector {
    func status(_ probe: ProbeConfig, bearer: String?, expectedTier: EnvironmentTier) async -> ProbeOutcome
}

public protocol MetricProvider: Connector {
    func metrics(_ source: MetricSource, productID: UUID, window: String, bearer: String?) async -> ConnectorResult<[MetricSample]>
    func events(_ source: MetricSource, productID: UUID, bearer: String?, maxPages: Int) async -> ConnectorResult<[LeadEvent]>
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names in lowercase.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public enum URLPolicy {
    public enum Violation: Error, CustomStringConvertible, Equatable {
        case invalid, scheme, insecure, embeddedCredentials

        public var description: String {
            switch self {
            case .invalid: "That is not a valid URL."
            case .scheme: "Only http and https URLs are supported."
            case .insecure: "HTTPS is required for every host except localhost."
            case .embeddedCredentials: "Do not put credentials in the URL. Use a secret variable instead."
            }
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost") { return true }
        // 127.x.y.z as a literal address only. "127.evil.example" is a public host name.
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    /// Accepts https anywhere and http on loopback only.
    public static func validate(_ text: String) throws -> URL {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let host = components.host, !host.isEmpty, let url = components.url else { throw Violation.invalid }
        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else { throw Violation.scheme }
        guard components.user == nil, components.password == nil else { throw Violation.embeddedCredentials }
        if scheme == "http", !isLoopback(host) { throw Violation.insecure }
        return url
    }
}

/// URLSession with no cookies, no cache, a short timeout, and redirects limited to the same host over https.
public final class URLSessionHTTPClient: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    public init(timeout: TimeInterval = 15) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    /// A redirect may only stay on the same host and may not drop from https to http.
    /// The Authorization header would otherwise travel to a host the user never configured.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url,
              from.host?.lowercased() == to.host?.lowercased(),
              !(from.scheme == "https" && to.scheme != "https") else { return nil }
        return request
    }
}

public enum HTTPFailure {
    /// Maps a transport error to a problem the UI can explain.
    public static func problem(for error: Error) -> (ObservationProblem, String) {
        if error is CancellationError { return (.cancelled, "Cancelled") }
        guard let urlError = error as? URLError else { return (.unavailable, error.localizedDescription) }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return (.offline, "This Mac is offline.")
        case .timedOut:
            return (.timeout, "The server did not answer in time.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
            return (.tlsFailure, "The TLS certificate could not be verified: \(urlError.localizedDescription)")
        case .cancelled:
            return (.cancelled, "Cancelled")
        case .cannotFindHost, .dnsLookupFailed:
            return (.unavailable, "The host name could not be resolved.")
        default:
            return (.unavailable, urlError.localizedDescription)
        }
    }

    /// Maps an HTTP status to a problem. nil for 2xx.
    public static func problem(status: Int, headers: [String: String]) -> (ObservationProblem, String, TimeInterval?)? {
        switch status {
        case 200..<300: return nil
        case 401: return (.unauthorized, "The credential was rejected (401).", nil)
        case 403:
            if headers["x-ratelimit-remaining"] == "0" || headers["retry-after"] != nil {
                return (.rateLimited, "The rate limit is used up.", retryAfter(headers))
            }
            return (.forbidden, "The credential lacks permission (403).", nil)
        case 404: return (.notFound, "Not found (404).", nil)
        case 429: return (.rateLimited, "Too many requests (429).", retryAfter(headers))
        case 500..<600: return (.unavailable, "The server failed (\(status)).", nil)
        default: return (.unavailable, "Unexpected status \(status).", nil)
        }
    }

    static func retryAfter(_ headers: [String: String]) -> TimeInterval? {
        if let text = headers["retry-after"], let seconds = TimeInterval(text) { return seconds }
        if let text = headers["x-ratelimit-reset"], let epoch = TimeInterval(text) {
            return max(0, epoch - Date.now.timeIntervalSince1970)
        }
        return nil
    }
}

/// Accepts the timestamp forms servers actually send.
public enum FlexibleDate {
    public static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// Scripted responses for tests and for the demo. Keyed by URL path (and query when given).
public final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    public enum Reply: Sendable {
        case response(HTTPResponse)
        case error(URLError.Code)
    }

    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]
    private var log: [URLRequest] = []

    public init() {}

    /// Queues a reply for a path. The last queued reply repeats.
    public func on(_ path: String, _ reply: Reply) {
        lock.withLock { replies[path, default: []].append(reply) }
    }

    public func on(_ path: String, status: Int = 200, json: String, headers: [String: String] = [:]) {
        on(path, .response(HTTPResponse(status: status, headers: headers, body: Data(json.utf8))))
    }

    public var requests: [URLRequest] { lock.withLock { log } }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let reply: Reply? = lock.withLock {
            log.append(request)
            let path = request.url?.path ?? ""
            let full = path + (request.url?.query.map { "?\($0)" } ?? "")
            for key in [full, path] {
                guard var queue = replies[key], !queue.isEmpty else { continue }
                let next = queue.count > 1 ? queue.removeFirst() : queue[0]
                replies[key] = queue
                return next
            }
            return nil
        }
        switch reply {
        case .response(let response): return response
        case .error(let code): throw URLError(code)
        case nil: return HTTPResponse(status: 404, body: Data("{}".utf8))
        }
    }
}
