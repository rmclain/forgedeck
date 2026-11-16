import Foundation
import LocalAuthentication
import Security

// Secret bytes live in the macOS Keychain and nowhere else.
// Each credential is one generic-password item: service "com.forgedeck.vault",
// account = the CredentialReference locator. Items are readable only while the Mac
// is unlocked and never leave this device (no iCloud Keychain sync, no backup migration).

public enum SecretError: Error, CustomStringConvertible, Equatable {
    case notFound
    case denied
    case unavailable(String)
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .notFound: "The secret is not in the Keychain. Enter it again."
        case .denied: "Access to the secret was denied."
        case .unavailable(let why): why
        case .keychain(let status):
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }
}

public protocol SecretStore: Sendable {
    func read(_ locator: String) throws -> String
    func write(_ value: String, locator: String) throws
    func delete(_ locator: String) throws
    func exists(_ locator: String) -> Bool
}

public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = Brand.keychainService) { self.service = service }

    private func baseQuery(_ locator: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: locator]
    }

    public func read(_ locator: String) throws -> String {
        var query = baseQuery(locator)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw SecretError.notFound }
            return value
        case errSecItemNotFound: throw SecretError.notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: throw SecretError.denied
        default: throw SecretError.keychain(status)
        }
    }

    public func write(_ value: String, locator: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(locator) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretError.keychain(update) }
        var add = baseQuery(locator)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "\(Brand.name) credential"
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretError.keychain(status) }
    }

    public func delete(_ locator: String) throws {
        let status = SecItemDelete(baseQuery(locator) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretError.keychain(status) }
    }

    public func exists(_ locator: String) -> Bool {
        var query = baseQuery(locator)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Looking for the item must never raise a prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }

    public func read(_ locator: String) throws -> String {
        try lock.withLock {
            guard let value = values[locator] else { throw SecretError.notFound }
            return value
        }
    }

    public func write(_ value: String, locator: String) throws { lock.withLock { values[locator] = value } }
    public func delete(_ locator: String) throws { lock.withLock { values[locator] = nil } }
    public func exists(_ locator: String) -> Bool { lock.withLock { values[locator] != nil } }
}

/// Reads a credential from wherever its reference points.
public struct CredentialResolver: Sendable {
    public let keychain: any SecretStore
    public let runner: any ProcessRunning
    public let environment: [String: String]

    public init(keychain: any SecretStore = KeychainSecretStore(), runner: any ProcessRunning = SystemProcessRunner(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.keychain = keychain
        self.runner = runner
        self.environment = environment
    }

    public func value(for reference: CredentialReference) async throws -> String {
        switch reference.origin {
        case .keychain:
            return try keychain.read(reference.locator)
        case .environmentReference:
            guard let value = environment[reference.locator], !value.isEmpty else {
                throw SecretError.unavailable("The environment variable \(reference.locator) is not set.")
            }
            return value
        case .onePassword:
            guard let op = ExecutableLocator.find("op") else {
                throw SecretError.unavailable("The 1Password CLI (op) is not installed.")
            }
            guard reference.locator.hasPrefix("op://") else {
                throw SecretError.unavailable("A 1Password reference starts with op://")
            }
            let result = try await runner.run(ProcessRequest(executable: op, arguments: ["read", "--no-newline", reference.locator], timeout: 30))
            guard result.ok else { throw SecretError.unavailable("1Password did not return the secret. Is the CLI signed in?") }
            return result.stdout
        case .sshAgent:
            throw SecretError.unavailable("SSH keys stay with the SSH agent and are never read.")
        }
    }

    public func isAvailable(_ reference: CredentialReference) -> Bool {
        switch reference.origin {
        case .keychain: keychain.exists(reference.locator)
        case .environmentReference: !(environment[reference.locator] ?? "").isEmpty
        case .onePassword: ExecutableLocator.find("op") != nil
        case .sshAgent: true
        }
    }
}

// MARK: Local authentication

public protocol Authorizing: Sendable {
    /// Asks the person at the Mac to confirm with Touch ID or their password.
    func confirm(reason: String) async -> Bool
}

public struct DeviceOwnerAuthorizer: Authorizing {
    public init() {}

    public func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

public struct FixedAuthorizer: Authorizing {
    public let answer: Bool
    public init(_ answer: Bool) { self.answer = answer }
    public func confirm(reason: String) async -> Bool { answer }
}
