import MeowModels
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

@MainActor
struct MvpHeaderBar: View {
    let mvpManager: MvpManager
    let onExportLogs: () -> Void
    let exportingLogs: Bool

    // Tap counter for 5-tap easter egg to switch back to full meow-ios mode
    @State private var minimalTapCount: Int = 0
    @State private var lastTapTime: Date?

    var body: some View {
        ZStack(alignment: .center) {
            // Centered Title with tap gesture
            Text("Block Ad")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MvpTheme.textPrimary)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleMinimalTap()
                }

            HStack {
                Spacer()

                Button(action: {
                    onExportLogs()
                }, label: {
                    ZStack {
                        if exportingLogs {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "doc.plaintext")
                                .font(.system(size: 14))
                                .foregroundStyle(MvpTheme.textSecondary)
                                .opacity(0.8)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                })
                .disabled(exportingLogs)
            }
        }
        .frame(height: 36)
    }

    private func handleMinimalTap() {
        let now = Date()
        if let last = lastTapTime, now.timeIntervalSince(last) > 2.0 {
            minimalTapCount = 0
        }
        lastTapTime = now
        minimalTapCount += 1

        if minimalTapCount >= 5 {
            minimalTapCount = 0
            MvpView.log.info("Minimal header 5-tap gesture triggered: switching to full meow-ios mode")
            withAnimation(.snappy) {
                mvpManager.isMvpMode = false
            }
            mvpManager.showToast("已切换至高级模式", type: .info)
        }
    }
}

@MainActor
struct MvpToggleSwitch: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            // Track
            Capsule()
                .fill(isOn ? MvpTheme.activeColor : MvpTheme.inactiveGray)
                .frame(width: 130, height: 56)
                .animation(.timingCurve(0.645, 0.045, 0.355, 1.0, duration: 0.35), value: isOn)

            // Thumb
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 86, height: 86)
                    .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
                    .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 1)

                // Active Checkmark
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(MvpTheme.activeColor)
                    .frame(width: 38, height: 38)
                    .scaleEffect(isOn ? 1.0 : 0.5)
                    .opacity(isOn ? 1.0 : 0.0)

                // Inactive Circle
                Circle()
                    .strokeBorder(MvpTheme.inactiveGray, lineWidth: 4)
                    .frame(width: 24, height: 24)
                    .scaleEffect(isOn ? 0.5 : 1.0)
                    .opacity(isOn ? 0.0 : 1.0)
            }
            .frame(width: 86, height: 86)
            .offset(x: isOn ? 34 : -34)
            .animation(.spring(duration: 0.35, bounce: 0.25), value: isOn)
        }
        .frame(width: 154, height: 86)
        .padding(.vertical, 24)
        .sensoryFeedback(.impact, trigger: isOn)
        .onTapGesture {
            MvpView.log.info("Toggle switch tapped (current isOn: \(isOn, privacy: .public))")
            action()
        }
    }
}

@MainActor
struct MvpStatusHero: View {
    let appModel: AppModel
    let activeProfile: Profile?
    let mvpManager: MvpManager

    private var isSwitchOn: Bool {
        switch appModel.vpnManager.stage {
        case .connected, .connecting, .preparing: return true
        default: return false
        }
    }

    private var statusTitle: String {
        switch appModel.vpnManager.stage {
        case .connected: return "防护已开启"
        case .connecting, .preparing: return "防护启动中"
        default: return "防护已暂停"
        }
    }

    private var statusSubtitle: String {
        switch appModel.vpnManager.stage {
        case .connected: return "防护运行中 · 智能拦截与隐私保护"
        case .connecting, .preparing: return "正在启动防护服务..."
        default: return "点击上方按钮开启防护"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            MvpToggleSwitch(isOn: isSwitchOn) {
                mvpManager.toggleConnection(appModel: appModel, activeProfile: activeProfile)
            }

            Text(statusTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(MvpTheme.textPrimary)
                .animation(.easeInOut(duration: 0.2), value: appModel.vpnManager.stage)

            Text(statusSubtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MvpTheme.textSecondary)
                .animation(.easeInOut(duration: 0.2), value: appModel.vpnManager.stage)
        }
    }
}

@MainActor
struct MvpQuickInfoCards: View {
    let appModel: AppModel

    private var isStart: Bool {
        appModel.vpnManager.stage == .connected
    }

    private var coreStatusText: String {
        switch appModel.vpnManager.stage {
        case .connected: return "正常"
        case .connecting, .preparing: return "启动中"
        default: return "停用"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            buildInfoItem(
                iconName: "shield.fill",
                title: "防护状态",
                value: isStart ? "已开启" : "未开启",
                isActive: isStart
            )

            buildInfoItem(
                iconName: "cpu",
                title: "内核状态",
                value: coreStatusText,
                isActive: isStart
            )
        }
    }

    private func buildInfoItem(iconName: String, title: String, value: String, isActive: Bool) -> some View {
        let bgFill = isActive ? MvpTheme.activeColor.opacity(0.12) : MvpTheme.inactiveBadgeBg.opacity(0.6)
        let iconColor = isActive ? MvpTheme.activeColor : MvpTheme.textSecondary

        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(bgFill)
                    .frame(width: 32, height: 32)

                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MvpTheme.textSecondary)

                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MvpTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(MvpTheme.cardBg)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(MvpTheme.borderColor, lineWidth: 1)
        )
    }
}

@MainActor
struct MvpProfileCard: View {
    let appModel: AppModel
    let activeProfile: Profile?
    let mvpManager: MvpManager

    @State private var urlInput: String = ""
    var isInputFocused: FocusState<Bool>.Binding
    @State private var versionStr: String = "v0"

    private var hasProfile: Bool {
        activeProfile != nil && !mvpManager.showInputArea
    }

    private var activeProfileTitle: String {
        let name = activeProfile?.name ?? ""
        return name.isEmpty ? "Block Ad" : name
    }

    private var updateDateStr: String {
        guard let date = activeProfile?.lastUpdated else { return "未知" }
        let timeStr = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) {
            return "今天 \(timeStr)"
        } else if Calendar.current.isDateInYesterday(date) {
            return "昨天 \(timeStr)"
        } else {
            return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
        }
    }

    nonisolated private static func parseRuleCount(from yaml: String?) -> String {
        guard let yaml else { return "v0" }
        var count = 0
        var inRules = false
        yaml.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("rules:") {
                inRules = true
            } else if inRules {
                if trimmed.hasPrefix("-") {
                    count += 1
                } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    stop = true
                }
            }
        }
        return "v\(count)"
    }

    var body: some View {
        VStack(spacing: 14) {
            buildProfileHeader()

            Divider()
                .background(MvpTheme.borderColor)

            ZStack(alignment: .center) {
                buildLoadedState()
                    .opacity(hasProfile ? 1 : 0)
                    .allowsHitTesting(hasProfile)

                buildImportState()
                    .opacity(hasProfile ? 0 : 1)
                    .allowsHitTesting(!hasProfile)
            }
            .padding(.vertical, 4)
        }
        .padding(16)
        .background(MvpTheme.cardBg)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(MvpTheme.borderColor, lineWidth: 1)
        )
        .task(id: activeProfile?.lastUpdated) {
            versionStr = Self.parseRuleCount(from: activeProfile?.yamlContent)
        }
    }

    private func buildProfileHeader() -> some View {
        HStack(alignment: .center) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15))
                    .foregroundStyle(MvpTheme.textPrimary)

                Text("配置文件")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MvpTheme.textPrimary)
            }

            Spacer()

            if hasProfile {
                Button(action: {
                    MvpView.log.info("Reset profile button tapped, expanding input area")
                    withAnimation(.snappy) {
                        mvpManager.showInputArea = true
                    }
                }, label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text("重置")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(MvpTheme.dangerText)
                    .padding(8)
                    .background(MvpTheme.dangerColor.opacity(0.05))
                    .clipShape(.rect(cornerRadius: 8))
                })
            } else if activeProfile != nil {
                Button(action: {
                    MvpView.log.info("Collapse profile input button tapped")
                    withAnimation(.snappy) {
                        mvpManager.showInputArea = false
                    }
                }, label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12))
                        Text("收起")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(MvpTheme.textSecondary)
                    .padding(8)
                    .background(MvpTheme.inactiveBadgeBg.opacity(0.4))
                    .clipShape(.rect(cornerRadius: 8))
                })
            }
        }
    }

    private func buildImportState() -> some View {
        VStack(spacing: 12) {
            ZStack(alignment: .trailing) {
                TextField(
                    "粘贴配置文件链接",
                    text: $urlInput,
                    prompt: Text("粘贴配置文件链接").foregroundStyle(MvpTheme.textSecondary)
                )
                .font(.system(size: 14))
                .foregroundStyle(MvpTheme.textPrimary)
                .tint(MvpTheme.activeColor)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.leading, 14)
                .padding(.trailing, 40)
                .padding(.vertical, 12)
                .focused(isInputFocused)
                .background(MvpTheme.inputBg)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(MvpTheme.borderColor, lineWidth: 1)
                )

                Button(action: {
                    if let pasted = UIPasteboard.general.string {
                        urlInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        MvpView.log.debug("Pasted URL into input from clipboard")
                    }
                }, label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 15))
                        .foregroundStyle(MvpTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                })
                .padding(.trailing, 4)
            }

            Button(action: {
                MvpView.log.info("Download and import button tapped")
                Task {
                    await mvpManager.importConfig(url: urlInput, appModel: appModel)
                }
            }, label: {
                HStack(alignment: .center, spacing: 8) {
                    if mvpManager.isImporting {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 15))
                        Text("下载并导入")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(MvpTheme.activeColor)
                .clipShape(.rect(cornerRadius: 12))
                .shadow(color: MvpTheme.activeColor.opacity(0.2), radius: 12, x: 0, y: 4)
            })
            .disabled(mvpManager.isImporting)
        }
    }

    private func buildLoadedState() -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 12) {
                Text(activeProfileTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(MvpTheme.textPrimary)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 6) {
                    Text("更新于：\(updateDateStr)")
                    Text("版本：\(versionStr)\(mvpManager.ruleProvidersVersionSuffix)")
                }
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(MvpTheme.textSecondary)
            }

            Spacer()

            Button(action: {
                if let profile = activeProfile {
                    MvpView.log.info("Update subscription button tapped for profile: \(profile.name, privacy: .public)")
                    Task {
                        await mvpManager.updateSubscription(appModel: appModel, activeProfile: profile)
                    }
                }
            }, label: {
                HStack(alignment: .center, spacing: 6) {
                    if mvpManager.isUpdating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text("更新")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(MvpTheme.activeColor)
                .clipShape(.rect(cornerRadius: 12))
                .shadow(color: MvpTheme.activeColor.opacity(0.2), radius: 12, x: 0, y: 4)
            })
        }
    }
}

// MARK: - Main MvpView

@MainActor
struct MvpView: View {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meow-ios", category: "mvp-ui")

    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [Profile]

    private let mvpManager = MvpManager.shared

    @State private var logExportDocument: MvpLogExportDocument?
    @State private var showingLogExporter = false
    @State private var exportingLogs = false

    @FocusState private var isInputFocused: Bool

    private var actualProfile: Profile? {
        profiles.first(where: \.isSelected) ?? profiles.first
    }

    var body: some View {
        ZStack {
            MvpTheme.bgPrimary
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    ScrollViewReader { scrollProxy in
                        VStack(spacing: 0) {
                            MvpHeaderBar(
                                mvpManager: mvpManager,
                                onExportLogs: { Task { await exportLogs() } },
                                exportingLogs: exportingLogs
                            )
                            .padding(.top, 12)

                            Spacer(minLength: 20)

                            MvpStatusHero(appModel: appModel, activeProfile: actualProfile, mvpManager: mvpManager)

                            Spacer(minLength: 24)

                            VStack(spacing: 16) {
                                MvpQuickInfoCards(appModel: appModel)
                                MvpProfileCard(
                                    appModel: appModel,
                                    activeProfile: actualProfile,
                                    mvpManager: mvpManager,
                                    isInputFocused: $isInputFocused
                                )
                                .id("ProfileCard")
                            }
                            .padding(.bottom, 16)
                        }
                        .padding(.horizontal, 20)
                        .frame(maxWidth: 600)
                        .frame(minHeight: geometry.size.height)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .onChange(of: isInputFocused) { _, isFocused in
                            if isFocused {
                                Task { @MainActor in
                                    // Delay slightly to let the keyboard safe area update
                                    try? await Task.sleep(for: .milliseconds(200))
                                    withAnimation(.easeOut(duration: 0.3)) {
                                        scrollProxy.scrollTo("ProfileCard", anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }

            if let toastMsg = mvpManager.toastMessage {
                buildToastOverlay(msg: toastMsg)
            }
        }
        .preferredColorScheme(.light)
        .task(id: actualProfile?.id) {
            MvpView.log.info("MvpView task loaded with profile: \(actualProfile?.name ?? "nil", privacy: .public), checking auto-update...")
            await mvpManager.checkAutoUpdate(appModel: appModel, activeProfile: actualProfile)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                MvpView.log.info("ScenePhase became active, checking auto-update...")
                Task {
                    await mvpManager.checkAutoUpdate(appModel: appModel, activeProfile: actualProfile)
                }
            }
        }
        .onChange(of: appModel.vpnManager.stage) { _, stage in
            if stage == .connected {
                Task { await mvpManager.fetchRuleProviderCounts() }
            }
        }
        .onAppear {
            if appModel.vpnManager.stage == .connected {
                Task { await mvpManager.fetchRuleProviderCounts() }
            }
        }
        .fileExporter(
            isPresented: $showingLogExporter,
            document: logExportDocument,
            contentType: .plainText,
            defaultFilename: "blockad-log-\(logTimestamp).log",
            onCompletion: { _ in
                logExportDocument = nil
            }
        )
    }

    private func buildToastOverlay(msg: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: toastIconName(for: mvpManager.toastType))
                    .foregroundStyle(.white)
                    .font(.system(size: 14, weight: .semibold))
                Text(msg)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(MvpTheme.toastBg)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.snappy, value: msg)
    }

    private func toastIconName(for type: MvpToastType) -> String {
        switch type {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Log Export

    private var logTimestamp: String {
        Date.now.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        ).filter { $0.isNumber }
    }

    private func exportLogs() async {
        exportingLogs = true
        defer { exportingLogs = false }
        let text = await MvpLogExporter.collectCombinedLogs()
        logExportDocument = MvpLogExportDocument(text: text)
        showingLogExporter = true
        Self.log.info("Log export document presented.")
    }
}
