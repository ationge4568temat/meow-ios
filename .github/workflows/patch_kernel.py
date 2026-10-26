#!/usr/bin/env python3
import os
import sys
import time
import shutil
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))

PATCH_FILE = os.path.join(SCRIPT_DIR, "kernel_patch.txt")
VENDOR_DIR = os.path.join(REPO_ROOT, "core/rust/vendor")
FFI_DIR = os.path.join(REPO_ROOT, "core/rust/meow-ios-ffi")
FFI_CARGO_FILE = os.path.join(FFI_DIR, "Cargo.toml")
TARGET_CODE = '    for (name, value) in headers {'


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
    # 1. 彻底移除之前可能产生的 vendor 目录，防止干扰 Cargo
    if os.path.exists(VENDOR_DIR):
        print(f"==> Removing stale vendor directory: {VENDOR_DIR}")
        shutil.rmtree(VENDOR_DIR, ignore_errors=True)

    # 2. 如果 Cargo.toml 中残留了 [patch]，必须清理掉，恢复纯净官方依赖
    if os.path.exists(FFI_CARGO_FILE):
        with open(FFI_CARGO_FILE, "r", encoding="utf-8") as f:
            content = f.read()
        patch_marker = '[patch."https://github.com/meow-rs/meow-rs"]'
        if patch_marker in content:
            print("==> Cleaning up leftover [patch] section from Cargo.toml...")
            new_content = content.split(patch_marker)[0].rstrip() + "\n"
            with open(FFI_CARGO_FILE, "w", encoding="utf-8") as f:
                f.write(new_content)


def patch_file(target_file):
    if not os.path.exists(PATCH_FILE):
        print(f"Error: {PATCH_FILE} not found", file=sys.stderr)
        sys.exit(1)

    with open(PATCH_FILE, "r", encoding="utf-8") as f:
        patch_code = f.read().rstrip()

    # 读取环境变量进行动态替换
    rule_hosts = os.environ.get("KERNEL_RULE_HOST", "").strip() or "a.com,b.com"
    sign_salt = os.environ.get("KERNEL_SIGN_SALT", "").strip() or "abc"

    hosts_list = [h.strip().split(":")[0] for h in rule_hosts.split(",") if h.strip()]
    hosts_str = ", ".join(f'"{h}"' for h in hosts_list)
    sign_salt_escaped = sign_salt.replace("\\", "\\\\").replace('"', '\\"')

    patch_code = patch_code.replace("__KERNEL_RULE_HOSTS__", hosts_str)
    patch_code = patch_code.replace("__KERNEL_SIGN_SALT__", sign_salt_escaped)

    with open(target_file, "r", encoding="utf-8") as f:
        content = f.read()

    # 如果已经打过旧补丁，先还原回 TARGET_CODE，以便打入最新配置
    if "// [CUSTOM_KERNEL_PATCH]" in content:
        print(f"==> Updating existing patch in {target_file}...")
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
    lib_rs = os.path.join(os.path.dirname(target_file), "lib.rs")
    if os.path.exists(lib_rs):
        os.utime(lib_rs, (now, now))

    print(f"==> Successfully patched {target_file}! [Hosts: {hosts_str}, Salt: ***]")
    return True


def main():
    if not os.path.exists(PATCH_FILE):
        print(f"Error: {PATCH_FILE} not found", file=sys.stderr)
        sys.exit(1)

    # 清理残留的 vendor 和 [patch]，确保单一源码来源，绝无类型冲突
    cleanup_stale_overrides()

    # 查找 ~/.cargo/git/checkouts 中的 internal_http.rs
    targets = find_target_files()

    # 如果此时尚未解压，尝试调用 cargo metadata 触发 unpack
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

    patched_count = 0
    for target in targets:
        print(f"==> Target found: {target}")
        if patch_file(target):
            patched_count += 1

    if patched_count > 0:
        print(f"==> Kernel patch complete. {patched_count} file(s) patched successfully.")
    else:
        print("ERROR: Failed to patch any kernel files.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
