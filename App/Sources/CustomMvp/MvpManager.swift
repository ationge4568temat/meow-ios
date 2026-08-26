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
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled {
                withAnimation {
                    self.toastMessage = nil
                }
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
            let fetch = FetchDescriptor<Profile>(predicate: #Predicate { $0.name == "Block Ad" })
            let profile: Profile
            if let existing = try? context.fetch(fetch).first {
                try appModel.subscriptionService.updateInfo(existing, name: "Block Ad", url: trimmed)
                try await appModel.subscriptionService.refresh(existing)
                try appModel.subscriptionService.select(existing)
                profile = existing
            } else {
                let created = try await appModel.subscriptionService.add(name: "Block Ad", url: trimmed)
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

        Self.log.info("Starting refreshRuleProviders via REST API on port \(creds.port)")

        let session = URLSession.shared
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
        }

        if let (data, resp) = try? await session.data(for: getReq),
           let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(RuleProvidersResponse.self, from: data),
           let providers = decoded.providers
        {
            providerNames = Array(providers.keys)
            Self.log.info("Successfully fetched \(providerNames.count) rule providers from API.")
        } else {
            Self.log.warning("Failed to fetch rule providers from API, falling back to YAML extraction.")
        }

        if providerNames.isEmpty, let yaml = activeProfile?.yamlContent {
            providerNames = extractRuleProviderNames(from: yaml)
            Self.log.info("Extracted \(providerNames.count) rule providers from YAML: \(providerNames)")
        }

        for name in providerNames {
            let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let putURL = baseURL.appending(path: "/providers/rules/\(escaped)")
            var putReq = URLRequest(url: putURL)
            putReq.httpMethod = "PUT"
            if !creds.secret.isEmpty {
                putReq.setValue("Bearer \(creds.secret)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (_, putResp) = try await session.data(for: putReq)
                if let httpResp = putResp as? HTTPURLResponse {
                    Self.log.info("PUT \(name) responded with status \(httpResp.statusCode)")
                }
            } catch {
                Self.log.error("PUT \(name) failed with error: \(error.localizedDescription)")
            }
        }

        Self.log.info("Sending IPC reload command to apply rule provider updates.")
        appModel.ipcBridge.send(.reload)
    }

    /// When VPN is not connected, remove cached rule provider files in AppGroup container
    /// so the engine is forced to pull fresh copies from remote on next start.
    func clearLocalRuleCache(activeProfile: Profile?) {
        guard let yaml = activeProfile?.yamlContent else { return }
        let providerNames = extractRuleProviderNames(from: yaml)
        guard !providerNames.isEmpty else { return }
        
        let container = AppGroup.containerURL
        let fileManager = FileManager.default

        Self.log.info("Starting clearLocalRuleCache for providers: \(providerNames)")

        let extensions = [".mrs", ".yaml", ".yml"]
        let subdirectories = ["", "rule-providers", "rules", "ruleset"]

        for name in providerNames {
            let escapedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            
            for subdir in subdirectories {
                let dirURL = subdir.isEmpty ? container : container.appending(path: subdir)
                for ext in extensions {
                    let fileURL = dirURL.appending(path: escapedName + ext)
                    if fileManager.fileExists(atPath: fileURL.path) {
                        do {
                            try fileManager.removeItem(at: fileURL)
                            Self.log.info("Deleted cached rule file: \(fileURL.lastPathComponent)")
                        } catch {
                            Self.log.error("Failed to delete cached rule file: \(fileURL.lastPathComponent), error: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        
        Self.log.info("Finished clearLocalRuleCache.")
    }

    private func extractRuleProviderNames(from yaml: String) -> [String] {
        var names: [String] = []
        var inRuleProviders = false
        yaml.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("rule-providers:") {
                inRuleProviders = true
            } else if inRuleProviders {
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty {
                    stop = true
                } else if line.hasPrefix("  ") && !line.hasPrefix("    ") && trimmed.hasSuffix(":") {
                    let name = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        names.append(name)
                    }
                }
            }
        }
        return names
    }
}

