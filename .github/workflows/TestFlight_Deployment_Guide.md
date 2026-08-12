# Meow iOS - TestFlight 云端自动化部署指南

本文档记录了将本项目成功部署至 TestFlight 所需的所有代码更改与苹果开发者后台配置，以便未来参考与维护。

## 1. 代码库修改记录

为了脱离原作者的开源环境并实现全自动化云端部署，我们对代码库进行了以下修改：

### 1.1 专属包名 (Bundle ID) 替换
将项目中所有的默认包名 `com.tangzixiang.meow` 以及默认应用组 `group.com.tangzixiang.meow` 全局替换为了您的专属标识符。
由于 iOS 网络代理类应用的特殊性（主程序与扩展程序必须通过共享沙盒通信），这些标识符深深绑定在底层代码中。以下是源码修改清单：

#### 🔴 【绝对必改项】 (若遗漏将导致编译失败、无法上传或应用崩溃)

**A. 核心配置文件与权限声明 (Entitlements)**
这决定了应用能不能被苹果认可，能不能开通 VPN 权限：
- `project.yml`: XcodeGen 构建脚本，必须修改 `bundleIdPrefix` 字段。
- `App/Info.plist`: 决定 App 显示信息的配置文件。
- `App/App.entitlements`: 必须修改 `com.apple.security.application-groups` 为新 App Group。
- `PacketTunnel/PacketTunnel.entitlements`: VPN 扩展的权限声明，做同样的 App Group 替换。

**B. 业务逻辑源码 (Swift & Objective-C)**
VPN 扩展和主程序需要通过 App Group 路径传递代理规则和流量数据。若这里没改，App 会直接崩溃或无法开启 VPN：
- **主程序数据层**: `App/Sources/AppModel.swift`, `MeowShared/Sources/MeowModels/AppGroup.swift`
- **主程序服务层**: `App/Sources/Services/VpnManager.swift`, `App/Sources/Services/AppIPCBridge.swift`, `DailyTrafficAccumulator.swift`, `GeoAssetStager.swift`, `MeowAPI.swift`
- **VPN 扩展通信层**: `PacketTunnel/Sources/MWAppGroup.m`, `MWTunnelEngine.m`, `PacketTunnelProvider.m`

**C. 底层核心层 (Rust)**
- `core/rust/meow-ios-ffi/src/logging.rs`: Rust 底层库硬编码了宿主 App Group 的目录路径用于写入日志文件，不改会导致 Rust 引擎无权限写入而崩溃。

#### 🟢 【可选改动项】 (不改不影响 App 核心运行，但建议修改以保持代码整洁)

**D. 自动化脚本与测试用例**
这些文件不参与最终发布的 App 安装包，不改也没有致命影响：
- `fastlane/Appfile`, `fastlane/Fastfile`: 老式的自动化打包工具配置（我们已弃用，改用 GitHub Actions）。
- `scripts/`: 原作者遗留的本地 shell 打包脚本。
- `MeowTests/`: 单元测试代码，虽然不影响用户使用，但不改可能导致本地跑单元测试时读取不到配置。
### 1.2 引入全新的云端打包工作流
**【原项目对比】**：原版 `upstream/main` 中只有老旧的本地打包脚本 (`scripts/build-adhoc.sh` 等)，没有任何 CI/CD 配置。
**【新增内容】**：我们从零创建了 `.github/workflows/testflight.yml` 文件。彻底废弃了本地编译脚本，引入了 GitHub Actions，实现了云端自动归档和上传，彻底解决了手动打包时恶心的证书管理痛点。

### 1.3 环境冲突与配置修正
**【原项目对比】**：原版项目对 Xcode 和 Swift 版本的激进要求，与常规 CI 环境存在冲突。
1. **降级 Swift 编译兼容性（🔴 必改项）**：将 `MeowShared/Package.swift` 中的 `swift-tools-version` 从超前的 `6.2` 降级为 `6.0`，以适配当前云端 macOS 虚拟机的 Xcode 16.x / 26.x 环境。
2. **修复命令行签名团队丢失（🔴 必改项）**：在 `.github/workflows/testflight.yml` 的 `xcodebuild` 归档参数和自动生成的 `ExportOptions.plist` 中，动态注入了 `DEVELOPMENT_TEAM=$TEAM_ID`。因为纯命令行打包时 Xcode 无法像图形界面那样自动推断团队。

---

## 2. 苹果开发者后台配置清单

为了让云端机器能够顺畅工作，必须在苹果系统进行以下基础建设：

### 2.1 开发者证书后台 (Developer Portal) 注册
登录 `developer.apple.com` 的 Identifiers 页面，完成以下三个标识符的注册：

1. **主 App ID (`com.david.fkad`)**：
   - 必须在 Capabilities 中勾选 `Network Extension` 和 `App Groups`。
2. **VPN 扩展 App ID (`com.david.fkad.PacketTunnel`)**：
   - 同样必须在 Capabilities 中勾选 `Network Extension` 和 `App Groups`。
3. **应用组 (App Group) (`group.com.david.fkad`)**：
   - 创建后，**必须**进入上述两个 App ID 的配置页面，点击 App Groups 旁边的 `Configure`，将其关联绑定。

### 2.2 App Store Connect 网页配置
登录 `appstoreconnect.apple.com`：
1. **新建 App**：创建一个壳子，Bundle ID 选择 `com.david.fkad`。
2. **生成 API 密钥 (至尊钥匙)**：
   - 角色必须选择 **管理 (Admin)**（或包含访问证书权限的 App Manager），否则云端机器无权为您生成签名证书。
   - 生成后，获得三个核心数据：`Issuer ID`、`Key ID` 以及下载的 `.p8` 私钥文件。

---

## 3. GitHub Secrets 环境变量配置

最后，将苹果后台的凭证填入 GitHub 仓库的 **Settings -> Secrets and variables -> Actions** 中：

- `TEAM_ID`: 苹果开发者账号的 10 位团队代号（在开发者后台右上角获取，如 3WX5DF47UP）。
- `ASC_ISSUER_ID`: API 密钥的颁发者 ID。
- `ASC_KEY_ID`: API 密钥的专属 ID。
- `ASC_PRIVATE_KEY`: 下载的 `.p8` 文件的完整文本内容。

配置完毕后，只需在 Actions 面板点击 **"Run workflow"**，即可随时喝着咖啡等待新版本推送至手机的 TestFlight！
