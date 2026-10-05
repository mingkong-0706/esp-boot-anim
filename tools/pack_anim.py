#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# -*- coding: utf-8 -*-
"""
pack_anim.py -- 把图片序列打包成 BAANIM01 (.baa) 开机动画帧文件。

用法:
    python pack_anim.py <输入> --out <输出.baa> [--width W] [--height H] [--fps N]
                        [--fit contain|cover|stretch|none] [--bg RRGGBB]
                        [--no-rle] [--quiet]

<输入> 可以是:
  * 一个目录   -- 读取其中所有 .png/.jpg/.jpeg/.bmp/.webp，按文件名里的数字做自然排序
                  (例如 frame2.png 排在 frame10.png 前面)
  * 单个文件   -- 只打包这一张图

尺寸处理 (所有帧都会被统一到 --width x --height，缺省取第一张图的尺寸):
  contain  等比缩放后居中，四周用 --bg 填充 (默认 000000)
  cover    等比缩放后居中裁剪，填满目标尺寸
  stretch  直接拉伸到目标尺寸
  none     尺寸必须与目标完全一致，否则报错退出

缩放统一使用 Pillow 的 LANCZOS 重采样。

本脚本不改动 baanim.py，只调用它提供的格式实现:
    pack() / pillow_to_bgrx() / AnimFile / FormatError
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# --- 保证从任意工作目录运行都能 import 到同目录的 baanim ------------------
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    print("错误: 需要 Pillow 才能运行本脚本", file=sys.stderr)
    raise SystemExit(2)

import baanim  # noqa: E402
from baanim import FormatError, AnimFile, pack, pillow_to_bgrx  # noqa: E402

# 支持的图片扩展名（小写）
EXTS = (".png", ".jpg", ".jpeg", ".bmp", ".webp")
FIT_MODES = ("contain", "cover", "stretch", "none")

_NUM_RE = re.compile(r"(\d+)")


# ----------------------------------------------------------------------
# 工具函数
# ----------------------------------------------------------------------
def die(msg: str, code: int = 2) -> "None":
    """打印中文错误并退出（不带 Python 回溯）。"""
    print("错误: %s" % msg, file=sys.stderr)
    raise SystemExit(code)


def natural_key(name: str):
    """自然排序键: 把文件名里的连续数字当成整数比较。"""
    parts = _NUM_RE.split(name)
    key = []
    for i, p in enumerate(parts):
        if i % 2:
            key.append((1, int(p), ""))
        else:
            key.append((0, 0, p.lower()))
    return key


def parse_color(text: str):
    """把 RRGGBB 解析成 (r, g, b)。"""
    s = text.strip().lstrip("#")
    if len(s) != 6 or any(c not in "0123456789abcdefABCDEF" for c in s):
        die("--bg 必须是 6 位十六进制 RRGGBB，收到 %r" % text)
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def is_image(name: str) -> bool:
    return os.path.splitext(name)[1].lower() in EXTS


def list_inputs(src: str):
    """返回待处理的图片路径列表（已按自然序排序）。"""
    if os.path.isdir(src):
        names = [n for n in os.listdir(src) if is_image(n)]
        if not names:
            die("目录中没有找到图片 (%s)" % ", ".join(EXTS))
        names.sort(key=natural_key)
        return [os.path.join(src, n) for n in names]
    if os.path.isfile(src):
        return [src]
    die("输入路径不存在: %s" % src)
    return []


def load_frames(paths):
    """读入所有图片，统一成 RGBA 模式（保留透明通道供后续合成）。"""
    out = []
    for p in paths:
        try:
            with Image.open(p) as im:
                im.load()
                out.append((p, im.convert("RGBA")))
        except Exception as exc:  # noqa: BLE001
            die("无法读取图片 %s: %s" % (p, exc))
    return out


def flatten(img, bg):
    """把带透明通道的图合成到纯色背景上，返回 RGBA。"""
    base = Image.new("RGBA", img.size, (bg[0], bg[1], bg[2], 255))
    base.alpha_composite(img)
    return base


def fit_frame(img, w: int, h: int, mode: str, bg):
    """把一张 RGBA 图统一到 w x h（尺寸不同的 none 模式在 main 里已提前拦截）。"""
    if img.size == (w, h):
        return img
    if mode == "none":
        die("--fit none 要求所有帧尺寸一致，但存在 %dx%d != %dx%d 的帧"
            % (img.size[0], img.size[1], w, h))
    if mode == "stretch":
        return img.resize((w, h), Image.LANCZOS)
    if mode not in ("contain", "cover"):
        die("未知的 --fit 模式: %r" % mode)

    sw, sh = img.size
    if sw <= 0 or sh <= 0:
        die("图片尺寸非法: %dx%d" % (sw, sh))
    scale = max(w / sw, h / sh) if mode == "cover" else min(w / sw, h / sh)
    nw = max(1, int(round(sw * scale)))
    nh = max(1, int(round(sh * scale)))
    resized = img.resize((nw, nh), Image.LANCZOS)

    if mode == "cover":
        # 居中裁剪：先裁后贴，避免负偏移
        left = max(0, (nw - w) // 2)
        top = max(0, (nh - h) // 2)
        return resized.crop((left, top, left + w, top + h))

    # contain: 居中贴在纯色背景画布上
    canvas = Image.new("RGBA", (w, h), (bg[0], bg[1], bg[2], 255))
    canvas.alpha_composite(resized, ((w - nw) // 2, (h - nh) // 2))
    return canvas


# ----------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="pack_anim.py",
        description="把图片序列打包成 .baa 开机动画帧文件（BAANIM01）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  python pack_anim.py frames\\ --out dist\\anim.baa --fps 30 --fit contain --bg 000000\n"
               "  python pack_anim.py logo.png --out dist\\logo.baa --width 640 --height 360 --fit cover\n")
    p.add_argument("input", help="输入目录（整个序列）或单个图片文件")
    p.add_argument("--out", required=True, help="输出的 .baa 文件路径")
    p.add_argument("--width", type=int, default=None, help="目标宽度（缺省=第一张图宽度）")
    p.add_argument("--height", type=int, default=None, help="目标高度（缺省=第一张图高度）")
    p.add_argument("--fps", type=int, default=30, help="帧率，默认 30")
    p.add_argument("--fit", choices=FIT_MODES, default="contain",
                   help="缩放方式，默认 contain")
    p.add_argument("--bg", default="000000", help="填充/透明合成背景色 RRGGBB，默认 000000")
    p.add_argument("--no-rle", action="store_true", help="关闭 RLE 压缩（原始帧数据）")
    p.add_argument("--quiet", action="store_true", help="只输出错误信息")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    quiet = args.quiet
    bg = parse_color(args.bg)

    if args.fps < 0 or args.fps > 1000:
        die("--fps 必须在 0..1000 之间，收到 %d" % args.fps)
    if (args.width is None) != (args.height is None):
        die("--width 和 --height 必须同时指定")

    paths = list_inputs(args.input)
    loaded = load_frames(paths)

    first = loaded[0][1]
    if args.width is None:
        tw, th = first.size
    else:
        tw, th = args.width, args.height
    if tw <= 0 or th <= 0:
        die("目标尺寸非法: %dx%d" % (tw, th))
    if tw * th > baanim.MAX_PIXELS:
        die("目标尺寸过大: %dx%d (上限 %d 像素)" % (tw, th, baanim.MAX_PIXELS))
    if len(loaded) > baanim.MAX_FRAMES:
        die("帧数过多: %d (上限 %d)" % (len(loaded), baanim.MAX_FRAMES))

    # 逐帧统一尺寸 -> BGRX
    frames = []
    for name, img in loaded:
        if args.fit == "none" and img.size != (tw, th):
            die("--fit none 要求所有帧尺寸一致: %s 是 %dx%d，而目标是 %dx%d"
                % (name, img.size[0], img.size[1], tw, th))
        fitted = fit_frame(img, tw, th, args.fit, bg)
        if fitted.mode != "RGBA":
            fitted = fitted.convert("RGBA")
        if args.fit == "contain":
            fitted = flatten(fitted, bg)   # 背景不透明，这里只是规范化
        frames.append(pillow_to_bgrx(fitted))

    expect = tw * th * 4
    for i, f in enumerate(frames):
        if len(f) != expect:
            die("第 %d 帧字节数 %d != %d" % (i, len(f), expect))

    try:
        blob = pack(frames, tw, th, args.fps, rle=not args.no_rle)
    except FormatError as exc:
        die("打包失败: %s" % exc, 1)

    out_path = os.path.abspath(args.out)
    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "wb") as fh:
        fh.write(blob)

    # ---------------- 统计信息 ----------------
    n = len(frames)
    raw_total = n * tw * th * 4
    size = len(blob)
    ratio_pct = (100.0 * size / raw_total) if raw_total else 0.0
    saved = (100.0 - ratio_pct)
    avg = size / n if n else 0.0

    if not quiet:
        print("输入      : %s%s" % (args.input, "（目录）" if os.path.isdir(args.input) else "（单文件）"))
        print("输出      : %s" % out_path)
        print("帧数      : %d" % n)
        print("尺寸      : %dx%d" % (tw, th))
        print("fps       : %d" % args.fps)
        print("缩放方式  : %s" % args.fit)
        print("RLE 压缩  : %s" % ("否" if args.no_rle else "是"))
        print("文件大小  : %d 字节 (%.2f MiB)" % (size, size / 1048576.0))
        print("原始大小  : %d 字节 (%.2f MiB)" % (raw_total, raw_total / 1048576.0))
        print("压缩比    : %.2f%%（节省 %.2f%%）" % (ratio_pct, saved))
        print("平均每帧  : %.1f 字节 (%.2f KiB)" % (avg, avg / 1024.0))

    # 立刻回读自检，确保写出的文件真的能解码
    try:
        with open(out_path, "rb") as fh:
            chk = AnimFile(fh.read())
        if (chk.frame_count, chk.width, chk.height) != (n, tw, th):
            die("回读校验失败: 头部字段不一致", 1)
        for i in range(chk.frame_count):
            if chk.frame(i) != frames[i]:
                die("回读校验失败: 第 %d 帧像素不一致" % i, 1)
    except FormatError as exc:
        die("回读校验失败: %s" % exc, 1)
    if not quiet:
        print("回读校验  : OK（%d 帧逐像素一致）" % n)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("已中断", file=sys.stderr)
        raise SystemExit(130)
