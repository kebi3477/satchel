//
//  KeychainManager.swift
//  glance
//
//  Thin, password-agnostic wrapper around Keychain Services — save/read/delete/exists by account, plus a Touch-ID access control helper.
//

import Foundation
import Security
import LocalAuthentication

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case accessControlFailed(String)
    case authenticationFailed
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "키체인 항목을 찾을 수 없어요."
        case .unexpectedData:
            return "키체인 항목의 형식이 올바르지 않아요."
        case .accessControlFailed(let msg):
            return "키체인 접근 제어를 만들 수 없어요: \(msg)"
        case .authenticationFailed:
            return "인증이 취소되었거나 실패했어요."
        case .osStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "키체인 오류: \(message)"
        }
    }
}

enum KeychainManager {
    nonisolated static let service = "dev.kebi.glance"

    /// Attributes-only existence check — never prompts, even for access-controlled items.
    nonisolated static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status != errSecItemNotFound
    }

    /// Pass an `LAContext` to authorize a read on an access-controlled item — the OS presents the prompt during this call.
    nonisolated static func read(account: String, context: LAContext? = nil) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpectedData }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.authenticationFailed
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Stores an item, updating its data in place when it already exists. Updating
    /// avoids the delete/add gap that can race with a second submit and produce
    /// `errSecDuplicateItem`. Existing access-control attributes are preserved;
    /// this method's access-control argument applies when adding a new item.
    nonisolated static func save(account: String, data: Data, accessControl: SecAccessControl? = nil) throws {
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break // Add below.
        default:
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        if let accessControl {
            addQuery[kSecAttrAccessControl as String] = accessControl
        } else {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return }
        // Another save may have added the item after our update reported
        // not-found. Complete that competing replacement with an update instead
        // of surfacing an avoidable “item already exists” error.
        if status == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                itemQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else { throw KeychainError.osStatus(retryStatus) }
            return
        }
        throw KeychainError.osStatus(status)
    }

    nonisolated static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    /// `.userPresence` requires Touch ID or device password, with no separate no-hardware handling needed.
    nonisolated static func makeUserPresenceAccessControl() throws -> SecAccessControl {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            let msg = (accessError?.takeRetainedValue() as Error?)?.localizedDescription ?? "알 수 없는 오류"
            throw KeychainError.accessControlFailed(msg)
        }
        return access
    }
}
