import Foundation
import MeowIPC
import MeowModels
import NetworkExtension
import Observation
import SwiftData
import SwiftUI

public enum MvpToastType {
    case info
    case success
    case error
    case warning
}

/// MvpManager coordinates MVP-specific state, preference silents, and bridges
/// the simplified Block Ad UI with meow-ios core AppModel & VpnManager.
@MainActor
@Observable
final class MvpManager {
    static let shared = MvpManager()

    var isMvpMode: Bool = !ProcessInfo.processInfo.arguments.contains("-UITests")
    var showInputArea: Bool = false
    var isImporting: Bool = false
    var isUpdating: Bool = false
    var isShieldToggling: Bool = false

    var toastMessage: String?
    var toastType: MvpToastType = .info
    private var toastTask: Task<Void, Never>?

    private init() {
    }

    func showToast(_ message: String, type: MvpToastType = .info, duration: TimeInterval = 2.5) {
        toastTask?.cancel()
        toastMessage = message
        toastType = type
        toastTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                withAnimation {
                    self.toastMessage = nil
                }
            }
        }
    }

    func toggleShield(appModel: AppModel, activeProfile: Profile?) {
        guard !isShieldToggling, !isUpdating, !isImporting else {
            if isUpdating || isImporting {
                showToast("操作处理中，请稍候...", type: .warning, duration: 1.5)
            }
            return
        }

        guard let activeProfile, !activeProfile.id.uuidString.isEmpty else {
            showInputArea = true
            showToast("请先导入配置文件", type: .info)
            return
        }

        isShieldToggling = true
        let isConnected = appModel.vpnManager.stage == .connected

        Task {
            if isConnected {
                await appModel.vpnManager.disconnect()
            } else {
                do {
                    // Apply optimal MVP preferences right before connecting
                    let defaults = AppGroup.defaults
                    defaults.set(true, forKey: PreferenceKey.blockHTTP3)
                    
                    // Ensure active config is written before connecting
                    try appModel.subscriptionService.writeActiveConfig(activeProfile)
                    await appModel.vpnManager.connect()
                    
                    // Surface any core errors that occurred during connect
                    if let err = appModel.vpnManager.lastError {
                        showToast("连接失败: \\(err)", type: .error, duration: 4.0)
                    }
                } catch {
                    showToast("启动防追踪失败: \(error.localizedDescription)", type: .error)
                }
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
            self.isShieldToggling = false
        }
    }

    func importConfig(url: String, appModel: AppModel) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            showToast("请输入有效的配置文件链接", type: .info)
            return
        }

        isImporting = true
        defer { isImporting = false }

        do {
            let profile = try await appModel.subscriptionService.add(name: "BlockAd MVP", url: trimmed)
            try appModel.subscriptionService.select(profile)
            showInputArea = false
            showToast("导入成功", type: .success)
        } catch {
            showToast("导入失败: \(error.localizedDescription)", type: .error)
        }
    }

    func updateSubscription(appModel: AppModel, activeProfile: Profile) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        do {
            try await appModel.subscriptionService.refresh(activeProfile)
            showToast("配置集已同步至最新", type: .success)
        } catch {
            showToast("更新失败: \(error.localizedDescription)", type: .error)
        }
    }
}
