import MeowModels
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers


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
                .foregroundColor(MvpTheme.textPrimary)
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
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "doc.plaintext")
                                .font(.system(size: 16))
                                .foregroundColor(MvpTheme.textSecondary)
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
            withAnimation {
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

            // Thumb container
            HStack {
                if isOn { Spacer() }
                
                // Thumb
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 86, height: 86)
                        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
                        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 1)

                    // Active Checkmark
                    Image(systemName: "checkmark")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(MvpTheme.activeColor)
                        .opacity(isOn ? 1 : 0)
                        .scaleEffect(isOn ? 1 : 0.5)

                    // Inactive Circle
                    Circle()
                        .stroke(MvpTheme.inactiveGray, lineWidth: 4)
                        .frame(width: 24, height: 24)
                        .opacity(isOn ? 0 : 1)
                        .scaleEffect(isOn ? 0.5 : 1)
                }
                .offset(x: isOn ? 12 : -12)
                
                if !isOn { Spacer() }
            }
            .frame(width: 130 + 24) // accommodate the oversized thumb
        }
        .padding(.vertical, 24)
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                action()
            }
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
        case .connecting, .preparing: return "防护启动中..."
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
        VStack(spacing: 12) {
            MvpToggleSwitch(isOn: isSwitchOn) {
                mvpManager.toggleConnection(appModel: appModel, activeProfile: activeProfile)
            }

            Text(statusTitle)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(MvpTheme.textPrimary)
                .animation(.easeInOut(duration: 0.2), value: appModel.vpnManager.stage)

            Text(statusSubtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(MvpTheme.textSecondary)
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
        HStack(spacing: 12) {
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
        let bgFill = isActive ? MvpTheme.activeColor.opacity(0.12) : Color(red: 229 / 255.0, green: 231 / 255.0, blue: 235 / 255.0).opacity(0.6)
        let iconColor = isActive ? MvpTheme.activeColor : MvpTheme.textSecondary
        
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(bgFill)
                    .frame(width: 32, height: 32)

                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(MvpTheme.textSecondary)

                Text(value)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(MvpTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(MvpTheme.cardBg)
        .cornerRadius(16)
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
    @FocusState private var isInputFocused: Bool
    @State private var ruleCountStr: String = "0 条"

    private var hasProfile: Bool {
        activeProfile != nil && !mvpManager.showInputArea
    }

    private var activeProfileTitle: String {
        let name = activeProfile?.name ?? ""
        return name.isEmpty ? "Block Ad" : name
    }
    
    private var updateDateStr: String {
        if let date = activeProfile?.lastUpdated {
            let df = DateFormatter()
            if Calendar.current.isDateInToday(date) {
                df.dateFormat = "'今天' HH:mm"
            } else if Calendar.current.isDateInYesterday(date) {
                df.dateFormat = "'昨天' HH:mm"
            } else {
                df.dateFormat = "MM-dd HH:mm"
            }
            return df.string(from: date)
        }
        return "未知"
    }
    
    private func computeRuleCount(from yaml: String?) async -> String {
        guard let yaml else { return "0 条" }
        return await Task.detached {
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
            return "\(count) 条"
        }.value
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
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(MvpTheme.borderColor, lineWidth: 1)
        )
        .padding(.bottom, isInputFocused ? 120 : 0)
        .animation(.easeOut(duration: 0.25), value: isInputFocused)
        .task(id: activeProfile?.lastUpdated) {
            ruleCountStr = await computeRuleCount(from: activeProfile?.yamlContent)
        }
    }

    private func buildProfileHeader() -> some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(MvpTheme.textPrimary)

                Text("配置文件")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(MvpTheme.textPrimary)
            }

            Spacer()

            if hasProfile {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        mvpManager.showInputArea = true 
                    }
                }, label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text("重置")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(MvpTheme.dangerColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(MvpTheme.dangerColor.opacity(0.08))
                    .cornerRadius(8)
                })
            } else if activeProfile != nil {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        mvpManager.showInputArea = false
                    }
                }, label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                        Text("收起")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(MvpTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(MvpTheme.borderColor.opacity(0.6))
                    .cornerRadius(8)
                })
            }
        }
    }

    private func buildImportState() -> some View {
        VStack(spacing: 12) {
            ZStack(alignment: .trailing) {
                TextField("粘贴配置文件链接", text: $urlInput)
                    .font(.system(size: 13))
                    .padding(.leading, 14)
                    .padding(.trailing, 40)
                    .padding(.vertical, 12)
                    .focused($isInputFocused)
                    .background(MvpTheme.inputBg)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(MvpTheme.borderColor, lineWidth: 1)
                    )

                Button(action: {
                    if let pasted = UIPasteboard.general.string {
                        urlInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }, label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 15))
                        .foregroundColor(MvpTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                })
                .padding(.trailing, 4)
            }

            Button(action: {
                Task {
                    await mvpManager.importConfig(url: urlInput, appModel: appModel)
                }
            }, label: {
                HStack(spacing: 8) {
                    if mvpManager.isImporting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 14))
                        Text("下载并导入")
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(MvpTheme.activeColor)
                .cornerRadius(12)
                .shadow(color: MvpTheme.activeColor.opacity(0.2), radius: 12, x: 0, y: 4)
            })
            .disabled(mvpManager.isImporting)
        }
    }

    private func buildLoadedState() -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {
                Text(activeProfileTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(MvpTheme.textPrimary)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 6) {
                    Text("更新于：\(updateDateStr)")
                    Text("规则：\(ruleCountStr)")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(MvpTheme.textSecondary)
            }

            Spacer()

            Button(action: {
                if let profile = activeProfile {
                    Task {
                        await mvpManager.updateSubscription(appModel: appModel, activeProfile: profile)
                    }
                }
            }, label: {
                HStack(spacing: 6) {
                    if mvpManager.isUpdating {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text("更新")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(MvpTheme.activeColor)
                .cornerRadius(12)
                .shadow(color: MvpTheme.activeColor.opacity(0.2), radius: 12, x: 0, y: 4)
            })
        }
    }
}

// MARK: - Main MvpView

@MainActor
struct MvpView: View {
    @Environment(AppModel.self) private var appModel
    @Query private var profiles: [Profile]

    private let mvpManager = MvpManager.shared

    @State private var logExportDocument: MvpLogExportDocument?
    @State private var showingLogExporter = false
    @State private var exportingLogs = false

    private var actualProfile: Profile? {
        return profiles.first(where: \.isSelected) ?? profiles.first
    }

    var body: some View {
        ZStack {
            MvpTheme.bgPrimary
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
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
                            MvpProfileCard(appModel: appModel, activeProfile: actualProfile, mvpManager: mvpManager)
                        }
                        .padding(.bottom, 16)
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            if let toastMsg = mvpManager.toastMessage {
                buildToastOverlay(msg: toastMsg)
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
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
                Text(msg)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(MvpTheme.toastBg)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: msg)
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
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }

    private func exportLogs() async {
        exportingLogs = true
        defer { exportingLogs = false }
        let text = await Task.detached { MvpLogExporter.collectCombinedLogs() }.value
        logExportDocument = MvpLogExportDocument(text: text)
        showingLogExporter = true
    }
}
