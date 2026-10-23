import AppKit
import Security

@MainActor
enum SignIns {
    struct Outcome {
        var added = 0
        var kept = 0
        var sites = 0
        var error: String?
    }

    static func available(_ source: ImportSourceInfo) -> Bool {
        source.kind != .safari && source.error == nil
    }

    static func bring(from source: ImportSourceInfo, profileID: String, into profile: UInt64,
                      store: BrowserStore) async -> Outcome {
        guard available(source) else { return Outcome(error: "\(source.name)'s sign-ins can't be read.") }
        var password: Data?
        switch await browserKey(source) {
        case .success(let key): password = key
        case .failure(let error): return Outcome(error: error.message)
        }
        let core = store.core
        let sourceID = source.id
        let read = await Task.detached { core.readBrowserCookies(sourceId: sourceID, profileId: profileID, password: password) }.value
        if let error = read.error { return Outcome(error: error) }
        let cookies = read.cookies.map { c in
            let cookie = MBCookie()
            cookie.domain = c.domain
            cookie.name = c.name
            cookie.value = c.value
            cookie.path = c.path
            cookie.secure = c.secure
            cookie.httpOnly = c.httpOnly
            cookie.expires = c.expires
            cookie.created = c.created
            cookie.lastUsed = c.lastUsed
            cookie.sameSite = c.sameSite
            cookie.priority = c.priority
            return cookie
        }
        let sites = Set(read.cookies.map { $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain }).count
        let path = core.profileDir(profileId: profile)
        return await withCheckedContinuation { continuation in
            MBEngine.importCookies(cookies, intoProfilePath: path) { added, kept, _ in
                continuation.resume(returning: Outcome(added: added, kept: kept, sites: sites))
            }
        }
    }

    static func describe(_ outcome: Outcome, from browser: String, named: Bool = false) -> String {
        if let error = outcome.error { return "Couldn't bring \(browser)'s sign-ins: \(error)" }
        if outcome.sites == 0 { return "\(browser) wasn't signed in to any sites." }
        let sites = "\(outcome.sites.formatted()) site\(outcome.sites == 1 ? "" : "s")"
        let text = outcome.added == 0 ? "already signed in to \(sites)." : "signed in to \(sites)."
        return named ? "\(browser): \(text)" : text.prefix(1).uppercased() + text.dropFirst()
    }

    static func likelyProfile(for profile: ImportProfileInfo, of source: ImportSourceInfo,
                              among profiles: [ProfileInfo]) -> ProfileInfo? {
        profiles.first { $0.name == profile.name } ?? profiles.first { $0.name == "\(profile.name) (\(source.name))" }
    }

    static func title(_ profile: ImportProfileInfo, of source: ImportSourceInfo) -> String {
        profile.name.hasPrefix(source.name) ? profile.name : "\(source.name) · \(profile.name)"
    }

    struct KeychainError: Error {
        let message: String
    }

    private static var browserKeys: [String: Data] = [:]

    static func browserKey(_ source: ImportSourceInfo) async -> Result<Data?, KeychainError> {
        guard let service = source.keychainService else { return .success(nil) }
        if let key = browserKeys[service] { return .success(key) }
        let name = source.name
        let result = await Task.detached(operation: { keychainPassword(service: service, browser: name) }).value
        guard case .success(let key) = result else { return result.map(\.self) }
        browserKeys[service] = key
        Task {
            try? await Task.sleep(for: .seconds(120))
            browserKeys[service] = nil
        }
        return .success(key)
    }

    nonisolated static func keychainPassword(service: String, browser: String) -> Result<Data, KeychainError> {
        if let debug = ProcessInfo.processInfo.environment["MBGA_DEBUG_KEYCHAIN_PASSWORD"] {
            return .success(Data(debug.utf8))
        }
        let services = [service] + similarServices(to: service, browser: browser)
        var status = errSecItemNotFound
        for name in services {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: name,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data { return .success(data) }
            if status != errSecItemNotFound { break }
        }
        switch status {
        case errSecItemNotFound:
            return .failure(KeychainError(message: "its key isn't in your keychain."))
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .failure(KeychainError(message: "MBGA wasn't allowed to read its key in your keychain."))
        default:
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return .failure(KeychainError(message: text))
        }
    }

    private nonisolated static func similarServices(to service: String, browser: String) -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        let word = browser.split(separator: " ").first.map(String.init) ?? browser
        return items.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0 != service && $0.localizedCaseInsensitiveContains(word) && $0.contains("Storage") }
    }
}
