//! 核心规则资源密文落盘与内存即时解密模块 (EMRS & EYML)
//!
//! 1:1 对标安卓端 Go 内核 `provider_decrypt.go`。
//! 负责识别私有加密容器、从 URL 解析 HWID、执行 ChaCha20-Poly1305 解密
//! 以及在失败时提供格式与行为感知的合法空规则蜜罐明文。

use anyhow::{anyhow, Result};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hmac::{Hmac, Mac};
use meow_rules::RuleSetBehavior;
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

pub const EMRS_MAGIC: &[u8; 4] = b"EMRS";
pub const EYML_MAGIC: &[u8; 4] = b"EYML";
pub const CONTAINER_HEADER_LEN: usize = 18; // 4 Magic + 1 Ver + 1 Mode + 12 Nonce
pub const TAG_LEN: usize = 16;
pub const MIN_CONTAINER_LEN: usize = CONTAINER_HEADER_LEN + TAG_LEN;

/// 编译期由 CI Secret 注入替换的盐常量
pub const KERNEL_RULE_SALT: &str = "__KERNEL_RULE_SALT__";

/// 由 Mihomo ConvertToMrs 原生生成的最小合法 Domain MRS 二进制蜜罐流 (包含一条空路由占位域名)
pub static HONEYPOT_MRS_DOMAIN_PAYLOAD: &[u8] = &[
    0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x00, 0x3d, 0x02, 0x00, 0x64, 0x03, 0x4d,
    0x52, 0x53, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x02, 0xaa, 0x00, 0x6a, 0x00, 0x23, 0x6d, 0x6f, 0x63, 0x2e, 0x6c, 0x6c,
    0x75, 0x6e, 0x2d, 0x72, 0x65, 0x64, 0x6c, 0x6f, 0x68, 0x65, 0x63, 0x61,
    0x6c, 0x70, 0x2d, 0x74, 0x6f, 0x70, 0x79, 0x65, 0x6e, 0x6f, 0x68, 0x2d,
    0x64, 0x72, 0x61, 0x75, 0x67, 0x06, 0x00, 0x60, 0x20, 0x18, 0x0c, 0x97,
    0x1f, 0x4e, 0xe2, 0x59, 0xa6, 0xc5, 0x75, 0x5a, 0x29, 0x20, 0xa6, 0xc4,
];

/// 由 Mihomo ConvertToMrs 原生生成的最小合法 IPCIDR MRS 二进制蜜罐流 (包含 RFC 5737 保留网段 198.51.100.1/32)
pub static HONEYPOT_MRS_IPCIDR_PAYLOAD: &[u8] = &[
    0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x00, 0xe5, 0x00, 0x00, 0x70, 0x4d, 0x52,
    0x53, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xc6, 0x33, 0x64,
    0x05, 0x00, 0x33, 0x27, 0x83, 0x17, 0x2c, 0x1a, 0x56, 0x08, 0x60, 0x70,
    0x45, 0xbf, 0xf5, 0x20, 0xaa,
];

/// 最小合法空 YAML 文本规则数据
pub static HONEYPOT_YAML_PAYLOAD: &[u8] = b"payload:\n  - DOMAIN-KEYWORD,guard-honeypot-placeholder-null\n";

/// 判断数据是否为私有加密容器 (匹配 EMRS 或 EYML)
#[inline]
pub fn is_encrypted_rule_container(data: &[u8]) -> bool {
    if data.len() < MIN_CONTAINER_LEN {
        return false;
    }
    let magic = &data[0..4];
    magic == EMRS_MAGIC || magic == EYML_MAGIC
}

/// 从规则 Provider 的 Vehicle URL 中提取 HWID 参数（离线冷启动与在线更新均有效）
#[inline]
pub fn extract_hwid_from_vehicle(vehicle_url: Option<&str>) -> String {
    vehicle_url
        .and_then(|u| url::Url::parse(u).ok())
        .and_then(|parsed| {
            parsed.query_pairs().find(|(k, _)| k == "hwid").map(|(_, v)| v.into_owned())
        })
        .unwrap_or_default()
}

/// 基于 HWID 派生 32 字节对称密钥：HMAC-SHA256(KERNEL_RULE_SALT, hwid)[:32]
#[inline]
fn derive_rule_key(hwid: &str) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(KERNEL_RULE_SALT.as_bytes())
        .expect("HMAC initialization failed");
    mac.update(hwid.as_bytes());
    let result = mac.finalize().into_bytes();
    let mut key = [0u8; 32];
    key.copy_from_slice(&result[0..32]);
    key
}

/// 内存即时解密实现 (ChaCha20-Poly1305，强绑定 AAD=hwid)
pub fn decrypt_rule_payload(data: &[u8], hwid: &str) -> Result<Vec<u8>> {
    if hwid.is_empty() {
        return Err(anyhow!("empty hwid context"));
    }
    if data.len() < MIN_CONTAINER_LEN {
        return Err(anyhow!("invalid container length"));
    }

    let nonce = Nonce::from_slice(&data[6..18]);
    let ciphertext_with_tag = &data[18..];

    let key = derive_rule_key(hwid);
    let cipher = ChaCha20Poly1305::new_from_slice(&key)
        .map_err(|e| anyhow!("cipher init failed: {e}"))?;

    let payload = Payload {
        msg: ciphertext_with_tag,
        aad: hwid.as_bytes(),
    };

    // 强校验 AAD=hwid，跨设备解密在此处直接失败报错
    cipher
        .decrypt(nonce, payload)
        .map_err(|_| anyhow!("AEAD authentication failed or wrong HWID"))
}

/// 获取格式与行为感知的合法蜜罐明文切片
#[inline]
pub fn get_honeypot_payload(magic: &[u8], behavior: RuleSetBehavior) -> &'static [u8] {
    if magic == EMRS_MAGIC {
        if behavior == RuleSetBehavior::Ipcidr {
            HONEYPOT_MRS_IPCIDR_PAYLOAD
        } else {
            HONEYPOT_MRS_DOMAIN_PAYLOAD
        }
    } else {
        HONEYPOT_YAML_PAYLOAD
    }
}

/// RAII 守护包装器：离开作用域时自动对明文内存执行 Volatile Zeroize 抹除
pub struct ZeroizeOnDrop(pub Vec<u8>);

impl Drop for ZeroizeOnDrop {
    fn drop(&mut self) {
        for b in self.0.iter_mut() {
            unsafe {
                std::ptr::write_volatile(b, 0);
            }
        }
        std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
    }
}

/// 智能切片枚举：实现 Deref<Target = [u8]>，支持零拷贝透明透传
pub enum RulePayload<'a> {
    Plaintext(&'a [u8]),
    Honeypot(&'static [u8]),
    Decrypted(ZeroizeOnDrop),
}

impl<'a> std::ops::Deref for RulePayload<'a> {
    type Target = [u8];
    #[inline]
    fn deref(&self) -> &[u8] {
        match self {
            Self::Plaintext(b) => b,
            Self::Honeypot(b) => b,
            Self::Decrypted(g) => &g.0,
        }
    }
}

/// 核心前置透明过滤器：是密文 -> 解密为标准规则，失败为蜜罐规则（均为明文），随后透明透传
pub fn preprocess_payload<'a>(
    bytes: &'a [u8],
    vehicle_url: Option<&str>,
    behavior: RuleSetBehavior,
) -> RulePayload<'a> {
    if is_encrypted_rule_container(bytes) {
        let hwid = extract_hwid_from_vehicle(vehicle_url);
        if let Ok(decrypted) = decrypt_rule_payload(bytes, &hwid) {
            RulePayload::Decrypted(ZeroizeOnDrop(decrypted))
        } else {
            RulePayload::Honeypot(get_honeypot_payload(&bytes[0..4], behavior))
        }
    } else {
        RulePayload::Plaintext(bytes)
    }
}
