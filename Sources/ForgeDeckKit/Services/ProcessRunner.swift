import Foundation

// Every subprocess goes through here: an executable URL, an argument array, and a
// working directory URL. Nothing is ever joined into a shell string.

public struct ProcessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL?
    /// nil inherits the parent's environment. A value replaces it entirely.
    public var environment: [String: String]?
    public var timeout: TimeInterval
    public var stdin: Data?
    /// Output past this many bytes is dropped and `truncated` is set.
    public var maxOutputBytes: Int

    public init(executable: URL, arguments: [String] = [], workingDirectory: URL? = nil,
                environment: [String: String]? = nil, timeout: TimeInterval = 30, stdin: Data? = nil,
                maxOutputBytes: Int = 1_000_000) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.stdin = stdin
        self.maxOutputBytes = maxOutputBytes
    }
}

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut = false
    public var truncated = false

    public init(exitCode: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false, truncated: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncated = truncated
    }

    public var ok: Bool { exitCode == 0 && !timedOut }
}

public enum ProcessError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .notFound(let name): "\(name) is not installed or not executable"
        case .launchFailed(let why): "could not start the process: \(why)"
        }
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: request.executable.path) else {
            throw ProcessError.notFound(request.executable.lastPathComponent)
        }
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory
        if let environment = request.environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input: Pipe? = request.stdin == nil ? nil : Pipe()
        process.standardInput = input ?? FileHandle.nullDevice

        let box = OutputBox(limit: request.maxOutputBytes)
        // Never `availableData` here: it raises an Objective-C exception (a crash) when the read fails, and the
        // termination handler switches the pipe to non-blocking while a callback may still be queued.
        out.fileHandleForReading.readabilityHandler = { handle in box.append(Self.readChunk(handle), stream: .out) }
        err.fileHandleForReading.readabilityHandler = { handle in box.append(Self.readChunk(handle), stream: .err) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + request.timeout)
                timer.setEventHandler {
                    box.markTimedOut()
                    if process.isRunning { process.terminate() }
                }
                process.terminationHandler = { finished in
                    timer.cancel()
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    // Whatever is still buffered in the pipes. Read without blocking: a background
                    // process the child started (an agent, a daemon) can hold the pipe open forever.
                    box.append(Self.drain(out.fileHandleForReading), stream: .out)
                    box.append(Self.drain(err.fileHandleForReading), stream: .err)
                    continuation.resume(returning: box.result(exitCode: finished.terminationStatus))
                }
                // Start the timer before launching: a dispatch source released without ever being resumed is a crash,
                // and the catch below cancels it when the launch fails (a working folder deleted meanwhile, say).
                timer.resume()
                do {
                    try process.run()
                    if let input, let data = request.stdin {
                        input.fileHandleForWriting.write(data)
                        try? input.fileHandleForWriting.close()
                    }
                } catch {
                    timer.cancel()
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    continuation.resume(throwing: ProcessError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

extension SystemProcessRunner {
    /// One read from a pipe that macOS says is readable. Errors and end of file return no data instead of throwing;
    /// at end of file the handler is removed so it stops firing.
    static func readChunk(_ handle: FileHandle) -> Data {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(handle.fileDescriptor, &buffer, buffer.count)
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 || (errno != EAGAIN && errno != EINTR) { handle.readabilityHandler = nil }
        return Data()
    }

    /// Reads what is already in a pipe and returns without waiting for it to close.
    static func drain(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return Data() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class OutputBox: @unchecked Sendable {
    enum Stream { case out, err }
    private let lock = NSLock()
    private let limit: Int
    private var out = Data()
    private var err = Data()
    private var truncated = false
    private var timedOut = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data, stream: Stream) {
        guard !data.isEmpty else { return }
        lock.withLock {
            let used = out.count + err.count
            let room = max(0, limit - used)
            if data.count > room { truncated = true }
            let slice = data.prefix(room)
            if stream == .out { out.append(slice) } else { err.append(slice) }
        }
    }

    func markTimedOut() { lock.withLock { timedOut = true } }

    func result(exitCode: Int32) -> ProcessResult {
        lock.withLock {
            ProcessResult(exitCode: exitCode, stdout: String(decoding: out, as: UTF8.self),
                          stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut, truncated: truncated)
        }
    }
}

/// Finds programs without a shell.
public enum ExecutableLocator {
    public static let searchPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]

    public static func find(_ name: String, extraPaths: [String] = [],
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = extraPaths + searchPaths + ["\(home)/.local/bin", "\(home)/bin"]
        paths += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        for dir in paths where seen.insert(dir).inserted {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}

/// POSIX single-quote quoting, for the two places a shell string cannot be avoided:
/// the `.command` launch script and the "Copy command" fallback.
public enum ShellQuote {
    public static func quote(_ text: String) -> String {
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ safe.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func join(_ words: [String]) -> String { words.map(quote).joined(separator: " ") }

    private static let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:@%+,")
}
