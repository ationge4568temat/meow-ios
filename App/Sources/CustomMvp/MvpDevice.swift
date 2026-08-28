import UIKit
import os

/// 提供 MVP 相关的设备标识信息
public enum MvpDevice {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meow-ios", category: "mvp-device")
    private static let hwidStorageKey = "MvpDeviceFallbackHWID_Key"

    /// 获取设备唯一标识符 (HWID)
    ///
    /// `identifierForVendor` 是一种安全的标识符：
    /// - 无需申请权限弹窗
    /// - 无需配置 Keychain 或特殊 Entitlements
    /// - 同一个开发商的 App 共享相同的标识符
    /// - 仅在卸载设备上所有该开发商的 App 时才会重置，足够满足长效标识需求。
    public static var hwid: String {
        if let id = UIDevice.current.identifierForVendor?.uuidString {
            log.debug("Obtained HWID from identifierForVendor")
            return id
        }
        
        if let stored = UserDefaults.standard.string(forKey: hwidStorageKey) {
            log.debug("Obtained HWID from UserDefaults fallback")
            return stored
        }
        
        let newUUID = UUID().uuidString
        UserDefaults.standard.set(newUUID, forKey: hwidStorageKey)
        log.info("Generated and stored new fallback HWID")
        return newUUID
    }
}
