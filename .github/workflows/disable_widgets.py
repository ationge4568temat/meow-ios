#!/usr/bin/env python3
import sys
from pathlib import Path


def disable_widgets(project_path: Path) -> None:
    with open(project_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    new_lines = []
    in_widgets_target = False
    skip_dependency = 0

    for line in lines:
        # 1. 注释 MeowWidgets Target 定义
        if line.startswith("  MeowWidgets:"):
            in_widgets_target = True
        elif in_widgets_target and line.startswith("  ") and not line.startswith("    "):
            in_widgets_target = False

        if in_widgets_target:
            new_lines.append("# " + line if line.strip() else line)
            continue

        # 2. 注释 meow-ios 主 App 对 MeowWidgets 的依赖
        if "- target: MeowWidgets" in line:
            new_lines.append("# " + line)
            skip_dependency = 2
            continue
        if skip_dependency > 0 and ("embed:" in line or "codeSign:" in line):
            new_lines.append("# " + line)
            skip_dependency -= 1
            continue
        skip_dependency = 0

        # 3. 注释 Scheme 中的 MeowWidgets 构建目标
        if "MeowWidgets: all" in line:
            new_lines.append("# " + line)
            continue

        new_lines.append(line)

    with open(project_path, "w", encoding="utf-8") as f:
        f.writelines(new_lines)


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("project.yml")
    if not target.is_file():
        print(f"Error: {target} not found", file=sys.stderr)
        sys.exit(1)
    disable_widgets(target)
    print(f"Successfully commented out MeowWidgets in {target}")
