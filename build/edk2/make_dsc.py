#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_dsc.py -- 补齐 BootAnimPkg.dsc 里缺失的 [LibraryClasses] 映射。

为什么需要它
============
EDK2 每升级一次，MdePkg 的基础库就可能新依赖一个"库类"（library class），
例如 2022 年 BaseLib 开始依赖 RegisterFilterLib。这时自建工程如果没在 DSC 里
指定这个类的实例，build 就会报：

    error 4000: Instance of library class [RegisterFilterLib] is not found

这个脚本的做法（**只增不减，幂等**）：

  1. 先从一个"已知可用"的清单里取需要映射的库类；
  2. 再扫描 <edk2>/MdePkg/Library/**/*.inf，读出每个 INF 的
     `LIBRARY_CLASS = XxxLib|...`，把 MdePkg 里所有库类都补进来
     （优先选名字以 Null 结尾的实例，优先选声明支持 UEFI_APPLICATION 的）；
  3. **只保留磁盘上真实存在的 .inf 路径**（避免指向不存在的实例）；
  4. 与 DSC 里已有的映射**合并**：已经有的不覆盖，缺的才追加。

所以它绝不会删掉你已有的映射，跑多少次结果都一样。

用法
====
    python3 make_dsc.py <edk2目录>                # 就地更新 BootAnimPkg.dsc
    python3 make_dsc.py <edk2目录> [dsc] [输出dsc]

Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

# 我们真正需要的、且在所有 EDK2 版本里路径都稳定的映射。
# 路径不存在时会被自动跳过。
KNOWN: list[tuple[str, str]] = [
    ("BaseLib",                  "MdePkg/Library/BaseLib/BaseLib.inf"),
    ("BaseMemoryLib",            "MdePkg/Library/BaseMemoryLib/BaseMemoryLib.inf"),
    ("RegisterFilterLib",        "MdePkg/Library/RegisterFilterLibNull/RegisterFilterLibNull.inf"),
    ("StackCheckLib",            "MdePkg/Library/StackCheckLibNull/StackCheckLibNull.inf"),
    ("DebugLib",                 "MdePkg/Library/BaseDebugLibNull/BaseDebugLibNull.inf"),
    ("DebugPrintErrorLevelLib",  "MdePkg/Library/BaseDebugPrintErrorLevelLib/BaseDebugPrintErrorLevelLib.inf"),
    ("PcdLib",                   "MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf"),
    ("PrintLib",                 "MdePkg/Library/BasePrintLib/BasePrintLib.inf"),
    ("MemoryAllocationLib",      "MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf"),
    ("UefiBootServicesTableLib", "MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf"),
    ("UefiApplicationEntryPoint", "MdePkg/Library/UefiApplicationEntryPoint/UefiApplicationEntryPoint.inf"),
    ("UefiLib",                  "MdePkg/Library/UefiLib/UefiLib.inf"),
    ("UefiRuntimeServicesTableLib", "MdePkg/Library/UefiRuntimeServicesTableLib/UefiRuntimeServicesTableLib.inf"),
    ("DevicePathLib",            "MdePkg/Library/UefiDevicePathLib/UefiDevicePathLib.inf"),
    ("ReportStatusCodeLib",      "MdePkg/Library/BaseReportStatusCodeLibNull/BaseReportStatusCodeLibNull.inf"),
]

ENTRY_RE = re.compile(r"^\[LibraryClasses\][ \t]*\r?\n(.*?)(?=^\[)", re.S | re.M)
LIBRARY_CLASS_RE = re.compile(r"^[ \t]*LIBRARY_CLASS[ \t]*=[ \t]*([^\r\n#]+)", re.M)


def scan_mde_library_instances(edk2: Path) -> dict[str, str]:
    """扫描 MdePkg/Library 下所有 INF，得出 库类名 -> 实例路径。"""
    root = edk2 / "MdePkg" / "Library"
    best: dict[str, tuple[int, str]] = {}
    if not root.is_dir():
        return {}

    for inf in sorted(root.rglob("*.inf")):
        try:
            txt = inf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        m = LIBRARY_CLASS_RE.search(txt)
        if not m:
            continue
        spec = m.group(1).strip()
        parts = [p.strip() for p in spec.split("|")]
        cls = parts[0]
        if not cls:
            continue
        types = parts[1].split() if len(parts) > 1 else []
        if types and ("UEFI_APPLICATION" not in types and "UEFI_DRIVER" not in types):
            continue                      # 这个实例不支持 UEFI 应用，别选它

        name = inf.stem
        if name.endswith("Null"):
            score = 0                     # 最合适：空实现，零依赖
        elif "Null" in name:
            score = 1
        elif types:
            score = 2
        else:
            score = 3                     # 通用实现
        rel = inf.relative_to(edk2).as_posix()
        if cls not in best or score < best[cls][0]:
            best[cls] = (score, rel)

    return {k: v[1] for k, v in best.items()}


def parse_existing(dsc_text: str) -> list[tuple[str, str]]:
    """取出 DSC 现有的 [LibraryClasses] 条目（保序）。"""
    m = ENTRY_RE.search(dsc_text)
    if not m:
        return []
    out = []
    for line in m.group(1).splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "|" not in s:
            continue
        cls, path = s.split("|", 1)
        out.append((cls.strip(), path.strip()))
    return out


def render(cls_paths: list[tuple[str, str]]) -> str:
    return "[LibraryClasses]\n" + "\n".join(
        "  %s|%s" % (c, p) for c, p in cls_paths) + "\n\n"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2

    edk2 = Path(os.path.abspath(os.path.expanduser(argv[1])))
    dsc_path = Path(argv[2]) if len(argv) > 2 else edk2 / "BootAnimPkg" / "BootAnimPkg.dsc"
    out_path = Path(argv[3]) if len(argv) > 3 else dsc_path

    if not dsc_path.is_file():
        print("错误: 找不到 DSC: %s" % dsc_path)
        return 2

    dsc_text = dsc_path.read_text(encoding="utf-8", errors="replace")
    existing = parse_existing(dsc_text)

    # 1) 已知清单 + 扫描结果
    wanted: list[tuple[str, str]] = list(KNOWN)
    scanned = scan_mde_library_instances(edk2)
    for cls, path in sorted(scanned.items()):
        wanted.append((cls, path))

    have = {c for c, _ in existing}
    merged: list[tuple[str, str]] = list(existing)
    added: list[str] = []
    skipped: list[str] = []

    for cls, path in wanted:
        if (edk2 / path).is_file() is False:
            if cls not in have:
                skipped.append("%s (%s 不存在)" % (cls, path))
            continue
        if cls in have:
            continue
        have.add(cls)
        merged.append((cls, path))
        added.append(cls)

    new_text, n = ENTRY_RE.subn(render(merged), dsc_text)
    if n != 1:
        print("错误: DSC 里没有（或有多于一个）[LibraryClasses] 段")
        return 3
    out_path.write_text(new_text, encoding="utf-8")

    print("DSC: %s" % out_path)
    print("  原有映射 %d 条，本次新增 %d 条，合计 %d 条"
          % (len(existing), len(added), len(merged)))
    if added:
        print("  新增: %s" % ", ".join(added))
    if skipped:
        print("  跳过(路径不存在): %s" % "; ".join(skipped))
    for k in ("RegisterFilterLib", "StackCheckLib", "UefiApplicationEntryPoint",
              "UefiBootServicesTableLib", "BaseLib", "BaseMemoryLib",
              "DebugLib", "MemoryAllocationLib", "PcdLib"):
        print("   %-28s %s" % (k, "OK" if any(c == k for c, _ in merged) else "-"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
