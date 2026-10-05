#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# -*- coding: utf-8 -*-
"""
baanim.py -- BAANIM01 帧容器格式的参考实现（编码器 + 解码器）。

这个文件是整个项目里 **唯一被实际执行验证过** 的格式契约：
C 端 (src/BaImage.c) 的 BaBaaOpen / BaBaaReadFrame / BaRleDecode 必须与这里的
解码逻辑逐字节等价（包括错误行为）。

======================================================================
文件布局 (全部小端序 little-endian)
======================================================================

 偏移   大小                内容
 ----   ------------------  ------------------------------------------
 0      8                   magic = b"BAANIM01"
 8      4  u32              headerSize   = 64
 12     4  u32              frameCount   帧数 (>=1)
 16     4  u32              width        像素宽
 20     4  u32              height       像素高
 24     4  u32              fps          建议帧率 (0 = 由配置文件决定)
 28     4  u32              flags        bit0: 帧数据经过 RLE 压缩
 32     32 u32 reserved[8]  必须为 0
 64     frameCount*8        帧索引: { u32 offset, u32 size } (offset 相对文件头)
 64+idx frameCount*size     帧数据 (每帧按 4 字节对齐填充)

每帧原始数据 = width*height*4 字节，像素顺序 BGRX
(byte0 = Blue, byte1 = Green, byte2 = Red, byte3 = 0)，
与 UEFI GOP 的 PixelBlueGreenRedReserved8BitPerColor 完全一致，
所以最常见的路径可以整行 memcpy，不需要逐像素转换。

======================================================================
RLE 包流 (flags.bit0 = 1 时)
======================================================================
解码出一个长度恰好为 width*height 的 BGRX 像素序列：

  读入 1 字节控制码 c
    c <  0x80 : 字面量包，后面紧跟 (c + 1) 个像素(每个 4 字节)，原样输出
    c >= 0x80 : 重复包，后面紧跟 1 个像素(4 字节)，重复 (c - 0x80 + 2) 次
                次数范围 2..129

约束（C 端必须同样处理，否则视为损坏）：
  * 输出满 width*height 像素之前包流结束  -> 错误 (截断)
  * 某个包会输出超过 width*height 像素    -> 错误 (溢出)
  * 恰好输出满即停止，之后的剩余字节被忽略
"""

from __future__ import annotations

import os
import struct
import sys
from dataclasses import dataclass
from typing import List, Sequence, Tuple

MAGIC = b"BAANIM01"
HEADER_SIZE = 64
HEADER_STRUCT = struct.Struct("<8sIIIIII8I")   # 8 + 6*4 + 8*4 = 64
INDEX_STRUCT = struct.Struct("<II")            # offset, size
FLAG_RLE = 0x00000001

MAX_PIXELS = 8192 * 8192
MAX_FRAMES = 100000

E_BAD_MAGIC = "bad magic"
E_TRUNCATED = "truncated"
E_RLE_OVERRUN = "rle overrun"
E_RLE_UNDERRUN = "rle underrun"


class FormatError(Exception):
    """文件结构不合法。"""


# ----------------------------------------------------------------------
# RLE
# ----------------------------------------------------------------------
def rle_encode(pixels: bytes) -> bytes:
    """把 BGRX 像素流编码成包流。"""
    if len(pixels) % 4:
        raise FormatError("pixel buffer not multiple of 4")
    n = len(pixels) // 4

    def px(idx: int) -> bytes:
        return pixels[idx * 4:idx * 4 + 4]

    def run_len(i: int) -> int:
        cur = px(i)
        r = 1
        while i + r < n and r < 129 and px(i + r) == cur:
            r += 1
        return r

    out = bytearray()
    i = 0
    while i < n:
        if run_len(i) >= 3:
            r = run_len(i)
            out.append(0x80 + (r - 2))
            out += px(i)
            i += r
            continue
        start = i
        while i < n and (i - start) < 128:
            if run_len(i) >= 3:
                break
            i += 1
        if i == start:            # 理论上不可达（上面已保证 run_len(start) < 3）
            i += 1
        cnt = i - start
        out.append(cnt - 1)
        out += pixels[start * 4:i * 4]
    return bytes(out)


def rle_decode(data: bytes, npixels: int) -> Tuple[bytes, int]:
    """把包流解码成 npixels 个 BGRX 像素。严格校验边界。

    返回 (像素数据, 消耗的输入字节数)。出错抛 FormatError。
    """
    total = npixels * 4
    out = bytearray()
    pos = 0
    n = len(data)
    while len(out) < total:
        if pos >= n:
            raise FormatError(E_RLE_UNDERRUN)
        c = data[pos]
        pos += 1
        if c < 0x80:
            cnt = c + 1
            need = cnt * 4
            if pos + need > n:
                raise FormatError(E_TRUNCATED)
            if len(out) + need > total:
                raise FormatError(E_RLE_OVERRUN)
            out += data[pos:pos + need]
            pos += need
        else:
            cnt = c - 0x80 + 2
            if pos + 4 > n:
                raise FormatError(E_TRUNCATED)
            if len(out) + cnt * 4 > total:
                raise FormatError(E_RLE_OVERRUN)
            out += data[pos:pos + 4] * cnt
            pos += 4
    return bytes(out), pos


# ----------------------------------------------------------------------
# 打包 / 解析
# ----------------------------------------------------------------------
def pack(frames: Sequence[bytes], width: int, height: int, fps: int,
         rle: bool = True, pad: bool = True) -> bytes:
    """把一组 BGRX 帧打包成 .baa 字节流。"""
    if not frames:
        raise FormatError("no frames")
    if len(frames) > MAX_FRAMES:
        raise FormatError("too many frames")
    if width <= 0 or height <= 0 or width * height > MAX_PIXELS:
        raise FormatError("bad dimensions")
    if not (0 <= fps <= 1000):
        raise FormatError("bad fps")
    expect = width * height * 4
    for i, f in enumerate(frames):
        if len(f) != expect:
            raise FormatError("frame %d size %d != %d" % (i, len(f), expect))

    payloads = [rle_encode(f) if rle else f for f in frames]

    offset = HEADER_SIZE + len(payloads) * INDEX_STRUCT.size
    index = bytearray()
    data = bytearray()
    for p in payloads:
        index += INDEX_STRUCT.pack(offset, len(p))
        data += p
        offset += len(p)
        if pad:
            padn = (-len(p)) % 4
            if padn:
                data += b"\x00" * padn
                offset += padn

    flags = FLAG_RLE if rle else 0
    header = HEADER_STRUCT.pack(MAGIC, HEADER_SIZE, len(frames), width, height,
                                fps, flags, *([0] * 8))
    return bytes(header) + bytes(index) + bytes(data)


@dataclass
class AnimInfo:
    frame_count: int
    width: int
    height: int
    fps: int
    flags: int
    rle: bool
    file_size: int


class AnimFile:
    """已解析的 .baa 文件（惰性解码单帧）。"""

    def __init__(self, blob: bytes):
        self.blob = blob
        if len(blob) < HEADER_SIZE:
            raise FormatError(E_TRUNCATED)
        (magic, header_size, fcount, width, height, fps, flags,
         *reserved) = HEADER_STRUCT.unpack_from(blob, 0)
        if magic != MAGIC:
            raise FormatError(E_BAD_MAGIC)
        if header_size < HEADER_SIZE or header_size > len(blob):
            raise FormatError("bad headerSize")
        if fcount == 0 or fcount > MAX_FRAMES:
            raise FormatError("bad frameCount")
        if width == 0 or height == 0 or width * height > MAX_PIXELS:
            raise FormatError("bad dimensions")
        if header_size + fcount * INDEX_STRUCT.size > len(blob):
            raise FormatError(E_TRUNCATED)
        if any(reserved):
            raise FormatError("reserved not zero")

        self.header_size = header_size
        self.frame_count = fcount
        self.width = width
        self.height = height
        self.fps = fps
        self.flags = flags
        self.rle = bool(flags & FLAG_RLE)

        raw = width * height * 4
        self._index: List[Tuple[int, int]] = []
        for i in range(fcount):
            off, size = INDEX_STRUCT.unpack_from(blob, header_size + i * INDEX_STRUCT.size)
            if off > len(blob) or size > len(blob) or off + size > len(blob):
                raise FormatError("frame %d out of range" % i)
            if not self.rle and size != raw:
                raise FormatError("frame %d raw size mismatch" % i)
            self._index.append((off, size))

    def info(self) -> AnimInfo:
        return AnimInfo(self.frame_count, self.width, self.height, self.fps,
                        self.flags, self.rle, len(self.blob))

    def frame_payload(self, i: int) -> bytes:
        off, size = self._index[i]
        return self.blob[off:off + size]

    def frame(self, i: int) -> bytes:
        """返回解码后的 BGRX 帧 (width*height*4 字节)。"""
        payload = self.frame_payload(i)
        if not self.rle:
            return payload
        return rle_decode(payload, self.width * self.height)[0]


# ----------------------------------------------------------------------
# 与 Pillow / 裸字节的互转
# ----------------------------------------------------------------------
def pillow_to_bgrx(img) -> bytes:
    """PIL.Image -> BGRX 字节流（RGBA 输入，忽略 alpha 并置 0xFF）。"""
    if img.mode != "RGBA":
        img = img.convert("RGBA")
    raw = img.tobytes()
    n = len(raw) // 4
    out = bytearray(len(raw))
    out[0::4] = raw[2::4]   # B
    out[1::4] = raw[1::4]   # G
    out[2::4] = raw[0::4]   # R
    out[3::4] = b"\xff" * n
    return bytes(out)


def bgrx_to_pillow(data: bytes, width: int, height: int):
    from PIL import Image
    n = width * height
    raw = bytearray(len(data))
    raw[0::4] = data[2::4]  # R
    raw[1::4] = data[1::4]  # G
    raw[2::4] = data[0::4]  # B
    raw[3::4] = data[3::4]
    return Image.frombytes("RGBA", (width, height), bytes(raw))


# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------
def _cmd_info(path: str) -> int:
    with open(path, "rb") as fh:
        a = AnimFile(fh.read())
    inf = a.info()
    raw_total = inf.frame_count * inf.width * inf.height * 4
    print("file      : %s" % path)
    print("size      : %d bytes (%.2f MiB)" % (inf.file_size, inf.file_size / 1048576.0))
    print("frames    : %d" % inf.frame_count)
    print("dimension : %dx%d" % (inf.width, inf.height))
    print("fps       : %d" % inf.fps)
    print("rle       : %s" % ("yes" if inf.rle else "no"))
    print("raw total : %d bytes (%.2f MiB)" % (raw_total, raw_total / 1048576.0))
    if raw_total:
        print("ratio     : %.1f%%" % (100.0 * inf.file_size / raw_total))
    for i in range(min(inf.frame_count, 8)):
        off, size = a._index[i]
        print("  frame[%d] off=%d size=%d" % (i, off, size))
    if inf.frame_count > 8:
        print("  ...")
    for i in range(inf.frame_count):
        a.frame(i)
    print("decode    : OK (all %d frames)" % inf.frame_count)
    return 0


def _cmd_extract(path: str, outdir: str, fmt: str = "bmp") -> int:
    with open(path, "rb") as fh:
        a = AnimFile(fh.read())
    os.makedirs(outdir, exist_ok=True)
    for i in range(a.frame_count):
        data = a.frame(i)
        name = os.path.join(outdir, "frame%04d.%s" % (i, fmt))
        if fmt == "bmp":
            bgrx_to_pillow(data, a.width, a.height).save(name)
        else:
            with open(name, "wb") as fh:
                fh.write(data)
        print("wrote %s" % name)
    return 0


def main(argv: Sequence[str]) -> int:
    if len(argv) < 3 or argv[1] not in ("info", "extract"):
        print("usage: baanim.py info <file.baa>")
        print("       baanim.py extract <file.baa> <outdir> [bmp|raw]")
        return 2
    try:
        if argv[1] == "info":
            return _cmd_info(argv[2])
        return _cmd_extract(argv[2], argv[3], argv[4] if len(argv) > 4 else "bmp")
    except FormatError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
