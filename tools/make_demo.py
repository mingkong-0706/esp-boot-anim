#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# -*- coding: utf-8 -*-
"""
make_demo.py -- 纯程序化生成一段 UEFI 开机动画并打包成 .baa，无需任何外部素材。

用法:
    python make_demo.py [--width 1920] [--height 1080] [--frames 60] [--fps 30]
                        [--theme dots|bar] [--bg RRGGBB] [--out dist/anim.baa]
                        [--cfg dist/bootanim.cfg] [--preview dist/preview.png]
                        [--no-rle] [--ss N]

主题:
    dots  (默认) 仿 Windows 11 开机转圈: 5 个圆点在一个圆环上公转，颜色 #0078D4，
                 每个点依次"淡入淡出 + 缩放"，形成流畅的追尾效果。
                 环半径 = 屏幕高度 * 6%，点半径 = 屏幕高度 * 1.1%，画在屏幕正中央。
    bar          屏幕下方的细进度条来回扫动（Windows 更新风格）。

平滑做法 (关键实现选择):
    * 所有几何量都是 帧号/总帧数 的连续函数，角度严格线性推进，
      首帧与末帧自动衔接 —— 循环播放无跳变。
    * 圆点/进度条不是整屏超采样（1920x1080 的 4 倍画布要 33M 像素，太占内存），
      而是"只对要画的矩形区域"做 SS 倍超采样: 区域内在 SS*SS 的放大画布上
      用 ImageDraw 绘制，再用 numpy 按 SS*SS 块求平均缩回 —— 等价于
      ImageDraw + LANCZOS 缩小的抗锯齿效果，而内存只跟图形大小有关。
      默认 --ss auto: 若整屏 SS 倍画布放得下就用整屏，否则自动用区域超采样。

其它:
    --preview  把若干帧拼成一张 PNG 预览图。
    --cfg      生成配套的 bootanim.cfg（全大写键名）。
    生成后自动用 baanim.AnimFile 回读，逐帧逐像素比对，不一致则非零退出。
"""

from __future__ import annotations

import argparse
import math
import os
import sys

# --- 保证从任意工作目录运行都能 import 到同目录的 baanim ------------------
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

try:
    import numpy as np
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    print("错误: 需要 Pillow 与 numpy 才能运行本脚本", file=sys.stderr)
    raise SystemExit(2)

import baanim  # noqa: E402
from baanim import AnimFile, FormatError, pack, pillow_to_bgrx  # noqa: E402

THEMES = ("dots", "bar")
ACCENT = (0x00, 0x78, 0xD4)      # Windows 11 强调色 #0078D4
DEFAULT_SS = 4                   # 默认超采样倍数
SS_MAX_PIXELS = 9_000_000        # 整屏超采样画布的像素上限
DOT_COUNT = 5                    # 圆点个数
RING_RATIO = 0.06                # 环半径 / 屏幕高度
DOT_RATIO = 0.011                # 点半径 / 屏幕高度
TAIL_POWER = 1.6                 # 追尾效果的衰减指数（越大尾巴越短）
MIN_ALPHA = 0.06                 # 最暗的点也留一点点亮度，尾巴更连续


# ----------------------------------------------------------------------
def die(msg: str, code: int = 2) -> "None":
    print("错误: %s" % msg, file=sys.stderr)
    raise SystemExit(code)


def parse_color(text: str):
    """解析 RRGGBB / #RRGGBB。"""
    s = text.strip().lstrip("#")
    if len(s) != 6 or any(c not in "0123456789abcdefABCDEF" for c in s):
        die("颜色必须是 6 位十六进制 RRGGBB，收到 %r" % text)
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def hexstr(rgb) -> str:
    return "%02X%02X%02X" % rgb


def resolve_ss(ss: int, w: int, h: int) -> int:
    """确定超采样倍数。auto(=0) 时若整屏 SS 倍画布放得下就用整屏，否则区域超采样。"""
    if ss > 0:
        return ss
    if (w * DEFAULT_SS) * (h * DEFAULT_SS) <= SS_MAX_PIXELS:
        return DEFAULT_SS
    return DEFAULT_SS          # 区域超采样不受整屏尺寸限制


# ----------------------------------------------------------------------
# 区域超采样绘制
# ----------------------------------------------------------------------
def blend_patch(dst: np.ndarray, patch: np.ndarray, cx: float, cy: float, ss: int):
    """把 SS 倍超采样的 RGBA patch 平均缩小后，over 合成到 dst 的对应位置。

    dst   整幅帧 (h, w, 3) uint8
    patch 区域画布 (ph*ss, pw*ss, 4) uint8，其中 alpha=0 表示"不画"
    (cx, cy) patch 左上角在整幅帧中的浮点坐标
    """
    ph, pw = patch.shape[0] // ss, patch.shape[1] // ss
    if ph <= 0 or pw <= 0:
        return
    # 块的均值 = 盒式滤波缩小（SS 倍降采样，抗锯齿的来源）
    small = patch.reshape(ph, ss, pw, ss, 4).mean(axis=(1, 3))
    a = small[:, :, 3:4] / 255.0

    x0 = int(round(cx))
    y0 = int(round(cy))
    x1 = min(dst.shape[1], x0 + pw)
    y1 = min(dst.shape[0], y0 + ph)
    x0c = max(0, x0)
    y0c = max(0, y0)
    if x1 <= x0c or y1 <= y0c:
        return
    sub = small[y0c - y0:y1 - y0, x0c - x0:x1 - x0]
    sa = a[y0c - y0:y1 - y0, x0c - x0:x1 - x0]
    region = dst[y0c:y1, x0c:x1].astype(np.float32)
    dst[y0c:y1, x0c:x1] = np.clip(
        region * (1.0 - sa) + sub[:, :, :3] * sa + 0.5, 0, 255).astype(np.uint8)


def draw_antialiased(dst: np.ndarray, cx: float, cy: float, radius: float,
                     color, alpha: int, ss: int):
    """在 (cx, cy) 处画一个半径 radius、透明度 alpha 的抗锯齿实心圆。"""
    if radius <= 0.0 or alpha <= 0:
        return
    # 多留 2 像素余量，保证缩放后不会有半个像素被切掉
    pad = 2.0
    pw = int(math.ceil(radius + pad)) * 2
    ph = pw
    layer = Image.new("RGBA", (pw * ss, ph * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cxs = pw / 2.0 * ss
    cys = ph / 2.0 * ss
    rs = radius * ss
    d.ellipse((cxs - rs, cys - rs, cxs + rs, cys + rs),
              fill=(color[0], color[1], color[2], int(alpha)))
    blend_patch(dst, np.asarray(layer, dtype=np.uint8), cx - pw / 2.0, cy - ph / 2.0, ss)


def draw_round_rect(dst: np.ndarray, x: float, y: float, w: float, h: float,
                    radius: float, color, alpha: int, ss: int):
    """在 (x, y) 处画一个 w x h、圆角 radius、透明度 alpha 的抗锯齿圆角矩形。"""
    if w <= 0 or h <= 0 or alpha <= 0:
        return
    pad = 2.0
    pw = int(math.ceil(w + pad * 2))
    ph = int(math.ceil(h + pad * 2))
    layer = Image.new("RGBA", (pw * ss, ph * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    bx0 = pad * ss
    by0 = pad * ss
    d.rounded_rectangle((bx0, by0, bx0 + w * ss, by0 + h * ss),
                        radius=max(0.0, radius * ss),
                        fill=(color[0], color[1], color[2], int(alpha)))
    blend_patch(dst, np.asarray(layer, dtype=np.uint8), x - pad, y - pad, ss)


# ----------------------------------------------------------------------
# 主题渲染（返回 BGRX 帧字节列表）
# ----------------------------------------------------------------------
def dot_state(t: float):
    """给定位相 t∈[0,1) 返回 (亮度, 缩放)。

    用 sin^TAIL_POWER 做平滑淡入淡出，t→0 与 t→1 取值连续且相等，
    保证循环播放首尾无跳变。刚"出生"的点很暗很小，随后变亮变大再变暗变小，
    相邻点之间因此形成流畅的追尾（彗星）效果。
    """
    b = max(0.0, math.sin(math.pi * t)) ** TAIL_POWER
    alpha = MIN_ALPHA + (1.0 - MIN_ALPHA) * b
    scale = 0.45 + 0.55 * b
    return alpha, scale


def render_dots(w: int, h: int, frames: int, bg, accent, ss: int):
    """dots 主题: 5 个圆点在圆环上公转 + 淡入淡出 + 缩放。"""
    ring = h * RING_RATIO
    dot_r = h * DOT_RATIO
    cx, cy = w / 2.0, h / 2.0
    out = []
    for i in range(frames):
        frame = np.zeros((h, w, 3), dtype=np.uint8)
        frame[:, :] = (bg[0], bg[1], bg[2])
        theta0 = 2.0 * math.pi * (i / frames)   # 角度严格线性 -> 首尾衔接
        # 按亮度从小到大绘制（亮的点后画，压住暗的尾巴）
        order = sorted(range(DOT_COUNT),
                       key=lambda k: dot_state((i / frames + k / DOT_COUNT) % 1.0)[0])
        for k in order:
            t = (i / frames + k / DOT_COUNT) % 1.0
            alpha, scale = dot_state(t)
            theta = theta0 - 2.0 * math.pi * k / DOT_COUNT
            px = cx + ring * math.cos(theta)
            py = cy + ring * math.sin(theta)
            draw_antialiased(frame, px, py, dot_r * scale, accent,
                             int(round(255 * alpha)), ss)
        out.append(pillow_to_bgrx(Image.fromarray(frame, "RGB")))
    return out


def render_bar(w: int, h: int, frames: int, bg, accent, ss: int):
    """bar 主题: 底部细进度条来回扫动。"""
    bar_h = max(2.0, h * 0.010)              # 条高 ≈ 屏高 1%
    track_h = bar_h * 2.4                    # 底槽（很淡的整条轨道）
    bar_w = w * 0.22                         # 扫动条长度
    margin = w * 0.10
    travel = max(1.0, w - 2 * margin - bar_w)
    y_center = h - h * 0.06                  # 位于屏幕底部上方 6% 屏高处
    out = []
    for i in range(frames):
        frame = np.zeros((h, w, 3), dtype=np.uint8)
        frame[:, :] = (bg[0], bg[1], bg[2])
        # (1-cos)/2: 在两端平滑减速换向，速度连续，看不到折角
        s = 0.5 - 0.5 * math.cos(2.0 * math.pi * (i / frames))
        x0 = margin + travel * s
        draw_round_rect(frame, margin, y_center - track_h / 2.0,
                        travel + bar_w, track_h, track_h / 2.0, accent, 38, ss)
        draw_round_rect(frame, x0, y_center - bar_h / 2.0,
                        bar_w, bar_h, bar_h / 2.0, accent, 255, ss)
        out.append(pillow_to_bgrx(Image.fromarray(frame, "RGB")))
    return out


def render(w, h, frames, theme, bg, accent, ss):
    if theme == "dots":
        return render_dots(w, h, frames, bg, accent, ss)
    return render_bar(w, h, frames, bg, accent, ss)


# ----------------------------------------------------------------------
# 预览图 / 配置文件
# ----------------------------------------------------------------------
def write_preview(frames_bgrx, w, h, path, max_tiles=16, tile_w=320):
    """把若干帧拼成一张 PNG 预览图（BGRX -> RGBA 再缩放）。"""
    n = len(frames_bgrx)
    count = min(max_tiles, n)
    if count <= 1:
        idx = [0]
    else:
        idx = sorted({int(round(i * (n - 1) / (count - 1))) for i in range(count)})
    cols = min(4, len(idx))
    rows = (len(idx) + cols - 1) // cols
    gap = 6
    scale = tile_w / w
    tw, th = tile_w, max(1, int(round(h * scale)))
    sheet = Image.new("RGBA", (cols * tw + (cols + 1) * gap,
                               rows * th + (rows + 1) * gap), (24, 24, 24, 255))
    for i, fi in enumerate(idx):
        tile = baanim.bgrx_to_pillow(frames_bgrx[fi], w, h).resize((tw, th), Image.LANCZOS)
        c, r = i % cols, i // cols
        sheet.alpha_composite(tile, (gap + c * (tw + gap), gap + r * (th + gap)))
    d = ImageDraw.Draw(sheet)
    d.text((gap + 2, gap + 2), "theme preview  frame %d..%d / %d" % (idx[0], idx[-1], n),
           fill=(255, 255, 255, 255))
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    sheet.convert("RGB").save(path)
    return len(idx), (sheet.size[0], sheet.size[1])


def write_gif(frames_bgrx, w, h, fps, path, gif_width=640):
    """把整个动画存成一张动图 GIF（可选，仅用于人眼快速确认动态效果）。

    GIF 只有 256 色且体积较大，所以只做降分辨率 + 统一调色板的一次性导出，
    真正的部署文件仍然是 .baa。
    """
    scale = min(1.0, gif_width / w)
    tw, th = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    imgs = [baanim.bgrx_to_pillow(f, w, h).resize((tw, th), Image.LANCZOS).convert("RGB")
            for f in frames_bgrx]
    # 用第一帧生成统一调色板，避免逐帧抖动导致的闪烁
    pal = imgs[0].convert("P", palette=Image.ADAPTIVE, colors=256)
    converted = [im.quantize(palette=pal, dither=Image.NONE) for im in imgs]
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    converted[0].save(path, save_all=True, append_images=converted[1:],
                      duration=max(20, int(round(1000.0 / max(1, fps)))),
                      loop=0, optimize=True)
    return len(converted), (tw, th)


def write_cfg(path, anim_path, frames, fps, bg, theme):
    """生成配套的 bootanim.cfg（键名全大写，ANIM 用相对 cfg 的路径）。"""
    cfg_dir = os.path.dirname(os.path.abspath(path))
    try:
        rel = os.path.relpath(os.path.abspath(anim_path), cfg_dir)
    except ValueError:                      # 跨盘符时退化为绝对路径
        rel = os.path.abspath(anim_path)
    rel = rel.replace("\\", "/")

    lines = [
        "# bootanim.cfg -- 由 tools/make_demo.py 自动生成 (UTF-8)",
        "# 键=值 纯文本，键名全大写，# 开头为注释",
        "",
        "ANIM=%s" % rel,
        "FRAMES=%d" % frames,
        "FPS=%d" % fps,
        "LOOP=1",
        "SCALE=fit",
        "FILTER=bilinear",
        "BACKGROUND=%s" % hexstr(bg),
        "TIMEOUT_MS=0",
        "LEAD_IN_MS=0",
        "SKIP_KEY=ESC",
        "CHAINLOAD=\\EFI\\BOOT\\BOOTX64.EFI",
        "CHAINLOAD_FALLBACK=\\EFI\\Microsoft\\Boot\\bootmgfw.efi",
        "DEBUG=0",
        "VIDEO_MODE=native",
        "CLEAR_FIRST=1",
        "",
        "# 主题: %s" % theme,
    ]
    os.makedirs(cfg_dir or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    return rel


# ----------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="make_demo.py",
        description="程序化生成演示用 UEFI 开机动画 (.baa) + 预览图 + 配置文件",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  python make_demo.py\n"
               "  python make_demo.py --width 640 --height 360 --frames 45 --out dist/small.baa\n"
               "  python make_demo.py --theme bar --frames 90\n")
    p.add_argument("--width", type=int, default=1920, help="宽度，默认 1920")
    p.add_argument("--height", type=int, default=1080, help="高度，默认 1080")
    p.add_argument("--frames", type=int, default=60, help="帧数，默认 60")
    p.add_argument("--fps", type=int, default=30, help="帧率，默认 30")
    p.add_argument("--theme", choices=THEMES, default="dots", help="主题，默认 dots")
    p.add_argument("--bg", default="000000", help="背景色 RRGGBB，默认 000000")
    p.add_argument("--out", default=os.path.join("dist", "anim.baa"), help="输出 .baa")
    p.add_argument("--cfg", default=os.path.join("dist", "bootanim.cfg"), help="输出 cfg")
    p.add_argument("--preview", default=os.path.join("dist", "preview.png"), help="输出预览 PNG")
    p.add_argument("--gif", default=None,
                   help="可选的动图输出路径（如 dist/demo.gif），默认不生成")
    p.add_argument("--no-rle", action="store_true", help="关闭 RLE 压缩")
    p.add_argument("--ss", type=int, default=0,
                   help="超采样倍数，0=auto(默认，区域超采样 4 倍)")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    bg = parse_color(args.bg)

    if args.width <= 0 or args.height <= 0:
        die("尺寸必须为正: %dx%d" % (args.width, args.height))
    if args.width * args.height > baanim.MAX_PIXELS:
        die("尺寸过大: %dx%d (上限 %d 像素)" % (args.width, args.height, baanim.MAX_PIXELS))
    if args.frames < 1 or args.frames > baanim.MAX_FRAMES:
        die("帧数必须在 1..%d 之间，收到 %d" % (baanim.MAX_FRAMES, args.frames))
    if args.fps < 0 or args.fps > 1000:
        die("--fps 必须在 0..1000 之间，收到 %d" % args.fps)
    ss = resolve_ss(args.ss, args.width, args.height)

    print("主题      : %s" % args.theme)
    print("尺寸      : %dx%d" % (args.width, args.height))
    print("帧数      : %d" % args.frames)
    print("fps       : %d" % args.fps)
    print("背景      : #%s   强调色: #%s" % (hexstr(bg), hexstr(ACCENT)))
    print("超采样    : %dx (区域超采样)" % ss)

    frames = render(args.width, args.height, args.frames, args.theme, bg, ACCENT, ss)

    expect = args.width * args.height * 4
    for i, f in enumerate(frames):
        if len(f) != expect:
            die("第 %d 帧字节数 %d != %d" % (i, len(f), expect))

    try:
        blob = pack(frames, args.width, args.height, args.fps, rle=not args.no_rle)
    except FormatError as exc:
        die("打包失败: %s" % exc, 1)

    out_path = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "wb") as fh:
        fh.write(blob)

    size = len(blob)
    raw_total = args.frames * args.width * args.height * 4
    ratio_pct = 100.0 * size / raw_total if raw_total else 0.0
    print("输出      : %s" % out_path)
    print("文件大小  : %d 字节 (%.2f MiB)" % (size, size / 1048576.0))
    print("原始大小  : %d 字节 (%.2f MiB)" % (raw_total, raw_total / 1048576.0))
    print("压缩比    : %.2f%%（节省 %.2f%%）" % (ratio_pct, 100.0 - ratio_pct))
    print("平均每帧  : %.1f 字节 (%.2f KiB)" % (size / args.frames, size / args.frames / 1024.0))

    # ---------------- 回读校验（逐帧逐像素） ----------------
    try:
        with open(out_path, "rb") as fh:
            a = AnimFile(fh.read())
    except FormatError as exc:
        die("回读校验失败: %s" % exc, 1)
    if (a.frame_count, a.width, a.height, a.fps) != (args.frames, args.width, args.height, args.fps):
        die("回读校验失败: 头部字段不一致 "
            "(frames=%d w=%d h=%d fps=%d)" % (a.frame_count, a.width, a.height, a.fps), 1)
    bad = 0
    for i in range(a.frame_count):
        if a.frame(i) != frames[i]:
            bad += 1
            if bad <= 3:
                print("  第 %d 帧像素不一致" % i, file=sys.stderr)
    if bad:
        die("回读校验失败: %d/%d 帧像素不一致" % (bad, a.frame_count), 1)
    print("回读校验  : OK（%d 帧逐像素一致，rle=%s）"
          % (a.frame_count, "yes" if a.rle else "no"))

    # ---------------- 配置文件 ----------------
    cfg_path = os.path.abspath(args.cfg)
    rel = write_cfg(cfg_path, out_path, args.frames, args.fps, bg, args.theme)
    print("配置文件  : %s (ANIM=%s)" % (cfg_path, rel))

    # ---------------- 预览图 ----------------
    if args.preview:
        prev_path = os.path.abspath(args.preview)
        tiles, _ = write_preview(frames, args.width, args.height, prev_path)
        try:                                  # 立刻回读预览图，确认 PNG 合法
            with Image.open(prev_path) as chk:
                chk.load()
                psize, pmode = chk.size, chk.mode
        except Exception as exc:  # noqa: BLE001
            die("预览图回读失败: %s" % exc, 1)
        print("预览图    : %s (%d 格, %dx%d, %s)"
              % (prev_path, tiles, psize[0], psize[1], pmode))

    # ---------------- 可选动图 ----------------
    if args.gif:
        gif_path = os.path.abspath(args.gif)
        gframes, gdim = write_gif(frames, args.width, args.height, args.fps, gif_path)
        print("动图      : %s (%d 帧, %dx%d, %.1f KiB)"
              % (gif_path, gframes, gdim[0], gdim[1], os.path.getsize(gif_path) / 1024.0))

    print("完成      : 可直接测试")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("已中断", file=sys.stderr)
        raise SystemExit(130)
