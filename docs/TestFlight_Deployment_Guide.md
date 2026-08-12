# Meow iOS - TestFlight 云端自动化部署指南

本文档记录了将本项目成功部署至 TestFlight 所需的所有代码更改与苹果开发者后台配置，以便未来参考与维护。

## 1. 代码库修改记录

为了脱离原作者的开源环境并实现全自动化云端部署，我们对代码库进行了以下修改：

### 1.1 专属包名 (Bundle ID) 替换
将项目中所有的默认包名 `com.tangzixiang.meow` 以及默认应用组 `group.com.tangzixiang.meow` 全局替换为了您的专属标识符。
这不仅涉及工程配置，还深深绑定在底层代码中。以下是**必须修改的源码文件清单**：

#### A. 核心配置文件
- `project.yml`: XcodeGen 的工程构建脚本，必须修改其中的 `bundleIdPrefix` 字段。
- `App/Info.plist`: 决定 App 显示信息的配置文件。

#### B. 苹果权限声明文件 (Entitlements)
- `App/App.entitlements`: 主程序的权限声明，必须将 `com.apple.security.application-groups` 的值改为您的 `group.com.david.fkad`。
- `PacketTunnel/PacketTunnel.entitlements`: VPN 扩展的权限声明，做同样的 App Group 替换。

#### C. 业务逻辑源码 (Swift & Objective-C)
VPN 扩展和主程序需要通过 App Group 共享数据目录，因此在代码中写死了大量的 App Group 字符串，这些都已做替换：
- **主程序模型层**: `App/Sources/AppModel.swift`, `MeowShared/Sources/MeowModels/AppGroup.swift`
- **主程序服务层**: `App/Sources/Services/VpnManager.swift`, `App/Sources/Services/AppIPCBridge.swift`, `DailyTrafficAccumulator.swift`, `GeoAssetStager.swift`, `MeowAPI.swift`
- **VPN 扩展层 (Objective-C)**: `PacketTunnel/Sources/MWAppGroup.m`, `MWTunnelEngine.m`, `PacketTunnelProvider.m`

#### D. 底层核心层 (Rust)
- `core/rust/meow-ios-ffi/src/logging.rs`: Rust 层的日志模块也硬编码了宿主 App Group 的目录路径以存放日志文件。

#### E. 自动化脚本与其他
- `fastlane/Appfile`, `fastlane/Fastfile`
- `scripts/` 目录下的打包 shell 脚本。
- `MeowTests/` 目录下的单元测试用例。
### 1.2 云端打包工作流 (`.github/workflows/testflight.yml`)
由于本地手动签名 VPN 扩展极易遇到“描述文件不匹配”、“网络扩展权限不足”等沙盒报错，我们彻底废弃了本地编译脚本，引入了 **GitHub Actions**。
- **构建环境**: 统一使用云端 macOS 虚拟机与最新版 Xcode。
- **自动签名**: 使用 `xcodebuild -allowProvisioningUpdates`，借助 App Store Connect API 密钥，由云端服务器自动向苹果申请并下载最新的发布版（App Store）证书和描述文件，彻底解决了签名痛点。

### 1.3 解决的编译与环境冲突
1. **清理本地废弃配置**：彻底删除了 `证书/` 目录下的所有本地 `.mobileprovision`、`.p12` 及临时 `profile.plist`，保持代码库纯净。
2. **修正 Swift 版本兼容**：将 `MeowShared/Package.swift` 中的 `swift-tools-version` 从超前的 `6.2` 降级为 `6.0`，以适配当前的云端 Xcode 环境。
3. **修复签名团队丢失**：在 `xcodebuild` 命令参数和自动生成的 `ExportOptions.plist` 中，动态注入了 `DEVELOPMENT_TEAM=$TEAM_ID`，解决了命令行归档时找不到开发者团队的报错。

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
