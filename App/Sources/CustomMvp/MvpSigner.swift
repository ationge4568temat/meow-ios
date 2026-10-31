import CryptoKit
import Foundation
import os
import Security

/// MVP 订阅请求签名器（字段与 Rust v1 保持 100% 同构，内部采用 HKDF 动态设备密钥签名）
public enum MvpSigner: Sendable {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meow-ios", category: "mvp-signer")

    // MARK: - CI Injected Configuration
    // [CUSTOM_SWIFT_CONFIG_BEGIN]
    private static let targetHosts: [String] = ["a.com", "b.com"]
    private static let signSalt: String = "abc"
    // [CUSTOM_SWIFT_CONFIG_END]

    public static let clientVersion: String = "1.0"
    public static let hkdfInfo = "meow-subscription-signer"

    public enum HeaderKeys {
        public static let auth = "X-Auth"
        public static let hwid = "X-HWID"
        public static let time = "X-Time"
        public static let nonce = "X-Nonce"
        public static let sign = "X-Sign"
        public static let clientVer = "X-Client-Ver"
    }

    /// 若命中域名白名单，则 auth 从 URL 参数中取，hwid 直接取 MvpDevice.hwid；不在白名单则不注入
    public static func applyIfTarget(to request: inout URLRequest) {
        guard let url = request.url, let host = url.host?.lowercased() else { return }

        // 1. 白名单校验：不在白名单则不注入
        let isTarget = targetHosts.contains { target in
            target.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(host) == .orderedSame
        }
        guard isTarget else {
            log.debug("Host \(host, privacy: .public) is not in target hosts; skipping signature.")
            return
        }

        // 2. auth 从 URL 参数 (query) 中取
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let auth = queryItems.first(where: { $0.name == "auth" })?.value,
              !auth.isEmpty
        else {
            log.debug("Missing auth parameter in URL query; skipping signature.")
            return
        }

        // 3. hwid 直接取 MvpDevice.hwid
        let hwid = MvpDevice.hwid
        guard !hwid.isEmpty else { return }

        let nowMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let tStr = String(nowMs)
        let nonce = generateNonce()
        let path = resolvePath(from: components)

        // 待签名 Payload: auth + hwid + t_str + nonce + path
        let payload = "\(auth)\(hwid)\(tStr)\(nonce)\(path)"

        // 基于 HKDF 派生特定设备专属密钥
        let deviceKey = deriveDeviceKey(masterSalt: signSalt, hwid: hwid)

        // 用设备专属密钥计算 HMAC-SHA256
        let sign = computeHMACSHA256(key: deviceKey, message: payload)

        // 注入与 Rust v1 完全同构的 Headers
        request.setValue(auth, forHTTPHeaderField: HeaderKeys.auth)
        request.setValue(hwid, forHTTPHeaderField: HeaderKeys.hwid)
        request.setValue(tStr, forHTTPHeaderField: HeaderKeys.time)
        request.setValue(nonce, forHTTPHeaderField: HeaderKeys.nonce)
        request.setValue(sign, forHTTPHeaderField: HeaderKeys.sign)
        request.setValue(clientVersion, forHTTPHeaderField: HeaderKeys.clientVer)

        log.info("Successfully signed request with HKDF for host: \(host, privacy: .public)")
    }

    /// 使用 HKDF-SHA256 派生设备专属密钥
    public static func deriveDeviceKey(masterSalt: String, hwid: String) -> SymmetricKey {
        let inputKey = SymmetricKey(data: Data(masterSalt.utf8))
        let saltData = Data(hwid.utf8)
        let infoData = Data(hkdfInfo.utf8)

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: saltData,
            info: infoData,
            outputByteCount: 32
        )
    }

    /// 计算 HMAC-SHA256 摘要
    public static func computeHMACSHA256(key: SymmetricKey, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 生成 16 字节随机数的 32 位小写 Hex 字符串
    public static func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 提取并标准化 URL 路径（保留末尾斜杠及原始百分号编码，空路径保底回退为 "/"）
    public static func resolvePath(from components: URLComponents) -> String {
        let rawPath = components.percentEncodedPath
        return rawPath.isEmpty ? "/" : (rawPath.hasPrefix("/") ? rawPath : "/" + rawPath)
    }
}
