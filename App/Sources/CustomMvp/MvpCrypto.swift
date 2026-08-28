import Foundation
import CryptoKit

/// 提供 MVP 配置文件加密/解密的支持
public enum MvpCrypto {
    
    /// AES-256 共享密钥 (32 bytes)
    /// 提示：后端需使用相同 Key 进行 AES-GCM 加密。
    /// 使用硬编码字符串的 SHA256 哈希值，可以根据需要随时替换为其他的 32 字节 Key。
    private static var symmetricKey: SymmetricKey {
        let keyData = SHA256.hash(data: "FkAdMvpSecretKey".data(using: .utf8)!)
        return SymmetricKey(data: keyData)
    }

    /// 尝试解密网络返回的配置文件数据
    ///
    /// - Parameter data: 网络返回的原始数据
    /// - Returns: 解密后的明文数据。如果原本就是明文或者解密失败，则原样返回。
    public static func decryptIfNecessary(_ data: Data) -> Data {
        // 1. 如果数据本身就是明文 YAML，直接返回，无需解密
        if isPlaintextYAML(data) {
            return data
        }

        // 2. 尝试 AES-GCM 解密
        // 约定密文格式为 CryptoKit 标准的 combined 格式：
        // [12 bytes Nonce] + [Ciphertext] + [16 bytes Tag]
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey)
            return decryptedData
        } catch {
            // 解密失败（可能是格式不匹配、Key错误，或原本就不是加密数据）
            // 为保持简单和不中断流程，原样返回 data，让后续的 YAML 解析器自行判断并抛出错误
            print("[MvpCrypto] 尝试解密失败或非预期的密文格式: \(error)")
            return data
        }
    }

    /// 简单嗅探数据是否已经是明文 YAML
    private static func isPlaintextYAML(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("dns:") || text.contains("proxy-groups:") || text.contains("rules:")
    }
}
