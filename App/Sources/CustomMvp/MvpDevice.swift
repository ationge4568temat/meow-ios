import UIKit

/// 提供 MVP 相关的设备标识信息
public enum MvpDevice {
    /// 获取设备唯一标识符 (HWID)
    ///
    /// `identifierForVendor` 是一种安全的标识符：
    /// - 无需申请权限弹窗
    /// - 无需配置 Keychain 或特殊 Entitlements
    /// - 同一个开发商的 App 共享相同的标识符
    /// - 仅在卸载设备上所有该开发商的 App 时才会重置，足够满足长效标识需求。
    public static var hwid: String {
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }
}
