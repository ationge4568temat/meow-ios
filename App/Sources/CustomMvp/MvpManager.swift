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

/// 统一抽象的 MVP VPN 隧道状态（收敛连接中、断开中、准备中等过渡状态）
enum MvpTunnelStatus: Equatable, Sendable {
    case connected     // 隧道开启运行中
    case transitioning // 正在开启 / 正在关闭 / 切换中
    case disconnected  // 隧道已停用 / 未开启

    init(stage: VpnStage, isToggling: Bool = false) {
        if stage == .connected {
            self = .connected
        } else if isToggling || stage == .connecting || stage == .stopping || stage == .preparing {
            self = .transitioning
        } else {
            self = .disconnected
        }
    }

    var isSwitchOn: Bool {
        self != .disconnected
    }

    var statusTitle: String {
        switch self {
        case .connected: return "防护已开启"
        case .transitioning: return "防护启动中"
        case .disconnected: return "防护已暂停"
        }
    }

    var statusSubtitle: String {
        switch self {
        case .connected: return "防护运行中 · 智能拦截与防跟踪"
        case .transitioning: return "正在启动防护服务..."
        case .disconnected: return "点击上方按钮开启防护"
        }
    }

    var coreStatusText: String {
        switch self {
        case .connected: return "正常"
        case .transitioning: return "切换中"
        case .disconnected: return "停用"
        }
    }
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

    /// 是否有后台任务处理中（导入、同步、或切换连接中）
    var isBusy: Bool {
        isImporting || isUpdating || isConnectionToggling
    }

    /// 获取当前统一的隧道状态
    func tunnelStatus(for stage: VpnStage) -> MvpTunnelStatus {
        MvpTunnelStatus(stage: stage, isToggling: isConnectionToggling)
    }

    var ruleProvidersVersionSuffix: String = AppGroup.defaults.string(forKey: "ruleProvidersVersionSuffix") ?? ""

    func updateRuleProvidersSuffix(_ suffix: String) {
        ruleProvidersVersionSuffix = suffix
        AppGroup.defaults.set(suffix, forKey: "ruleProvidersVersionSuffix")
    }

    var toastMessage: String?
    var toastType: MvpToastType = .info
    private var toastTask: Task<Void, Never>?

    private let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private init() {}

    func showToast(_ message: String, type: MvpToastType = .info, duration: TimeInterval = 2.5) {
        Self.log.debug("showToast [\(String(describing: type))]: \(message, privacy: .public)")
        toastTask?.cancel()
        toastMessage = message
        toastType = type
        toastTask = Task {
            do {
                try await Task.sleep(for: .seconds(duration))
                withAnimation(.snappy) {
                    self.toastMessage = nil
                }
            } catch {
                // Cancelled, do nothing
            }
        }
    }

    func toggleConnection(appModel: AppModel, activeProfile: Profile?) {
        guard !isBusy else {
            Self.log.info("toggleConnection ignored: busy state")
            if isUpdating || isImporting {
                showToast("操作处理中，请稍候...", type: .warning, duration: 1.5)
            }
            return
        }

        let status = tunnelStatus(for: appModel.vpnManager.stage)
        if status == .transitioning {
            Self.log.info("toggleConnection ignored: VPN is in transitioning state.")
            showToast("服务状态切换中，请稍候...", type: .info, duration: 1.5)
            return
        }

        guard let activeProfile, !activeProfile.id.uuidString.isEmpty else {
            Self.log.info("toggleConnection requested but no active profile configured.")
            showInputArea = true
            showToast("请先导入配置文件", type: .info)
            return
        }

        isConnectionToggling = true
        let shouldDisconnect = (status == .connected)
        Self.log.info("toggleConnection triggered (action: \(shouldDisconnect ? "disconnect" : "connect", privacy: .public))")

        Task {
            defer {
                isConnectionToggling = false
            }

            if shouldDisconnect {
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

            // Provide a brief debounce delay before re-enabling toggle
            try? await Task.sleep(for: .milliseconds(300))
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
                try appModel.subscriptionService.updateInfo(
                    existing,
                    name: profileName,
                    url: trimmed,
                    updateInterval: .manual,
                )
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

            if tunnelStatus(for: appModel.vpnManager.stage) != .disconnected {
                Self.log.info("Tunnel is active or transitioning; disconnecting before clearing local rule cache...")
                await appModel.vpnManager.disconnect()
            }

            Self.log.info("Clearing local rule cache...")
            clearLocalRuleCache(activeProfile: profile)

            showInputArea = false
            showToast("导入成功", type: .success)
        } catch {
            Self.log.error("importConfig failed with error: \(error.localizedDescription, privacy: .public)")
            showToast("导入失败: \(error.localizedDescription)", type: .error)
        }
    }

    static let defaultAutoUpdateInterval: TimeInterval = 2 * 24 * 3600 // 2 days

    /// Checks if the active profile's lastUpdated date exceeds the auto-update interval (default 2 days),
    /// and triggers a silent subscription refresh if needed.
    func checkAutoUpdate(
        appModel: AppModel,
        activeProfile: Profile?,
        interval: TimeInterval = defaultAutoUpdateInterval
    ) async {
        guard let activeProfile else {
            Self.log.info("checkAutoUpdate skipped: activeProfile is nil")
            return
        }
        guard !isUpdating else {
            Self.log.info("checkAutoUpdate skipped: update already in progress")
            return
        }
        let trimmedURL = activeProfile.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            Self.log.info("checkAutoUpdate skipped: profile '\(activeProfile.name, privacy: .public)' has empty URL")
            return
        }

        let elapsed = Date.now.timeIntervalSince(activeProfile.lastUpdated)
        let elapsedHours = elapsed / 3600
        let thresholdHours = interval / 3600

        Self.log.info("checkAutoUpdate evaluated for profile '\(activeProfile.name, privacy: .public)': lastUpdated was \(elapsedHours, format: .fixed(precision: 1))h ago (threshold: \(thresholdHours, format: .fixed(precision: 1))h, date: \(activeProfile.lastUpdated.formatted(), privacy: .public))")

        guard elapsed >= interval else {
            Self.log.info("checkAutoUpdate: profile is up-to-date, skipping...")
            return
        }

        Self.log.info("checkAutoUpdate triggered: profile is outdated (\(elapsedHours / 24, format: .fixed(precision: 1)) days >= \(thresholdHours / 24, format: .fixed(precision: 1)) days), starting silent refresh...")
        await updateSubscription(appModel: appModel, activeProfile: activeProfile, silent: true)
    }

    func updateSubscription(appModel: AppModel, activeProfile: Profile, silent: Bool = false) async {
        guard !isUpdating else {
            Self.log.info("updateSubscription skipped: already updating")
            return
        }

        if tunnelStatus(for: appModel.vpnManager.stage) == .transitioning {
            Self.log.info("updateSubscription skipped: VPN is transitioning")
            if !silent {
                showToast("服务状态切换中，请稍候同步...", type: .warning, duration: 1.5)
            }
            return
        }

        Self.log.info("updateSubscription starting for profile: \(activeProfile.name, privacy: .public) (silent: \(silent, privacy: .public))")
        isUpdating = true
        defer { isUpdating = false }

        do {
            try await appModel.subscriptionService.refresh(activeProfile)

            switch tunnelStatus(for: appModel.vpnManager.stage) {
            case .connected:
                Self.log.info("VPN is connected; refreshing rule providers via API...")
                await refreshRuleProviders(appModel: appModel, activeProfile: activeProfile)
            case .disconnected:
                Self.log.info("VPN is safely disconnected; clearing local rule cache...")
                clearLocalRuleCache(activeProfile: activeProfile)
            case .transitioning:
                Self.log.warning("VPN is transitioning; skipping cache purge to avoid contention.")
                updateRuleProvidersSuffix("")
            }

            Self.log.info("updateSubscription succeeded for profile: \(activeProfile.name, privacy: .public)")
            if !silent {
                showToast("已同步至最新", type: .success)
            }
        } catch {
            Self.log.error("updateSubscription failed with error: \(error.localizedDescription, privacy: .public)")
            if !silent {
                showToast("更新失败: \(error.localizedDescription)", type: .error)
            }
        }
    }

    // MARK: - Rule Provider Refresh & Cache Management

    /// When VPN is connected, trigger the embedded engine to force update all rule-providers via REST API.
    func refreshRuleProviders(appModel: AppModel, activeProfile: Profile?) async {
        guard let creds = AppGroup.apiCredentials(), creds.port > 0 else {
            Self.log.error("refreshRuleProviders: No API credentials available; sending reload anyway.")
            appModel.ipcBridge.send(.reload)
            return
        }

        Self.log.info("Starting refreshRuleProviders via REST API on port \(creds.port, privacy: .public)")

        if let providers = await fetchRuleProviders(port: creds.port, secret: creds.secret) {
            let providerNames = Array(providers.keys)
            let details = providers.values.compactMap { stub -> String? in
                guard let name = stub.name else { return nil }
                let countStr = stub.ruleCount.map { "\($0)" } ?? "?"
                return "\(name)(\(countStr))"
            }.joined(separator: ", ")

            Self.log.info("Successfully fetched \(providerNames.count, privacy: .public) rule providers from API: \(details, privacy: .public)")

            let logger = Self.log
            let session = apiSession
            let secret = creds.secret
            let port = creds.port

            await withTaskGroup(of: Void.self) { group in
                for name in providerNames {
                    group.addTask {
                        await Self.updateSingleRuleProvider(name: name, port: port, secret: secret, session: session, logger: logger)
                    }
                }
            }
        } else {
            Self.log.warning("Failed to fetch rule providers before reload; proceeding to reload config.")
        }

        Self.log.info("Sending IPC reload command to apply rule provider updates.")
        appModel.ipcBridge.send(.reload)

        try? await Task.sleep(for: .seconds(1.0))
        await fetchRuleProviderCounts()
    }

    func fetchRuleProviderCounts() async {
        guard let creds = AppGroup.apiCredentials(), creds.port > 0 else { return }

        guard let providers = await fetchRuleProviders(port: creds.port, secret: creds.secret) else {
            Self.log.warning("fetchRuleProviderCounts failed to fetch from API.")
            return
        }

        let sortedNames = providers.keys.sorted()
        let counts = sortedNames.compactMap { name -> String? in
            guard let count = providers[name]?.ruleCount else { return nil }
            return "\(count)"
        }

        guard counts.count == sortedNames.count else {
            Self.log.warning("fetchRuleProviderCounts: incomplete rule counts from providers.")
            return
        }

        let suffix = counts.joined(separator: ".")
        let newSuffix = suffix.isEmpty ? "" : ".\(suffix)"
        Self.log.info("fetchRuleProviderCounts success: \(newSuffix, privacy: .public)")
        updateRuleProvidersSuffix(newSuffix)
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
        updateRuleProvidersSuffix("")
    }

    // MARK: - Private API Helpers

    private func fetchRuleProviders(port: Int, secret: String) async -> [String: ProviderStub]? {
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else { return nil }
        let getURL = baseURL.appending(path: "/providers/rules")
        var getReq = URLRequest(url: getURL)
        getReq.cachePolicy = .reloadIgnoringLocalCacheData
        getReq.timeoutInterval = 8.0
        if !secret.isEmpty {
            getReq.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, resp) = try? await apiSession.data(for: getReq),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(RuleProvidersResponse.self, from: data)
        else {
            return nil
        }
        return decoded.providers
    }

    private nonisolated static func updateSingleRuleProvider(
        name: String,
        port: Int,
        secret: String,
        session: URLSession,
        logger: Logger
    ) async {
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else { return }
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let putURL = baseURL.appending(path: "/providers/rules/\(escaped)")
        logger.info("Requesting PUT rule provider update from: \(putURL.absoluteString, privacy: .public)")

        var putReq = URLRequest(url: putURL, timeoutInterval: 15.0)
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

private struct RuleProvidersResponse: Decodable {
    let providers: [String: ProviderStub]?
}

private struct ProviderStub: Decodable {
    let name: String?
    let ruleCount: Int?
}
