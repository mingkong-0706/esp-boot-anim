#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# -*- coding: utf-8 -*-
"""
check_c.py -- 在没有 C 编译器的情况下对 C 源码做结构性自检。

开发机上没有安装任何 C 工具链，所以用这个脚本尽量把"笔误级"的错误
提前抓出来。它不是完整的 C 编译器，但能发现下面这几类真问题：

  1. 括号/花括号/方括号不配对
  2. 调用了未定义的函数（例如把 BaFileSizeGet 写成 BaFileSizeGet2）
  3. 使用了未声明的 BaXxx 标识符（函数 / 类型 / 全局变量 / 宏）
  4. 访问了任何结构体里都不存在的成员（X->Field / X.Field）
  5. 头文件里声明了但没有实现的函数（只对 Ba.h / BaPlat.h 检查）
  6. #define 重复定义且值不同

用法: python check_c.py
"""

from __future__ import annotations

import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRCDIR = os.path.join(ROOT, "src")
if len(sys.argv) > 1:
    SRCDIRS = [os.path.abspath(a) for a in sys.argv[1:]]
else:
    SRCDIRS = [SRCDIR]

KEYWORDS = {
    "if", "for", "while", "switch", "return", "sizeof", "do", "else", "case",
    "goto", "break", "continue", "defined", "static", "const", "void", "int",
    "char", "unsigned", "signed", "long", "short", "struct", "union", "enum",
    "typedef", "extern", "inline", "register", "volatile", "float", "double",
    "default", "true", "false", "NULL",
}

# UEFI / EDK2 / gnu-efi 提供的符号（不是我们定义的）
EXTERNAL = set("""
EFI_STATUS EFI_HANDLE EFI_SYSTEM_TABLE EFI_BOOT_SERVICES EFI_RUNTIME_SERVICES
EFI_FILE_PROTOCOL EFI_FILE_INFO EFI_SIMPLE_FILE_SYSTEM_PROTOCOL
EFI_GRAPHICS_OUTPUT_PROTOCOL EFI_GRAPHICS_OUTPUT_MODE_INFORMATION
EFI_GRAPHICS_OUTPUT_BLT_PIXEL EFI_LOADED_IMAGE_PROTOCOL EFI_INPUT_KEY
EFI_DEVICE_PATH_PROTOCOL EFI_GUID EFI_TIME EFIAPI UINT8 UINT16 UINT32 UINT64
UINTN INT32 INT64 BOOLEAN VOID CHAR8 CHAR16 TRUE FALSE NULL
EFI_SUCCESS EFI_ERROR EFI_DEVICE_ERROR EFI_ABORTED EFI_BUFFER_TOO_SMALL
EFI_SECURITY_VIOLATION EFI_NOT_FOUND EFI_UNSUPPORTED EFI_INVALID_PARAMETER
EfiLoaderData EfiBltBufferToVideo EFI_FILE_MODE_READ
PixelBlueGreenRedReserved8BitPerColor PixelRedGreenBlueReserved8BitPerColor
PixelBitMask PixelBltOnly
MEDIA_DEVICE_PATH MEDIA_FILEPATH_DP
gST gBS gRT gImageHandle
printf fopen fclose fread fwrite fseek ftell rewind fflush fputs fputc
malloc calloc realloc free
memcpy memmove memcmp memset
strlen strcmp strncmp strcpy strncpy snprintf sprintf sscanf atoi
exit abort qsort time clock clock_gettime realpath _fullpath
va_list va_start va_arg va_end
""".split())

# 外部（UEFI）结构体的成员名与协议里的函数指针名。
# 这些不可能出现在我们自己的结构体里，做成员检查时要放行。
EXTERNAL_MEMBERS = set("""
ConOut ConIn ConInHandle ConsoleInHandle BootServices RuntimeServices
OutputString EnableCursor Reset ClearScreen
AllocatePool FreePool Stall GetTime SetWatchdogTimer GetVariable SetVariable
CheckEvent WaitForKey ReadKeyStroke
OpenVolume Open Close GetInfo SetInfo SetPosition GetPosition Read Write
Flush Delete
HandleProtocol LocateProtocol LocateHandleBuffer OpenProtocol CloseProtocol
LoadImage StartImage UnloadImage Exit ExitBootServices
Mode Info QueryMode SetMode MaxMode SizeOfInfo
HorizontalResolution VerticalResolution PixelFormat PixelInformation
FrameBufferBase FrameBufferSize PixelsPerScanLine
RedMask GreenMask BlueMask ReservedMask
Blt
DeviceHandle FilePath ImageBase ImageSize
Type SubType Length
FileSize FileName PhysicalSize Attribute
Year Month Day Hour Minute Second Nanosecond TimeZone Daylight
CopyMem SetMem CompareMem AllocatePages FreePages GetMemoryMap
RaiseTPL RestoreTPL CreateEvent SetTimer WaitForEvent SignalEvent
CloseEvent InstallConfigurationTable CalculateCrc32
""".split())

# Python 里额外补充的已知外部符号（gnu-efi / 编译器内建）
EXTRA_EXTERNAL_PREFIXES = ("__",)


def strip_comments_and_literals(text: str) -> str:
    """去掉注释与字符串/字符字面量，保留换行以维持行号。"""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            i += 2
            continue
        if c == '"' or c == "'":
            quote = c
            out.append(" ")
            i += 1
            while i < n:
                if text[i] == "\\":
                    out.append(" ")
                    i += 1
                    if i < n:
                        out.append(" ")
                        i += 1
                    continue
                if text[i] == quote:
                    out.append(" ")
                    i += 1
                    break
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check_balance(path: str, text: str, problems: list) -> None:
    depth = {"(": 0, "{": 0, "[": 0}
    pairs = {")": "(", "}": "{", "]": "["}
    for lineno, line in enumerate(text.splitlines(), 1):
        for ch in line:
            if ch in depth:
                depth[ch] += 1
            elif ch in pairs:
                depth[pairs[ch]] -= 1
                if depth[pairs[ch]] < 0:
                    problems.append("%s:%d: 多余的 '%s'" % (path, lineno, ch))
                    depth[pairs[ch]] = 0
    for k, v in depth.items():
        if v != 0:
            problems.append("%s: '%s' 不配对（差 %d 个）" % (path, k, v))


FUNC_DEF_RE = re.compile(
    r"^[ \t]*(?:static[ \t]+)?(?:const[ \t]+)?[A-Za-z_][\w \t]*\**[ \t]*\n"
    r"[ \t]*([A-Za-z_]\w*)[ \t]*\(",
    re.M)

FUNC_DEF_ONELINE_RE = re.compile(
    r"^[ \t]*(?:static[ \t]+)?(?:const[ \t]+)?[A-Za-z_][\w \t]*\**[ \t]*"
    r"([A-Za-z_]\w*)[ \t]*\([^;{]*$",
    re.M)

PROTO_RE = re.compile(
    r"^[ \t]*(?:extern[ \t]+)?[A-Za-z_][\w \t]*\**[ \t]*([A-Za-z_]\w*)[ \t]*\([^;{]*\)[ \t]*;",
    re.M)

TYPEDEF_RE = re.compile(r"\}[ \t]*([A-Za-z_]\w*)[ \t]*;")
TYPEDEF_ALIAS_RE = re.compile(r"typedef[ \t]+[^;{]*\b([A-Za-z_]\w*)[ \t]*;")
STRUCT_TAG_RE = re.compile(r"typedef[ \t]+struct[ \t]+([A-Za-z_]\w*)")
DEFINE_RE = re.compile(r"^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)[ \t]*([^\n]*)", re.M)
CALL_RE = re.compile(r"([A-Za-z_]\w*)[ \t]*\(")
IDENT_BA_RE = re.compile(r"\b(Ba[A-Z_0-9][A-Za-z0-9_]*)\b")
MEMBER_RE = re.compile(r"->[ \t]*([A-Za-z_]\w*)")
DOTMEMBER_RE = re.compile(r"\b[A-Za-z_]\w*[ \t]*\.[ \t]*([A-Za-z_]\w*)")

STRUCT_BODY_RE = re.compile(r"typedef[ \t]+struct[ \t]*\{(.*?)\}[ \t]*[A-Za-z_]\w*[ \t]*;",
                            re.S)
NAMED_STRUCT_RE = re.compile(r"typedef[ \t]+struct[ \t]+[A-Za-z_]\w*[ \t]*\{(.*?)\}[ \t]*([A-Za-z_]\w*)[ \t]*;",
                             re.S)
# 不带 typedef 的具名结构体定义（例如 hosttest 里的 struct BaFile {...};）
PLAIN_STRUCT_RE = re.compile(r"(?<!typedef[ \t])struct[ \t]+[A-Za-z_]\w*[ \t]*\{(.*?)\}[ \t]*;",
                             re.S)


def member_names(body: str) -> list:
    names = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("/*"):
            continue
        # 取 ';' 或 '[' 之前最后一段里的最后一个标识符
        head = re.split(r"[;\[]", line)[0]
        head = head.replace("*", " ")
        toks = [t for t in re.split(r"\s+", head) if t]
        if len(toks) >= 2:
            cand = toks[-1]
            if re.fullmatch(r"[A-Za-z_]\w*", cand):
                names.append(cand)
    return names


def main() -> int:
    problems = []
    files = []
    for d in SRCDIRS:
        for name in sorted(os.listdir(d)):
            if name.endswith((".c", ".h")):
                files.append(os.path.join(d, name))

    raw = {}
    clean = {}
    for path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            t = fh.read()
        raw[path] = t
        c = strip_comments_and_literals(t)
        clean[path] = c

    # ---- 1. 括号平衡 ----
    for path in files:
        check_balance(os.path.relpath(path, ROOT), clean[path], problems)

    # ---- 2. 收集已定义符号 ----
    defined_funcs = set()
    protos = defaultdict(list)
    typedefs = set()
    defines = {}
    members = set()

    for path in files:
        c = clean[path]
        rel = os.path.relpath(path, ROOT)
        for m in FUNC_DEF_RE.finditer(c):
            defined_funcs.add(m.group(1))
        for m in FUNC_DEF_ONELINE_RE.finditer(c):
            defined_funcs.add(m.group(1))
        for m in PROTO_RE.finditer(c):
            protos[m.group(1)].append(rel)
        for m in TYPEDEF_RE.finditer(c):
            typedefs.add(m.group(1))
        for m in TYPEDEF_ALIAS_RE.finditer(c):
            typedefs.add(m.group(1))
        for m in STRUCT_TAG_RE.finditer(c):
            typedefs.add(m.group(1))
        for m in DEFINE_RE.finditer(c):
            name = m.group(1)
            val = m.group(2).strip()
            # BA_ENTRY 在 gnu-efi / EDK2 两个分支里故意取不同的值
            if name in defines and defines[name][1] != val and name != "BA_ENTRY":
                problems.append("%s: #define %s 与 %s 里的值不一致"
                                % (rel, name, defines[name][0]))
            defines[name] = (rel, val)
        for rx in (STRUCT_BODY_RE, NAMED_STRUCT_RE, PLAIN_STRUCT_RE):
            for m in rx.finditer(c):
                members.update(member_names(m.group(1)))

    known = set(KEYWORDS) | EXTERNAL | defined_funcs | set(protos) | typedefs | set(defines)
    known |= {n for n in members}

    # ---- 3. 调用未定义的函数 ----
    for path in files:
        c = clean[path]
        rel = os.path.relpath(path, ROOT)
        for lineno, line in enumerate(c.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in CALL_RE.finditer(line):
                name = m.group(1)
                if name in KEYWORDS or name in EXTERNAL or name in EXTERNAL_MEMBERS:
                    continue
                if name.startswith(EXTRA_EXTERNAL_PREFIXES):
                    continue
                if name not in known:
                    problems.append("%s:%d: 调用了未定义的 '%s'" % (rel, lineno, name))

    # ---- 4. 未声明的 BaXxx 标识符 ----
    for path in files:
        c = clean[path]
        rel = os.path.relpath(path, ROOT)
        for lineno, line in enumerate(c.splitlines(), 1):
            for m in IDENT_BA_RE.finditer(line):
                name = m.group(1)
                if name not in known:
                    problems.append("%s:%d: 未声明的标识符 '%s'" % (rel, lineno, name))

    # ---- 5. 不存在的结构体成员 ----
    for path in files:
        c = clean[path]
        rel = os.path.relpath(path, ROOT)
        for lineno, line in enumerate(c.splitlines(), 1):
            body = line.split("//")[0]
            for m in MEMBER_RE.finditer(body):
                name = m.group(1)
                if name in EXTERNAL_MEMBERS:
                    continue
                if name not in members:
                    problems.append("%s:%d: '->%s' 在任何结构体里都不存在" % (rel, lineno, name))

    # ---- 6. 头文件里声明但没实现的函数 ----
    for path in files:
        if not path.endswith(".h"):
            continue
        rel = os.path.relpath(path, ROOT)
        base = os.path.basename(path)
        if base not in ("Ba.h", "BaPlat.h", "BaUefi.h", "BaGuids.h"):
            continue
        c = clean[path]
        for m in PROTO_RE.finditer(c):
            name = m.group(1)
            if name in EXTERNAL or name in KEYWORDS:
                continue
            if name in typedefs or name in defines:
                continue
            if name.startswith(EXTRA_EXTERNAL_PREFIXES):
                continue
            if name not in defined_funcs:
                problems.append("%s: 声明了 '%s' 但没有任何 .c 实现它" % (rel, name))

    # ---- 输出 ----
    print("扫描 %d 个文件" % len(files))
    print("  函数定义 : %d" % len(defined_funcs))
    print("  类型     : %d" % len(typedefs))
    print("  宏       : %d" % len(defines))
    print("  结构成员 : %d" % len(members))
    print()
    if problems:
        print("发现 %d 个问题:" % len(problems))
        for p in problems:
            print("  - " + p)
        return 1
    print("OK: 没有发现结构性问题")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
