#!/usr/bin/env python3
"""
patch_kernel.py - 在 CI 构建阶段对 Rust 内核进行就地代码注入与落盘保护
与 .github/workflows/build-rust-device.sh 紧密结合：
1. Target A (HTTP 签名头): 在 crates/meow-config/src/internal_http.rs 注入防重放鉴权头
2. Target B (规则密文解密 - 方案 A): 在 crates/meow-config/src/rule_provider.rs 的 2 处 HTTP 载入点
   进行前置透明过滤，底层解析器与文件载入点 100% 保持官方原版不动；
   注入 rule_decrypt.rs 并补齐 crates/meow-config/Cargo.toml 加密依赖
3. Target C (Swift 客户端): 同步将目标域名与 Salt 配置更新至 MvpSigner.swift
"""

import os
import sys
import time
import shutil
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))

PATCH_FILE = os.path.join(SCRIPT_DIR, "kernel_patch.txt")
RULE_DECRYPT_SRC = os.path.join(SCRIPT_DIR, "rule_decrypt.rs")
VENDOR_DIR = os.path.join(REPO_ROOT, "core/rust/vendor")
FFI_DIR = os.path.join(REPO_ROOT, "core/rust/meow-ios-ffi")
FFI_CARGO_FILE = os.path.join(FFI_DIR, "Cargo.toml")

# --- Target A: internal_http.rs 锚点 ---
TARGET_CODE = '    for (name, value) in headers {'

# --- Target B: rule_provider.rs 极简 2 处插桩（底层 parse_bytes_to_ruleset_with_format 0改动） ---
SITE_HTTP_ORIG = """    let parse = |bytes: &[u8]| {
        parse_bytes_to_ruleset_with_format(bytes, behavior, explicit_format, ctx, strict)
    };"""

SITE_HTTP_PATCH = """    let parse = |bytes: &[u8]| {
        let payload = crate::rule_decrypt::preprocess_payload(bytes, Some(url), behavior);
        parse_bytes_to_ruleset_with_format(&payload, behavior, explicit_format, ctx, strict)
    };"""

SITE_INSTALL_ORIG = """        let cache_write_lock = Arc::clone(&self.cache_write_lock);
        let (boxed, parsed_as) = crate::spawn_blocking_with_current_dispatcher(move || {
            let parsed =
                parse_bytes_to_ruleset_with_format(&bytes, behavior, format, &ctx_clone, strict)?;"""

SITE_INSTALL_PATCH = """        let cache_write_lock = Arc::clone(&self.cache_write_lock);
        let vehicle_url = self.vehicle.clone();
        let (boxed, parsed_as) = crate::spawn_blocking_with_current_dispatcher(move || {
            let payload = crate::rule_decrypt::preprocess_payload(&bytes, Some(vehicle_url.as_str()), behavior);
            let parsed =
                parse_bytes_to_ruleset_with_format(&payload, behavior, format, &ctx_clone, strict)?;"""


def find_target_files():
    cargo_home = os.environ.get("CARGO_HOME", os.path.expanduser("~/.cargo"))
    checkouts_dir = os.path.join(cargo_home, "git", "checkouts")
    candidates = []

    if os.path.exists(checkouts_dir):
        for root, _, files in os.walk(checkouts_dir):
            norm_root = root.replace("\\", "/")
            if "crates/meow-config/src" in norm_root and "internal_http.rs" in files:
                candidates.append(os.path.join(root, "internal_http.rs"))

    return list(set(candidates))


def cleanup_stale_overrides():
    # 彻底移除之前可能产生的 vendor 目录，防止干扰 Cargo
    if os.path.exists(VENDOR_DIR):
        print(f"==> Removing stale vendor directory: {VENDOR_DIR}")
        shutil.rmtree(VENDOR_DIR, ignore_errors=True)

    # 如果 Cargo.toml 中残留了 [patch]，清理恢复纯净官方依赖
    if os.path.exists(FFI_CARGO_FILE):
        with open(FFI_CARGO_FILE, "r", encoding="utf-8") as f:
            content = f.read()
        patch_marker = '[patch."https://github.com/meow-rs/meow-rs"]'
        if patch_marker in content:
            print("==> Cleaning up leftover [patch] section from Cargo.toml...")
            new_content = content.split(patch_marker)[0].rstrip() + "\n"
            with open(FFI_CARGO_FILE, "w", encoding="utf-8") as f:
                f.write(new_content)


def patch_internal_http(target_file):
    """Target A: 注入 HTTP 签名鉴权请求头"""
    if not os.path.exists(PATCH_FILE):
        print(f"Error: {PATCH_FILE} not found", file=sys.stderr)
        sys.exit(1)

    with open(PATCH_FILE, "r", encoding="utf-8") as f:
        patch_code = f.read().rstrip()

    rule_hosts = os.environ.get("KERNEL_RULE_HOST", "").strip() or "a.com,b.com"
    sign_salt = os.environ.get("KERNEL_SIGN_SALT", "").strip() or "abc"

    hosts_list = [h.strip().split(":")[0] for h in rule_hosts.split(",") if h.strip()]
    hosts_str = ", ".join(f'"{h}"' for h in hosts_list)
    sign_salt_escaped = sign_salt.replace("\\", "\\\\").replace('"', '\\"')

    patch_code = patch_code.replace("__KERNEL_RULE_HOSTS__", hosts_str)
    patch_code = patch_code.replace("__KERNEL_SIGN_SALT__", sign_salt_escaped)

    with open(target_file, "r", encoding="utf-8") as f:
        content = f.read()

    if "// [CUSTOM_KERNEL_PATCH]" in content:
        print(f"==> Updating existing HTTP patch in {target_file}...")
        start_idx = content.find("// [CUSTOM_KERNEL_PATCH]")
        target_idx = content.find(TARGET_CODE, start_idx)
        if target_idx != -1:
            line_start = content.rfind("\n", 0, start_idx) + 1
            content = content[:line_start] + content[target_idx:]

    if TARGET_CODE not in content:
        print(f"==> Skipping revision without anchor: {target_file}")
        return False

    replacement = patch_code + "\n\n" + TARGET_CODE
    new_content = content.replace(TARGET_CODE, replacement, 1)

    with open(target_file, "w", encoding="utf-8") as f:
        f.write(new_content)

    now = time.time()
    os.utime(target_file, (now, now))
    return True


def patch_rule_provider(internal_http_path):
    """Target B (方案 A): 仅在 2 处 HTTP 载入点注入预处理，函数定义及 load_file 0 改动"""
    src_dir = os.path.dirname(internal_http_path)
    config_dir = os.path.dirname(src_dir)
    rule_provider_file = os.path.join(src_dir, "rule_provider.rs")
    lib_file = os.path.join(src_dir, "lib.rs")
    rule_decrypt_dst = os.path.join(src_dir, "rule_decrypt.rs")
    cargo_toml = os.path.join(config_dir, "Cargo.toml")

    if not os.path.exists(rule_provider_file):
        print(f"Error: {rule_provider_file} not found", file=sys.stderr)
        return False

    # 1. 补齐 crates/meow-config/Cargo.toml 中的解密依赖
    if os.path.exists(cargo_toml):
        with open(cargo_toml, "r", encoding="utf-8") as f:
            c_content = f.read()
        deps_to_add = []
        if "chacha20poly1305" not in c_content:
            deps_to_add.append('chacha20poly1305 = "0.10"')
        if "hmac" not in c_content:
            deps_to_add.append('hmac = "0.12"')
        if "sha2" not in c_content:
            deps_to_add.append('sha2 = "0.10"')
        if deps_to_add:
            marker = "# [CUSTOM_KERNEL_DEPS]\n"
            target = "[dependencies]\n"
            if target in c_content:
                replacement = target + marker + "\n".join(deps_to_add) + "\n"
                c_content = c_content.replace(target, replacement, 1)
                with open(cargo_toml, "w", encoding="utf-8") as f:
                    f.write(c_content)
                print(f"==> Injected crypto dependencies into {cargo_toml}")

    # 2. 复制并注入 Salt 到 crates/meow-config/src/rule_decrypt.rs
    # 规则解密 Salt 与签名鉴权 Salt (KERNEL_SIGN_SALT) 严格独立，严禁自动兜底互用
    rule_salt = (
        os.environ.get("RULE_ENCRYPT_SALT", "").strip()
        or os.environ.get("RULE_SECRET_SALT", "").strip()
    )
    if not rule_salt:
        if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS"):
            print("ERROR: RULE_ENCRYPT_SALT is required in CI environment but not set!", file=sys.stderr)
            sys.exit(1)
        rule_salt = "abc"
    if os.path.exists(RULE_DECRYPT_SRC):
        with open(RULE_DECRYPT_SRC, "r", encoding="utf-8") as f:
            decrypt_code = f.read()
        decrypt_code = decrypt_code.replace("__KERNEL_RULE_SALT__", rule_salt)
        with open(rule_decrypt_dst, "w", encoding="utf-8") as f:
            f.write(decrypt_code)
        print(f"==> Injected rule_decrypt.rs into {src_dir}! [Salt: {rule_salt[:6]}***]")

    # 3. 在 lib.rs 注册 pub mod rule_decrypt;
    if os.path.exists(lib_file):
        with open(lib_file, "r", encoding="utf-8") as f:
            lib_content = f.read()
        if "pub mod rule_decrypt;" not in lib_content:
            lib_content = "pub mod rule_decrypt;\n" + lib_content
            with open(lib_file, "w", encoding="utf-8") as f:
                f.write(lib_content)
            print(f"==> Registered rule_decrypt module in {lib_file}")

    # 4. 在 rule_provider.rs 仅插桩 2 处 HTTP 调用点
    with open(rule_provider_file, "r", encoding="utf-8") as f:
        rp_content = f.read()

    if "crate::rule_decrypt::preprocess_payload" in rp_content:
        print(f"==> Notice: {rule_provider_file} already patched.")
    else:
        if SITE_HTTP_ORIG not in rp_content or SITE_INSTALL_ORIG not in rp_content:
            print(f"Error: Target sites not found in {rule_provider_file}", file=sys.stderr)
            return False

        rp_content = rp_content.replace(SITE_HTTP_ORIG, SITE_HTTP_PATCH, 1)
        rp_content = rp_content.replace(SITE_INSTALL_ORIG, SITE_INSTALL_PATCH, 1)

        with open(rule_provider_file, "w", encoding="utf-8") as f:
            f.write(rp_content)
        print(f"==> Successfully patched 2 HTTP rule sites in {rule_provider_file}!")

    now = time.time()
    for fp in [rule_decrypt_dst, lib_file, rule_provider_file]:
        if os.path.exists(fp):
            os.utime(fp, (now, now))

    return True


def revert_all(targets):
    """一键还原所有插桩代码"""
    for target in targets:
        src_dir = os.path.dirname(target)
        config_dir = os.path.dirname(src_dir)
        rule_provider_file = os.path.join(src_dir, "rule_provider.rs")
        lib_file = os.path.join(src_dir, "lib.rs")
        rule_decrypt_dst = os.path.join(src_dir, "rule_decrypt.rs")
        cargo_toml = os.path.join(config_dir, "Cargo.toml")

        # 1. 还原 internal_http.rs
        if os.path.exists(target):
            with open(target, "r", encoding="utf-8") as f:
                content = f.read()
            if "// [CUSTOM_KERNEL_PATCH]" in content:
                start_idx = content.find("// [CUSTOM_KERNEL_PATCH]")
                target_idx = content.find(TARGET_CODE, start_idx)
                if target_idx != -1:
                    line_start = content.rfind("\n", 0, start_idx) + 1
                    content = content[:line_start] + content[target_idx:]
                    with open(target, "w", encoding="utf-8") as f:
                        f.write(content)
                    print(f"==> Reverted {target}")

        # 2. 还原 rule_provider.rs
        if os.path.exists(rule_provider_file):
            with open(rule_provider_file, "r", encoding="utf-8") as f:
                rp_content = f.read()
            if "crate::rule_decrypt::preprocess_payload" in rp_content:
                rp_content = rp_content.replace(SITE_HTTP_PATCH, SITE_HTTP_ORIG)
                rp_content = rp_content.replace(SITE_INSTALL_PATCH, SITE_INSTALL_ORIG)
                with open(rule_provider_file, "w", encoding="utf-8") as f:
                    f.write(rp_content)
                print(f"==> Reverted {rule_provider_file}")

        # 3. 还原 lib.rs
        if os.path.exists(lib_file):
            with open(lib_file, "r", encoding="utf-8") as f:
                lib_content = f.read()
            if "pub mod rule_decrypt;\n" in lib_content:
                lib_content = lib_content.replace("pub mod rule_decrypt;\n", "")
                with open(lib_file, "w", encoding="utf-8") as f:
                    f.write(lib_content)
                print(f"==> Reverted {lib_file}")

        # 4. 删除 rule_decrypt.rs
        if os.path.exists(rule_decrypt_dst):
            os.remove(rule_decrypt_dst)
            print(f"==> Removed {rule_decrypt_dst}")

        # 5. 还原 Cargo.toml
        if os.path.exists(cargo_toml):
            with open(cargo_toml, "r", encoding="utf-8") as f:
                lines = f.readlines()
            new_lines = []
            skip = False
            for line in lines:
                if "# [CUSTOM_KERNEL_DEPS]" in line:
                    skip = True
                    continue
                if skip:
                    if any(k in line for k in ["chacha20poly1305", "hmac", "sha2"]):
                        continue
                    skip = False
                new_lines.append(line)
            with open(cargo_toml, "w", encoding="utf-8") as f:
                f.writelines(new_lines)
            print(f"==> Reverted {cargo_toml}")


def patch_swift_signer(hosts_str, sign_salt_escaped):
    """Target C: 同步配置至 Swift 端 MvpSigner.swift"""
    swift_file = os.path.join(REPO_ROOT, "App/Sources/CustomMvp/MvpSigner.swift")
    if not os.path.exists(swift_file):
        print(f"Notice: {swift_file} not found; skipping Swift signer patch.")
        return False

    with open(swift_file, "r", encoding="utf-8") as f:
        content = f.read()

    begin_marker = "// [CUSTOM_SWIFT_CONFIG_BEGIN]"
    end_marker = "// [CUSTOM_SWIFT_CONFIG_END]"
    if begin_marker not in content or end_marker not in content:
        print(f"Warning: Markers not found in {swift_file}; skipping.")
        return False

    start_idx = content.find(begin_marker)
    end_idx = content.find(end_marker) + len(end_marker)

    new_config = f"""{begin_marker}
    private static let targetHosts: [String] = [{hosts_str}]
    private static let signSalt: String = "{sign_salt_escaped}"
    {end_marker}"""

    new_content = content[:start_idx] + new_config + content[end_idx:]
    with open(swift_file, "w", encoding="utf-8") as f:
        f.write(new_content)

    print(f"==> Successfully patched {swift_file}! [Hosts: {hosts_str}, Salt: ***]")
    return True


def main():
    if not os.path.exists(PATCH_FILE):
        print(f"Error: {PATCH_FILE} not found", file=sys.stderr)
        sys.exit(1)

    cleanup_stale_overrides()

    targets = find_target_files()

    if not targets:
        print("==> Target not found in checkouts. Running cargo metadata to ensure checkouts are unpacked...")
        try:
            subprocess.run(
                ["cargo", "metadata", "--manifest-path", FFI_CARGO_FILE, "--format-version", "1"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True
            )
            targets = find_target_files()
        except Exception as e:
            print(f"Notice: cargo metadata invocation: {e}")

    if not targets:
        print("ERROR: Could not locate internal_http.rs in ~/.cargo/git/checkouts!", file=sys.stderr)
        print("Please ensure 'cargo fetch' or 'cargo metadata' was executed prior to patch_kernel.py.", file=sys.stderr)
        sys.exit(1)

    # 支持 --revert / -r
    if len(sys.argv) > 1 and sys.argv[1] in ("--revert", "-r"):
        print("==> Reverting all kernel patches...")
        revert_all(targets)
        return

    patched_count = 0
    for target in targets:
        print(f"==> Target found: {target}")
        if patch_internal_http(target) and patch_rule_provider(target):
            patched_count += 1

    if patched_count > 0:
        print(f"==> Kernel patch complete. {patched_count} kernel checkout(s) patched successfully.")
    else:
        print("ERROR: Failed to patch any kernel files.", file=sys.stderr)
        sys.exit(1)

    rule_hosts = os.environ.get("KERNEL_RULE_HOST", "").strip() or "a.com,b.com"
    sign_salt = os.environ.get("KERNEL_SIGN_SALT", "").strip() or "abc"
    hosts_list = [h.strip().split(":")[0] for h in rule_hosts.split(",") if h.strip()]
    hosts_str = ", ".join(f'"{h}"' for h in hosts_list)
    sign_salt_escaped = sign_salt.replace("\\", "\\\\").replace('"', '\\"')
    patch_swift_signer(hosts_str, sign_salt_escaped)


if __name__ == "__main__":
    main()
