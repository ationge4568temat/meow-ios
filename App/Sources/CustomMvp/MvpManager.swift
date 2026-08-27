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

        isConnectionToggling = true
        
        let isActiveState: Bool
        switch appModel.vpnManager.stage {
        case .connected, .connecting, .preparing:
            isActiveState = true
        default:
            isActiveState = false
        }

        Task {
            if isActiveState {
                await appModel.vpnManager.disconnect()
            } else {
                do {
                    // Apply optimal MVP preferences right before connecting
                    let defaults = AppGroup.defaults
                    defaults.set(true, forKey: PreferenceKey.blockHTTP3)
                    
                    // Ensure active config is written before connecting
                    try appModel.subscriptionService.writeActiveConfig(activeProfile)
                    await appModel.vpnManager.connect()
                    
                    if let err = appModel.vpnManager.lastError {
                        showToast("连接失败: \(err)", type: .error, duration: 4.0)
                    }
                } catch {
                    showToast("启动防追踪失败: \(error.localizedDescription)", type: .error)
                }
            }

            try? await Task.sleep(for: .milliseconds(500))
            self.isConnectionToggling = false
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
            let context = AppModelContainer.shared.container.mainContext
            let profileName = Self.defaultProfileName
            let fetch = FetchDescriptor<Profile>(predicate: #Predicate { $0.name == profileName })
            let profile: Profile
            if let existing = try? context.fetch(fetch).first {
                try appModel.subscriptionService.updateInfo(existing, name: profileName, url: trimmed)
                try await appModel.subscriptionService.refresh(existing)
                try appModel.subscriptionService.select(existing)
                profile = existing
            } else {
                let created = try await appModel.subscriptionService.add(name: profileName, url: trimmed)
                try appModel.subscriptionService.select(created)
                profile = created
            }

            if appModel.vpnManager.stage == .connected {
                await refreshRuleProviders(appModel: appModel, activeProfile: profile)
            } else {
                clearLocalRuleCache(activeProfile: profile)
            }

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

            if appModel.vpnManager.stage == .connected {
                await refreshRuleProviders(appModel: appModel, activeProfile: activeProfile)
            } else {
                clearLocalRuleCache(activeProfile: activeProfile)
            }

            showToast("已同步至最新", type: .success)
        } catch {
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
        var getReq = URLRequest(url: baseURL.appending(path: "/providers/rules"))
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

        printDirectoryStructure()
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

    private func printDirectoryStructure() {
        let container = AppGroup.containerURL
        let fileManager = FileManager.default
        Self.log.info("--- AppGroup Directory Structure ---")
        Self.log.info("Base Path: \(container.path, privacy: .public)")
        
        if let enumerator = fileManager.enumerator(at: container, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let fileURL as URL in enumerator {
                let relativePath = fileURL.path.replacingOccurrences(of: container.path + "/", with: "")
                Self.log.info("- \(relativePath, privacy: .public)")
            }
        }
        Self.log.info("------------------------------------")
    }
}
