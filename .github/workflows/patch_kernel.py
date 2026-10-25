#!/usr/bin/env python3
import os
import sys
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))

PATCH_FILE = os.path.join(SCRIPT_DIR, "kernel_patch.txt")
VENDOR_DIR = os.path.join(REPO_ROOT, "core/rust/vendor/meow-rs")
FFI_DIR = os.path.join(REPO_ROOT, "core/rust/meow-ios-ffi")
FFI_CARGO_FILE = os.path.join(FFI_DIR, "Cargo.toml")
TARGET_CODE = '    for (name, value) in headers {'


def find_target_files():
    candidates = []

    # 1. Check local vendor directory if exists
    vendor_target = os.path.join(VENDOR_DIR, "crates/meow-config/src/internal_http.rs")
    if os.path.exists(vendor_target):
        candidates.append(vendor_target)

    # 2. Check cargo checkouts directory
    cargo_home = os.environ.get("CARGO_HOME", os.path.expanduser("~/.cargo"))
    checkouts_dir = os.path.join(cargo_home, "git", "checkouts")
    if os.path.exists(checkouts_dir):
        for root, _, files in os.walk(checkouts_dir):
            if "crates/meow-config/src" in root.replace("\\", "/") and "internal_http.rs" in files:
                candidates.append(os.path.join(root, "internal_http.rs"))

    return list(set(candidates))


def step_clone_vendor():
    print(f"==> Cloning meow-rs v0.26.0 into {VENDOR_DIR}...")
    os.makedirs(os.path.dirname(VENDOR_DIR), exist_ok=True)
    subprocess.check_call([
        "git", "clone", "--depth", "1", "--branch", "v0.26.0",
        "https://github.com/meow-rs/meow-rs", VENDOR_DIR
    ])


def step_patch_ffi_cargo_toml():
    with open(FFI_CARGO_FILE, "r", encoding="utf-8") as f:
        content = f.read()

    patch_marker = '[patch."https://github.com/meow-rs/meow-rs"]'
    if patch_marker in content:
        print("Notice: [patch] section already exists in Cargo.toml.")
        return

    patch_section = f'\n{patch_marker}\nmeow-config = {{ path = "../vendor/meow-rs/crates/meow-config" }}\n'
    with open(FFI_CARGO_FILE, "a", encoding="utf-8") as f:
        f.write(patch_section)
    print("==> Added [patch] section to core/rust/meow-ios-ffi/Cargo.toml")


def patch_file(target_file):
    if not os.path.exists(PATCH_FILE):
        print(f"Error: {PATCH_FILE} not found", file=sys.stderr)
        sys.exit(1)

    with open(PATCH_FILE, "r", encoding="utf-8") as f:
        patch_code = f.read().rstrip()

    with open(target_file, "r", encoding="utf-8") as f:
        content = f.read()

    if "// [CUSTOM_KERNEL_PATCH]" in content:
        print(f"Notice: {target_file} is already patched.")
        return True

    if TARGET_CODE not in content:
        print(f"Error: TARGET_CODE not found in {target_file}", file=sys.stderr)
        return False

    replacement = patch_code + "\n\n" + TARGET_CODE
    new_content = content.replace(TARGET_CODE, replacement, 1)

    with open(target_file, "w", encoding="utf-8") as f:
        f.write(new_content)

    print(f"==> Successfully patched {target_file}!")
    return True


def main():
    if not os.path.exists(PATCH_FILE):
        print(f"Error: {PATCH_FILE} not found", file=sys.stderr)
        sys.exit(1)

    targets = find_target_files()

    # If not found in vendor or checkouts, try `cargo fetch`
    if not targets:
        print("==> Target not found in checkouts. Running cargo fetch...")
        try:
            subprocess.run(["cargo", "fetch", "--manifest-path", FFI_CARGO_FILE], check=True)
            targets = find_target_files()
        except Exception as e:
            print(f"Notice: cargo fetch skipped or unavailable ({e})")

    # If still not found, fallback to shallow git clone vendor directory
    if not targets:
        step_clone_vendor()
        step_patch_ffi_cargo_toml()
        targets = find_target_files()

    if not targets:
        print("Error: Could not locate internal_http.rs to patch!", file=sys.stderr)
        sys.exit(1)

    success_count = 0
    for target in targets:
        if patch_file(target):
            success_count += 1

    if success_count > 0:
        print(f"==> Kernel patch complete. {success_count} file(s) patched successfully.")
    else:
        print("Error: Failed to patch any kernel files.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
