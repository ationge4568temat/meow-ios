import Foundation
import MeowModels
import os
import Security

/// 提供 MVP 相关的设备标识信息
public enum MvpDevice: Sendable {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meow-ios", category: "mvp-device")
    private static let hwidStorageKey = "MvpDeviceFallbackHWID_Key"
    private static let keychainAccount = "meow_device_hwid"
    private static let keychainService = "com.tangzixiang.meow.hwid"

    /// 内存缓存（避免频繁触发 securityd IPC 交互，保证高频访问性能）
    private static let cachedHWID = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// 获取设备唯一标识符 (HWID)
    ///
    /// 满足“零弹窗、高可靠、卸载重装不丢失”的设备持久化标识：
    /// - 使用 `kSecClassGenericPassword`：普通键值对存储，避免触发系统网页凭据提示。
    /// - 使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：
    ///   - 设备重启且用户首次解锁后，后台均可静默读取。
    ///   - 禁止随 iCloud 备份同步或换机迁移（Quick Start），保证物理设备绝对唯一。
    ///   - 卸载重装后 Keychain 条目依然持久保留，自动无缝恢复。
    /// - 兼容存量：若 Keychain 为空但检测到老版本 AppGroup.defaults 中的旧标识，自动迁移固化至 Keychain。
    public static var hwid: String {
        if let memoryValue = cachedHWID.withLock({ $0 }) {
            return memoryValue
        }

        return cachedHWID.withLock { current in
            if let existing = current {
                return existing
            }

            // 1. 尝试从 Keychain 读取（命中日常运行或卸载重装场景）
            if let keychainValue = readFromKeychain(), !keychainValue.isEmpty {
                log.debug("Obtained HWID from Keychain")
                // 若 defaults 丢失（如卸载重装后），补写回 defaults
                if AppGroup.defaults.string(forKey: hwidStorageKey) != keychainValue {
                    AppGroup.defaults.set(keychainValue, forKey: hwidStorageKey)
                    log.info("Restored HWID from Keychain to AppGroup defaults after reinstall")
                }
                current = keychainValue
                return keychainValue
            }

            // 2. Keychain 未命中，检查老版本存量 Defaults（老用户平滑升级场景）
            if let legacyID = AppGroup.defaults.string(forKey: hwidStorageKey), !legacyID.isEmpty {
                log.info("Migrating legacy HWID from AppGroup defaults to Keychain")
                saveToKeychain(legacyID)
                current = legacyID
                return legacyID
            }

            // 3. 全新用户首次安装冷启动场景
            let newUUID = UUID().uuidString
            log.info("Generated and stored new HWID into Keychain and AppGroup defaults")
            saveToKeychain(newUUID)
            AppGroup.defaults.set(newUUID, forKey: hwidStorageKey)
            current = newUUID
            return newUUID
        }
    }

    // MARK: - Keychain 底层交互

    private static func readFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else {
            if status != errSecSuccess && status != errSecItemNotFound {
                log.warning("SecItemCopyMatching failed with status: \(status, privacy: .public)")
            }
            return nil
        }

        return string
    }

    private static func saveToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: keychainAccount,
            ]
            let updateAttrs: [CFString: Any] = [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus != errSecSuccess {
                log.error("SecItemUpdate failed with status: \(updateStatus, privacy: .public)")
            }
        } else if status != errSecSuccess {
            log.error("SecItemAdd failed with status: \(status, privacy: .public)")
        }
    }

    #if DEBUG
    @discardableResult
    internal static func deleteFromKeychainForTesting() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    internal static func clearMemoryCacheForTesting() {
        cachedHWID.withLock { $0 = nil }
    }

    internal static func resetForTesting() {
        clearMemoryCacheForTesting()
        AppGroup.defaults.removeObject(forKey: hwidStorageKey)
        deleteFromKeychainForTesting()
    }
    #endif
}
