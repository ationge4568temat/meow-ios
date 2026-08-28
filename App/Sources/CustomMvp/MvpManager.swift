import Foundation
import MeowIPC
import MeowModels
import NetworkExtension
import Observation
import SwiftData
import SwiftUI
import os

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
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meow-ios", category: "mvp-manager")
    private static let defaultProfileName = "Block Ad"

    var isMvpMode: Bool = !ProcessInfo.processInfo.arguments.contains("-UITests")
    var showInputArea: Bool = false
    var isImporting: Bool = false
    var isUpdating: Bool = false
    var isConnectionToggling: Bool = false

    var toastMessage: String?
    var toastType: MvpToastType = .info
    private var toastTask: Task<Void, Never>?

    private init() {
    }

    func showToast(_ message: String, type: MvpToastType = .info, duration: TimeInterval = 2.5) {
        Self.log.debug("showToast [\(String(describing: type))]: \(message, privacy: .public)")
        toastTask?.cancel()
        toastMessage = message
        toastType = type
        toastTask = Task {
            do {
                try await Task.sleep(for: .seconds(duration))
                withAnimation {
                    self.toastMessage = nil
                }
            } catch {
                // Cancelled, do nothing
            }
        }
    }

    func toggleConnection(appModel: AppModel, activeProfile: Profile?) {
        guard !isConnectionToggling, !isUpdating, !isImporting else {
            Self.log.info("toggleConnection ignored: busy state (isConnectionToggling: \(self.isConnectionToggling, privacy: .public), isUpdating: \(self.isUpdating, privacy: .public), isImporting: \(self.isImporting, privacy: .public))")
            if isUpdating || isImporting {
                showToast("操作处理中，请稍候...", type: .warning, duration: 1.5)
            }
            return
        }

        if appModel.vpnManager.stage == .stopping {
            Self.log.info("toggleConnection ignored: VPN is currently disconnecting.")
            showToast("正在断开服务，请稍候...", type: .info, duration: 1.5)
            return
        }

        guard let activeProfile, !activeProfile.id.uuidString.isEmpty else {
            Self.log.info("toggleConnection requested but no active profile configured.")
            showInputArea = true
            showToast("请先导入配置文件", type: .info)
            return
        }

        isConnectionToggling = true
        
        let isActiveState: Bool
        switch appModel.vpnManager.stage {
        case .connected, .connecting, .preparing:
            isActiveState = true
        default:
            isActiveState = false
        }

        Self.log.info("toggleConnection triggered (targetAction: \(isActiveState ? "disconnect" : "connect", privacy: .public), currentStage: \(String(describing: appModel.vpnManager.stage), privacy: .public))")

        Task {
            defer {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    self.isConnectionToggling = false
                }
            }

            if isActiveState {
                Self.log.info("Disconnecting VPN via vpnManager...")
                await appModel.vpnManager.disconnect()
            } else {
                do {
                    // Apply optimal MVP preferences right before connecting
                    let defaults = AppGroup.defaults
                    defaults.set(true, forKey: PreferenceKey.blockHTTP3)
                    
                    // Ensure active config is written before connecting
                    Self.log.info("Writing active config for profile: \(activeProfile.name, privacy: .public) and initiating connection...")
                    try appModel.subscriptionService.writeActiveConfig(activeProfile)
                    await appModel.vpnManager.connect()
                    
                    if let err = appModel.vpnManager.lastError {
                        Self.log.error("VPN connection failed with error: \(err, privacy: .public)")
                        showToast("连接失败: \(err)", type: .error, duration: 4.0)
                    } else {
                        Self.log.info("VPN connection initiated successfully.")
                    }
                } catch {
                    Self.log.error("Failed to start VPN: \(error.localizedDescription, privacy: .public)")
                    showToast("启动防追踪失败: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    func importConfig(url: String, appModel: AppModel, modelContext: ModelContext? = nil) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("https://") else {
            Self.log.warning("importConfig rejected: Invalid or non-HTTPS URL: \(url, privacy: .public)")
            showToast("请输入有效的 HTTPS 配置链接", type: .info)
            return
        }

        Self.log.info("importConfig starting for URL: \(trimmed, privacy: .public)")
        isImporting = true
        defer { isImporting = false }

        do {
            let context = modelContext ?? AppModelContainer.shared.container.mainContext
            let profileName = Self.defaultProfileName
            let fetch = FetchDescriptor<Profile>(predicate: #Predicate { $0.name == profileName })
            let profile: Profile
            if let existing = try? context.fetch(fetch).first {
                Self.log.info("Found existing default profile: \(existing.id.uuidString, privacy: .public). Updating info and refreshing...")
                try appModel.subscriptionService.updateInfo(existing, name: profileName, url: trimmed)
                try await appModel.subscriptionService.refresh(existing)
                try appModel.subscriptionService.select(existing)
                profile = existing
            } else {
                Self.log.info("Creating new default profile: \(profileName, privacy: .public)...")
                let created = try await appModel.subscriptionService.add(name: profileName, url: trimmed)
                try appModel.subscriptionService.select(created)
                profile = created
            }

            Self.log.info("importConfig successfully saved profile: \(profile.id.uuidString, privacy: .public)")

            if appModel.vpnManager.stage == .connected {
                Self.log.info("VPN is connected; refreshing rule providers via API...")
                await refreshRuleProviders(appModel: appModel, activeProfile: profile)
            } else {
                Self.log.info("VPN is not connected; clearing local rule cache...")
                clearLocalRuleCache(activeProfile: profile)
            }

            showInputArea = false
            showToast("导入成功", type: .success)
        } catch {
            Self.log.error("importConfig failed with error: \(error.localizedDescription, privacy: .public)")
            showToast("导入失败: \(error.localizedDescription)", type: .error)
        }
    }

    func updateSubscription(appModel: AppModel, activeProfile: Profile) async {
        guard !isUpdating else {
            Self.log.info("updateSubscription skipped: already updating")
            return
        }
        Self.log.info("updateSubscription starting for profile: \(activeProfile.name, privacy: .public)")
        isUpdating = true
        defer { isUpdating = false }

        do {
            try await appModel.subscriptionService.refresh(activeProfile)

            if appModel.vpnManager.stage == .connected {
                Self.log.info("VPN is connected; refreshing rule providers via API...")
                await refreshRuleProviders(appModel: appModel, activeProfile: activeProfile)
            } else {
                Self.log.info("VPN is not connected; clearing local rule cache...")
                clearLocalRuleCache(activeProfile: activeProfile)
            }

            Self.log.info("updateSubscription succeeded for profile: \(activeProfile.name, privacy: .public)")
            showToast("已同步至最新", type: .success)
        } catch {
            Self.log.error("updateSubscription failed with error: \(error.localizedDescription, privacy: .public)")
            showToast("更新失败: \(error.localizedDescription)", type: .error)
        }
    }

    // MARK: - Rule Provider Refresh & Cache Management

    /// When VPN is connected, trigger the embedded engine to force update all rule-providers via REST API.
    func refreshRuleProviders(appModel: AppModel, activeProfile: Profile?) async {
        guard let creds = AppGroup.apiCredentials(), creds.port > 0 else {
            Self.log.error("refreshRuleProviders failed: No API credentials available.")
            return
        }

        Self.log.info("Starting refreshRuleProviders via REST API on port \(creds.port, privacy: .public)")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: config)
        let baseURL = URL(string: "http://127.0.0.1:\(creds.port)")!

        var providerNames: [String] = []
        let getURL = baseURL.appending(path: "/providers/rules")
        Self.log.info("Requesting GET rule providers from: \(getURL.absoluteString, privacy: .public)")
        var getReq = URLRequest(url: getURL)
        if !creds.secret.isEmpty {
            getReq.setValue("Bearer \(creds.secret)", forHTTPHeaderField: "Authorization")
        }

        struct RuleProvidersResponse: Decodable {
            let providers: [String: ProviderStub]?
        }
        struct ProviderStub: Decodable {
            let name: String?
            let ruleCount: Int?
        }

        if let (data, resp) = try? await session.data(for: getReq),
           let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(RuleProvidersResponse.self, from: data),
           let providers = decoded.providers
        {
            providerNames = Array(providers.keys)
            
            let details = providers.values.compactMap { stub -> String? in
                guard let name = stub.name else { return nil }
                let countStr = stub.ruleCount.map { "\($0)" } ?? "?"
                return "\(name)(\(countStr))"
            }.joined(separator: ", ")
            
            Self.log.info("Successfully fetched \(providerNames.count, privacy: .public) rule providers from API: \(details, privacy: .public)")
        } else {
            Self.log.warning("Failed to fetch rule providers from API.")
        }

        let logger = Self.log
        await withTaskGroup(of: Void.self) { group in
            for name in providerNames {
                let secret = creds.secret
                group.addTask {
                    let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                    let putURL = baseURL.appending(path: "/providers/rules/\(escaped)")
                    logger.info("Requesting PUT rule provider update from: \(putURL.absoluteString, privacy: .public)")
                    var putReq = URLRequest(url: putURL)
                    putReq.httpMethod = "PUT"
                    if !secret.isEmpty {
                        putReq.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                    }
                    do {
                        let (_, putResp) = try await session.data(for: putReq)
                        if let httpResp = putResp as? HTTPURLResponse {
                            logger.info("PUT \(name, privacy: .public) responded with status \(httpResp.statusCode, privacy: .public)")
                        }
                    } catch {
                        logger.error("PUT \(name, privacy: .public) failed with error: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }

        Self.log.info("Sending IPC reload command to apply rule provider updates.")
        appModel.ipcBridge.send(.reload)
    }

    /// When VPN is not connected, remove cached rule provider files in AppGroup container
    /// so the engine is forced to pull fresh copies from remote on next start.
    func clearLocalRuleCache(activeProfile: Profile?) {
        let container = AppGroup.containerURL
        let fileManager = FileManager.default

        Self.log.info("Starting clearLocalRuleCache.")

        let dirURL = container.appending(path: "rule-providers")
        var deletedFiles: [String] = []
        
        if let urls = try? fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) {
            for fileURL in urls {
                do {
                    try fileManager.removeItem(at: fileURL)
                    deletedFiles.append(fileURL.lastPathComponent)
                } catch {
                    Self.log.error("Failed to delete cached item: \(fileURL.lastPathComponent, privacy: .public), error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        
        Self.log.info("Finished clearLocalRuleCache. Deleted files: \(deletedFiles, privacy: .public)")
    }

}
