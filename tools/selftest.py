#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# -*- coding: utf-8 -*-
"""
selftest.py -- 对 baanim.py 的格式实现做全面自检。

内容:
  1. RLE 编解码往返（多种图案: 纯色 / 长游程 / 噪声 / 渐变 / 边界长度）
  2. pack/parse 整体往返
  3. 损坏文件模糊测试（截断 / 追加 / 随机翻位 / 索引越界）—— 只允许
     抛出 FormatError，绝不允许崩溃、死循环或越界写
  4. 与 Pillow 的 BGRX 互转一致性（若可用）
  5. 生成 tools/_testdata/ 下的样例 .baa 供 C 端自测使用

用法: python selftest.py
"""

from __future__ import annotations

import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import baanim  # noqa: E402
from baanim import (AnimFile, FormatError, FLAG_RLE, HEADER_SIZE,  # noqa: E402
                    MAX_PIXELS, pack, rle_decode, rle_encode)

PASS = 0
FAIL = 0


def check(cond: bool, what: str) -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        print("  FAIL: %s" % what)


def expect_error(fn, what: str) -> None:
    global PASS, FAIL
    try:
        fn()
    except FormatError:
        PASS += 1
    except Exception as exc:  # noqa: BLE001
        FAIL += 1
        print("  FAIL: %s -> wrong exception %r" % (what, exc))
    else:
        FAIL += 1
        print("  FAIL: %s -> expected FormatError, got none" % what)


# ----------------------------------------------------------------------
def make_patterns(npix: int, rng: random.Random) -> dict:
    pats = {}
    pats["solid"] = bytes((1, 2, 3, 0)) * npix
    pats["twocolor"] = b"".join(
        (bytes((10, 20, 30, 0)) if (i // 7) % 2 else bytes((40, 50, 60, 0)))
        for i in range(npix))
    pats["noise"] = bytes(rng.randrange(256) for _ in range(npix * 4))
    grad = bytearray()
    for i in range(npix):
        v = (i * 255) // max(1, npix - 1) if npix > 1 else 0
        grad += bytes((v, 255 - v, (v * 3) & 0xFF, 0))
    pats["gradient"] = bytes(grad)
    if npix >= 4:
        pats["mixed"] = (b"\xAA\xBB\xCC\x00" * 3 + pats["noise"][:max(0, (npix - 3) * 4)])
        pats["mixed"] = pats["mixed"][:npix * 4]
        if len(pats["mixed"]) != npix * 4:
            pats["mixed"] = (pats["mixed"] + b"\x00" * (npix * 4))[:npix * 4]
    return pats


def test_rle() -> None:
    print("[1] RLE roundtrip")
    rng = random.Random(20240517)
    for npix in (1, 2, 3, 4, 5, 127, 128, 129, 130, 255, 256, 257, 1000, 4096):
        for name, data in make_patterns(npix, rng).items():
            enc = rle_encode(data)
            dec, used = rle_decode(enc, npix)
            check(dec == data, "rle roundtrip npix=%d pat=%s" % (npix, name))
            check(used <= len(enc), "rle used<=len npix=%d pat=%s" % (npix, name))

    # 长游程必须被压缩
    long_run = bytes((9, 9, 9, 0)) * 300
    enc = rle_encode(long_run)
    check(len(enc) < len(long_run) // 10, "long run compresses (%d -> %d)" % (len(long_run), len(enc)))
    check(rle_decode(enc, 300)[0] == long_run, "long run roundtrip")
    # 129 是单包上限
    check(len(rle_encode(bytes((7, 7, 7, 0)) * 129)) == 5, "run of 129 -> 1 packet")
    check(len(rle_encode(bytes((7, 7, 7, 0)) * 130)) == 10, "run of 130 -> 2 packets")


def test_pack() -> None:
    print("[2] pack / parse roundtrip")
    rng = random.Random(4242)
    w, h, n = 37, 19, 5
    npix = w * h
    frames = [make_patterns(npix, rng)["noise"] for _ in range(n)]
    frames[1] = bytes((0, 0, 0, 0)) * npix
    frames[3] = make_patterns(npix, rng)["gradient"]
    blob = pack(frames, w, h, 30, rle=True)
    a = AnimFile(blob)
    inf = a.info()
    check((inf.frame_count, inf.width, inf.height, inf.fps) == (n, w, h, 30), "header fields")
    check(inf.rle is True, "rle flag")
    for i in range(n):
        check(a.frame(i) == frames[i], "frame %d roundtrip" % i)

    blob2 = pack(frames, w, h, 25, rle=False)
    a2 = AnimFile(blob2)
    check(a2.info().rle is False, "raw flag")
    for i in range(n):
        check(a2.frame(i) == frames[i], "raw frame %d roundtrip" % i)
    check(len(blob2) == HEADER_SIZE + n * 8 + n * npix * 4 + sum((-npix * 4) % 4 for _ in range(n)),
          "raw file size")

    # 尺寸不符必须报错
    expect_error(lambda: pack([frames[0][:-4]], w, h, 30), "pack size mismatch")
    expect_error(lambda: pack([], w, h, 30), "pack no frames")
    expect_error(lambda: pack(frames, 0, h, 30), "pack zero width")
    expect_error(lambda: pack(frames, w, h, 100000), "pack bad fps")


def test_corruption() -> None:
    print("[3] corruption fuzz")
    rng = random.Random(99)
    w, h = 16, 16
    npix = w * h
    good = pack([make_patterns(npix, rng)["noise"] for _ in range(3)], w, h, 30, rle=True)

    # 截断：只要切掉了任何一个索引条目覆盖到的字节就必须报错；
    # 只丢掉尾部对齐填充仍应能正常解码。
    a_good = AnimFile(good)
    required = max(off + size for off, size in a_good._index)
    check(required <= len(good), "index fits in file")
    for cut in range(0, len(good), 7):
        blob = good[:cut]

        def f(b=blob):
            a = AnimFile(b)
            for i in range(a.frame_count):
                a.frame(i)
        if cut < required:
            expect_error(f, "truncated at %d (required %d)" % (cut, required))
        else:
            f()   # 仅丢失填充，允许成功

    # 随机翻位后必须不崩溃（要么正常解码要么 FormatError）
    crashes = 0
    for _ in range(3000):
        b = bytearray(good)
        for _ in range(rng.randrange(1, 6)):
            b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
        try:
            a = AnimFile(bytes(b))
            for i in range(a.frame_count):
                a.frame(i)
        except FormatError:
            pass
        except MemoryError:
            crashes += 1
        except Exception as exc:  # noqa: BLE001
            crashes += 1
            print("    unexpected %r" % exc)
    check(crashes == 0, "bitflip fuzz produced no unexpected exceptions")

    # 头部字段攻击
    def mutate(off: int, val: int) -> bytes:
        b = bytearray(good)
        struct.pack_into("<I", b, off, val)
        return bytes(b)

    # frameCount 调小是合法的（只是少解析几帧），其余字段的极端值必须报错
    for off, name, vals in ((8, "headerSize", (0, 1, 0x7FFFFFFF, 0xFFFFFFFF)),
                            (12, "frameCount", (0, 0x7FFFFFFF, 0xFFFFFFFF)),
                            (16, "width", (0, 1, 0x7FFFFFFF, 0xFFFFFFFF)),
                            (20, "height", (0, 1, 0x7FFFFFFF, 0xFFFFFFFF))):
        for val in vals:
            blob = mutate(off, val)

            def f(b=blob):
                a = AnimFile(b)
                for i in range(a.frame_count):
                    a.frame(i)
            expect_error(f, "header %s=%d" % (name, val))
    # 合法的裁剪只解析前 1 帧
    a1 = AnimFile(mutate(12, 1))
    check(a1.frame_count == 1 and a1.frame(0) == AnimFile(good).frame(0), "frameCount=1 truncation valid")

    # 保留字段必须为 0
    expect_error(lambda: AnimFile(mutate(32, 1)), "reserved != 0")
    # 魔数
    bad = bytearray(good)
    bad[0:8] = b"XXXXXXXX"
    expect_error(lambda: AnimFile(bytes(bad)), "bad magic")
    # 索引越界
    b = bytearray(good)
    struct.pack_into("<II", b, HEADER_SIZE, 0xFFFFFF00, 16)
    expect_error(lambda: AnimFile(bytes(b)), "index out of range")
    # headerSize 小于 64
    expect_error(lambda: AnimFile(mutate(8, 32)), "headerSize < 64")


def test_pillow() -> None:
    print("[4] Pillow interop")
    try:
        from PIL import Image
    except ImportError:
        print("  (Pillow 不可用，跳过)")
        return
    rng = random.Random(7)
    w, h = 23, 11
    img = Image.new("RGBA", (w, h))
    px = [(rng.randrange(256), rng.randrange(256), rng.randrange(256), 255)
          for _ in range(w * h)]
    img.putdata(px)
    bgrx = baanim.pillow_to_bgrx(img)
    check(len(bgrx) == w * h * 4, "bgrx length")
    for i, (r, g, b, _a) in enumerate(px):
        check(bgrx[i * 4:i * 4 + 4] == bytes((b, g, r, 255)), "pixel %d order" % i)
    back = baanim.bgrx_to_pillow(bgrx, w, h)
    want = bytearray()
    for (r, g, b, a) in px:
        want += bytes((r, g, b, a))
    check(back.tobytes() == bytes(want), "pillow roundtrip")
    # 存一份 24 位 BMP 供 C 端 BMP 解码器自测
    os.makedirs(TESTDIR, exist_ok=True)
    tmp = os.path.join(TESTDIR, "pillow_check.bmp")
    img.convert("RGB").save(tmp)
    re2 = Image.open(tmp).convert("RGBA")
    check(baanim.pillow_to_bgrx(re2) == bgrx, "bmp reload bgrx identical")


def test_emit_fixtures() -> None:
    print("[5] emit fixtures for C self-test")
    rng = random.Random(31337)
    os.makedirs(TESTDIR, exist_ok=True)

    # (a) 20 帧 64x48 演示帧，带 RLE
    w, h, n = 64, 48, 20
    frames = []
    for f in range(n):
        buf = bytearray()
        for y in range(h):
            for x in range(w):
                r = (x * 4 + f * 12) & 0xFF
                g = (y * 5 + f * 7) & 0xFF
                b = (f * 13) & 0xFF
                if (x // 8 + y // 8 + f) % 7 == 0:
                    r = g = b = 255
                buf += bytes((b, g, r, 0))
        frames.append(bytes(buf))
    blob = pack(frames, w, h, 24, rle=True)
    p = os.path.join(TESTDIR, "test_rle.baa")
    with open(p, "wb") as fh:
        fh.write(blob)
    print("  %s (%d bytes)" % (p, len(blob)))

    # (b) 同内容不压缩
    blob2 = pack(frames, w, h, 24, rle=False)
    p2 = os.path.join(TESTDIR, "test_raw.baa")
    with open(p2, "wb") as fh:
        fh.write(blob2)
    print("  %s (%d bytes)" % (p2, len(blob2)))

    # (c) 纯噪声（RLE 几乎无效，测试字面量包边界）
    nz = pack([bytes(rng.randrange(256) for _ in range(w * h * 4)) for _ in range(3)],
              w, h, 30, rle=True)
    p3 = os.path.join(TESTDIR, "test_noise.baa")
    with open(p3, "wb") as fh:
        fh.write(nz)
    print("  %s (%d bytes)" % (p3, len(nz)))

    # (d) 参考解码结果，供 C 端逐字节比对
    with open(os.path.join(TESTDIR, "test_rle.expected"), "wb") as fh:
        for f in frames:
            fh.write(f)
    print("  test_rle.expected (%d bytes)" % (len(frames) * w * h * 4))


def test_emit_bmp_fixtures() -> None:
    """为 C 端 BMP 解码器生成 .bmp + 期望的 BGRX 原始数据。"""
    print("[6] emit BMP fixtures for C self-test")
    try:
        from PIL import Image
    except ImportError:
        print("  (Pillow 不可用，跳过)")
        return
    os.makedirs(TESTDIR, exist_ok=True)
    rng = random.Random(20240518)

    cases = []
    for name, mode, w, h in (
        ("bmp24", "RGB", 37, 19),      # 24 位，自下而上（BMP 默认）
        ("bmp32", "RGBA", 23, 11),     # 32 位 BGRA
        ("bmp8", "P", 29, 13),         # 8 位调色板
        ("bmp1", "1", 17, 9),          # 1 位黑白
    ):
        img = Image.new(mode, (w, h))
        if mode == "P":
            pal = []
            for _ in range(256):
                pal += [rng.randrange(256), rng.randrange(256), rng.randrange(256)]
            img.putpalette(pal)
            img.putdata([rng.randrange(256) for _ in range(w * h)])
        elif mode == "1":
            img.putdata([rng.randrange(2) for _ in range(w * h)])
        else:
            img.putdata([tuple(rng.randrange(256) for _ in range(len(mode)))
                         for _ in range(w * h)])

        # 存成 BMP 时统一转成 RGB/RGBA/调色板/1位，保持位深不被 Pillow 改变
        if mode == "P":
            save_img = img.convert("P", palette=Image.ADAPTIVE, colors=256)
        else:
            save_img = img
        bmp_path = os.path.join(TESTDIR, name + ".bmp")
        save_img.save(bmp_path)

        # 用 Pillow 重新读回来（和 C 端看到的是同一个文件），生成期望的 BGRX
        reload = Image.open(bmp_path)
        bgrx = baanim.pillow_to_bgrx(reload)
        with open(os.path.join(TESTDIR, name + ".bgrx"), "wb") as fh:
            fh.write(bgrx)
        cases.append((name, reload.size[0], reload.size[1], len(bgrx)))
        print("  %-6s %2dx%-3d bmp=%6d B  bgrx=%6d B"
              % (name, reload.size[0], reload.size[1],
                 os.path.getsize(bmp_path), len(bgrx)))

    # 一份配置样例（C 端解析后应有相同的取值）
    cfg = """# host test sample
ANIM=anim.baa
FRAMES=0
FPS=24
LOOP=1
SCALE=fill
FILTER=nearest
BACKGROUND=123456
TIMEOUT_MS=9000
LEAD_IN_MS=50
SKIP_KEY=off
PACING=fixed
DEBUG=1
CLEAR_FIRST=0
VIDEO_MODE=1024x768
CHAINLOAD=\\EFI\\Microsoft\\Boot\\bootmgfw-orig.efi
CHAINLOAD_FALLBACK=\\EFI\\Microsoft\\Boot\\bootmgfw.efi
UNKNOWN_KEY=whatever
"""
    cfg_path = os.path.join(TESTDIR, "sample.cfg")
    with open(cfg_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(cfg)
    print("  %s (%d bytes)" % (cfg_path, len(cfg.encode("utf-8"))))


TESTDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_testdata")


def main() -> int:
    print("baanim selftest  (MAX_PIXELS=%d)" % MAX_PIXELS)
    test_rle()
    test_pack()
    test_corruption()
    test_pillow()
    test_emit_fixtures()
    test_emit_bmp_fixtures()
    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
