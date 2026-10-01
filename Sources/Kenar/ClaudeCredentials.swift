import Foundation
import Security
import LocalAuthentication

/// Read-only access to Claude Code's store. The interactive read is only used
/// after a user presses Retry; automatic polling never opens a Keychain dialog.
final class ClaudeCredentialStore {
    enum Failure: Error, Equatable {
        case notFound, expired, invalidData, accessRequired, accessDenied
        case keychainError(OSStatus)

        var message: String {
            switch self {
            case .notFound: return L("Claude Code login not found — run /login in Claude Code. Opening Claude Desktop alone does not connect Kenar.")
            case .expired: return L("Claude Code access token expired — run /usage in Claude Code, then retry the connection.")
            case .invalidData: return L("Claude Code login could not be read — check /status in Claude Code.")
            case .accessRequired: return L("Keychain access is required — unlock your Mac, then retry and allow Kenar to read the Claude Code login.")
            case .accessDenied: return L("macOS blocked access to the Claude Code login — retry and approve the Keychain request for Kenar.")
            case .keychainError(let status): return L("Claude Code Keychain error (%d) — retry the connection.", status)
            }
        }

        static func keychainStatus(_ status: OSStatus) -> Failure {
            switch status {
            case errSecItemNotFound: return .notFound
            case errSecInteractionNotAllowed, errSecNotAvailable: return .accessRequired
            case errSecAuthFailed, errSecUserCanceled, 100001: return .accessDenied
            default: return .keychainError(status)
            }
        }
    }

    struct KeychainRead {
        var data: Data?
        var status: OSStatus
    }

    static let shared = ClaudeCredentialStore(
        sourceURL: AppPaths.config("CLAUDE_CONFIG_DIR", fallback: ".claude").appendingPathComponent(".credentials.json"),
        cacheURL: ClaudeProvider.ownStoreURL,
        readKeychain: readKeychain
    )

    private let lock = NSLock()
    private let sourceURL: URL
    private let cacheURL: URL
    private let readFile: (URL) -> Data?
    private let readKeychain: (Bool) -> KeychainRead
    private var memory: ClaudeProvider.Credentials?
    private var sourceNeedsRead = false

    init(sourceURL: URL, cacheURL: URL,
         readFile: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) },
         readKeychain: @escaping (Bool) -> KeychainRead) {
        self.sourceURL = sourceURL; self.cacheURL = cacheURL
        self.readFile = readFile; self.readKeychain = readKeychain
    }

    func load(forceSourceRead: Bool = false, allowInteraction: Bool = false,
              now: Date = Date()) -> Result<ClaudeProvider.Credentials, Failure> {
        lock.lock(); defer { lock.unlock() }
        func usable(_ creds: ClaudeProvider.Credentials) -> Bool {
            creds.expiresAt.map { $0.timeIntervalSince(now) >= 30 } ?? true
        }
        if !forceSourceRead && !sourceNeedsRead {
            if let memory, usable(memory) { return .success(memory) }
            if let data = readFile(cacheURL), let creds = ClaudeProvider.parseCredentialsJSON(data), usable(creds) {
                memory = creds; return .success(creds)
            }
        }
        memory = nil
        sourceNeedsRead = true
        var failure: Failure = .notFound
        if let data = readFile(sourceURL) {
            if let creds = ClaudeProvider.parseCredentialsJSON(data) {
                if usable(creds) { memory = creds; sourceNeedsRead = false; return .success(creds) }
                failure = .expired
            } else { failure = .invalidData }
        }
        let read = readKeychain(allowInteraction)
        if read.status == errSecSuccess {
            if let data = read.data, let creds = ClaudeProvider.parseCredentialsJSON(data) {
                if usable(creds) { memory = creds; sourceNeedsRead = false; return .success(creds) }
                failure = .expired
            } else { failure = .invalidData }
        } else if read.status != errSecItemNotFound {
            failure = Failure.keychainStatus(read.status)
        }
        // Never negatively cache a read: a new login or newly granted access is
        // picked up on the very next attempt, including within the same minute.
        return .failure(failure)
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }; memory = nil; sourceNeedsRead = true
    }

    private static func readKeychain(allowInteraction: Bool) -> KeychainRead {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return KeychainRead(data: status == errSecSuccess ? item as? Data : nil, status: status)
    }
}
