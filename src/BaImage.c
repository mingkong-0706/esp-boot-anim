/** @file
  BaImage.c -- 纯逻辑图像模块：BMP 解码 / BAANIM01 帧解码 / 缩放采样。

  本文件不依赖任何系统头文件或 UEFI，可直接在 PC 上编译做单元测试。

  与 tools/baanim.py 的对应关系（必须逐字节等价，含错误行为）：
      BaRleDecode        <-> baanim.rle_decode
      BaBaaParseHeader   <-> baanim.AnimFile.__init__
      BaBaaFrameLoc      <-> baanim.AnimFile._index
      BaBaaDecodeFrame   <-> baanim.AnimFile.frame

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#include "Ba.h"

/* ================================================================== */
/* 小端序读取                                                         */
/* ================================================================== */
static BA_U32
BaRdU32 (
  const BA_U8 *P
  )
{
  return (BA_U32)P[0]
         | ((BA_U32)P[1] << 8)
         | ((BA_U32)P[2] << 16)
         | ((BA_U32)P[3] << 24);
}

static BA_U16
BaRdU16 (
  const BA_U8 *P
  )
{
  return (BA_U16)((BA_U32)P[0] | ((BA_U32)P[1] << 8));
}

/* ================================================================== */
/* 内存填充                                                           */
/* ================================================================== */
void
BaImageFillBgrx (
  BA_U8  *Dst,
  BA_U32  W,
  BA_U32  H,
  BA_U32  Stride,
  BA_U32  Bgrx
  )
{
  BA_U32 Y;
  BA_U32 X;
  BA_U8  B0 = (BA_U8)(Bgrx & 0xFF);
  BA_U8  B1 = (BA_U8)((Bgrx >> 8) & 0xFF);
  BA_U8  B2 = (BA_U8)((Bgrx >> 16) & 0xFF);
  BA_U8  B3 = (BA_U8)((Bgrx >> 24) & 0xFF);

  if (Dst == BA_NULL) {
    return;
  }
  for (Y = 0; Y < H; Y++) {
    BA_U8 *Row = Dst + (BA_SIZE)Y * Stride;
    for (X = 0; X < W; X++) {
      Row[0] = B0;
      Row[1] = B1;
      Row[2] = B2;
      Row[3] = B3;
      Row   += 4;
    }
  }
}

/* ================================================================== */
/* BAANIM01 的 RLE 解码                                               */
/* ================================================================== */
BA_STATUS
BaRleDecode (
  const BA_U8 *Src,
  BA_SIZE      SrcSize,
  BA_U8       *Dst,
  BA_SIZE      DstSize,
  BA_SIZE     *Used
  )
{
  BA_SIZE Out = 0;
  BA_SIZE Pos = 0;

  if ((Src == BA_NULL) || (Dst == BA_NULL)) {
    return BA_ERR_INVALID;
  }
  if ((DstSize & 3u) != 0) {
    return BA_ERR_INVALID;
  }
  if (Used != BA_NULL) {
    *Used = 0;
  }

  while (Out < DstSize) {
    BA_U8   C;
    BA_SIZE Cnt;
    BA_SIZE Need;
    BA_SIZE K;

    if (Pos >= SrcSize) {
      return BA_ERR_RLE;              /* 包流提前结束 */
    }
    C = Src[Pos];
    Pos++;

    if (C < 0x80u) {
      /* 字面量包：C+1 个像素 */
      Cnt  = (BA_SIZE)C + 1;
      Need = Cnt * 4;
      if (Pos + Need > SrcSize) {
        return BA_ERR_TRUNCATED;
      }
      if (Out + Need > DstSize) {
        return BA_ERR_RLE;            /* 会写越界 */
      }
      BaMemCopy (Dst + Out, Src + Pos, Need);
      Pos += Need;
      Out += Need;
    } else {
      /* 重复包：像素重复 (C-0x80+2) 次。
         用 32 位写入代替 4 次字节写入 —— 1920x1080 一帧有 200 万像素，
         这个循环是整个解码里最热的地方。Out 始终是 4 的倍数，对齐安全。 */
      BA_U32  Px;
      BA_U32 *D32;

      Cnt  = (BA_SIZE)C - 0x80u + 2u;
      Need = Cnt * 4;
      if (Pos + 4 > SrcSize) {
        return BA_ERR_TRUNCATED;
      }
      if (Out + Need > DstSize) {
        return BA_ERR_RLE;
      }
      Px = (BA_U32)Src[Pos]
           | ((BA_U32)Src[Pos + 1] << 8)
           | ((BA_U32)Src[Pos + 2] << 16)
           | ((BA_U32)Src[Pos + 3] << 24);
      Pos += 4;
      D32 = (BA_U32 *)(void *)(Dst + Out);
      for (K = 0; K < Cnt; K++) {
        D32[K] = Px;
      }
      Out += Need;
    }
  }

  if (Used != BA_NULL) {
    *Used = Pos;
  }
  return BA_OK;
}

/* ================================================================== */
/* BAANIM01 头 / 索引 / 帧                                            */
/* ================================================================== */
BA_STATUS
BaBaaParseHeader (
  const BA_U8   *Hdr,
  BA_SIZE        Size,
  BA_BAA_HEADER *Out
  )
{
  BA_U32 I;

  if ((Hdr == BA_NULL) || (Out == BA_NULL)) {
    return BA_ERR_INVALID;
  }
  if (Size < BA_BAA_HEADER_MIN) {
    return BA_ERR_TRUNCATED;
  }
  if (BaMemCmp (Hdr, BA_BAA_MAGIC, 8) != 0) {
    return BA_ERR_FORMAT;
  }

  Out->HeaderSize = BaRdU32 (Hdr + 8);
  Out->FrameCount = BaRdU32 (Hdr + 12);
  Out->Width      = BaRdU32 (Hdr + 16);
  Out->Height     = BaRdU32 (Hdr + 20);
  Out->Fps        = BaRdU32 (Hdr + 24);
  Out->Flags      = BaRdU32 (Hdr + 28);

  if (Out->HeaderSize < BA_BAA_HEADER_MIN) {
    return BA_ERR_FORMAT;
  }
  if (Out->HeaderSize > Size) {
    return BA_ERR_FORMAT;
  }
  if ((Out->FrameCount == 0) || (Out->FrameCount > BA_MAX_FRAMES)) {
    return BA_ERR_FORMAT;
  }
  if ((Out->Width == 0) || (Out->Height == 0)) {
    return BA_ERR_FORMAT;
  }
  if ((BA_U64)Out->Width * (BA_U64)Out->Height > (BA_U64)BA_MAX_PIXELS) {
    return BA_ERR_TOO_BIG;
  }
  /* 索引必须完整落在文件内 */
  if ((BA_U64)Out->HeaderSize + (BA_U64)Out->FrameCount * 8u > (BA_U64)Size) {
    return BA_ERR_TRUNCATED;
  }
  /* 保留字段必须为 0 */
  for (I = 0; I < 8; I++) {
    if (BaRdU32 (Hdr + 32 + I * 4) != 0) {
      return BA_ERR_FORMAT;
    }
  }

  return BA_OK;
}

BA_STATUS
BaBaaFrameLoc (
  const BA_U8        *IdxEntry,
  BA_SIZE             IdxSize,
  BA_SIZE             FileSize,
  const BA_BAA_HEADER *Hdr,
  BA_U32              Index,
  BA_U64             *Offset,
  BA_U32             *Length
  )
{
  BA_U32 Off;
  BA_U32 Len;

  if ((IdxEntry == BA_NULL) || (Hdr == BA_NULL) || (Offset == BA_NULL) || (Length == BA_NULL)) {
    return BA_ERR_INVALID;
  }
  if (Index >= Hdr->FrameCount) {
    return BA_ERR_INVALID;
  }
  if (IdxSize < 8) {
    return BA_ERR_TRUNCATED;
  }

  Off = BaRdU32 (IdxEntry);
  Len = BaRdU32 (IdxEntry + 4);

  if ((BA_U64)Off > (BA_U64)FileSize) {
    return BA_ERR_TRUNCATED;
  }
  if ((BA_U64)Len > (BA_U64)FileSize) {
    return BA_ERR_TRUNCATED;
  }
  if ((BA_U64)Off + (BA_U64)Len > (BA_U64)FileSize) {
    return BA_ERR_TRUNCATED;
  }
  /* 未压缩时每帧长度必须严格等于 宽*高*4，与 Python 参考实现一致 */
  if ((Hdr->Flags & BA_BAA_FLAG_RLE) == 0) {
    if ((BA_U64)Len != (BA_U64)Hdr->Width * (BA_U64)Hdr->Height * 4u) {
      return BA_ERR_FORMAT;
    }
  }

  *Offset = (BA_U64)Off;
  *Length = Len;
  return BA_OK;
}

BA_STATUS
BaBaaDecodeFrame (
  const BA_U8        *Raw,
  BA_SIZE             RawSize,
  const BA_BAA_HEADER *Hdr,
  BA_U8              *Out,
  BA_SIZE             OutSize
  )
{
  BA_SIZE Want;

  if ((Raw == BA_NULL) || (Hdr == BA_NULL) || (Out == BA_NULL)) {
    return BA_ERR_INVALID;
  }

  Want = (BA_SIZE)Hdr->Width * (BA_SIZE)Hdr->Height * 4u;
  if (OutSize < Want) {
    return BA_ERR_INVALID;
  }

  if ((Hdr->Flags & BA_BAA_FLAG_RLE) == 0) {
    if (RawSize != Want) {
      return BA_ERR_FORMAT;
    }
    BaMemCopy (Out, Raw, Want);
    return BA_OK;
  }

  return BaRleDecode (Raw, RawSize, Out, Want, BA_NULL);
}

/* ================================================================== */
/* BMP 解码                                                           */
/* ================================================================== */
#define BA_BMP_BI_RGB        0u
#define BA_BMP_BI_RLE8       1u
#define BA_BMP_BI_RLE4       2u
#define BA_BMP_BI_BITFIELDS  3u

typedef struct {
  BA_U32 Width;
  BA_U32 Height;
  BA_BOOL TopDown;
  BA_U16 BitCount;
  BA_U32 Compression;
  BA_U32 PixelOfs;
  BA_U32 PaletteOfs;
  BA_U32 PaletteCount;
  BA_U32 MaskR;
  BA_U32 MaskG;
  BA_U32 MaskB;
  BA_U32 RowStride;
} BA_BMP;

static void
BaBitCountAndShift (
  BA_U32  Mask,
  BA_U32 *Bits,
  BA_U32 *Shift
  )
{
  BA_U32 B = 0;
  BA_U32 S = 0;
  BA_U32 M = Mask;

  if (M == 0) {
    *Bits  = 0;
    *Shift = 0;
    return;
  }
  while ((M & 1u) == 0) {
    M >>= 1;
    S++;
  }
  while ((M & 1u) != 0) {
    M >>= 1;
    B++;
  }
  *Bits  = B;
  *Shift = S;
}

/* 把 n 位分量扩展成 8 位（n<=8） */
static BA_U8
BaExpandTo8 (
  BA_U32 V,
  BA_U32 Bits
  )
{
  switch (Bits) {
    case 0:  return 0;
    case 1:  return (BA_U8)(V ? 255u : 0u);
    case 2:  return (BA_U8)(V * 85u);
    case 3:  return (BA_U8)((V << 5) | (V << 2) | (V >> 1));
    case 4:  return (BA_U8)(V * 17u);
    case 5:  return (BA_U8)((V << 3) | (V >> 2));
    case 6:  return (BA_U8)((V << 2) | (V >> 4));
    case 7:  return (BA_U8)((V << 1) | (V >> 6));
    case 8:  return (BA_U8)V;
    default:
    {
      BA_U32 MaxV = (1u << Bits) - 1u;
      return (BA_U8)((V * 255u + (MaxV >> 1)) / MaxV);
    }
  }
}

/* 解析 BMP 头，得到解码所需的全部信息 */
static BA_STATUS
BaBmpParse (
  const BA_U8 *Data,
  BA_SIZE      Size,
  BA_BMP      *B
  )
{
  BA_U32 BiSize;
  BA_U32 BfOffBits;
  BA_U32 Width;
  BA_U32 Height;
  BA_I32 RawHeight;
  BA_U32 ColorsUsed;
  BA_SIZE MinPixel;

  if ((Data == BA_NULL) || (B == BA_NULL)) {
    return BA_ERR_INVALID;
  }
  if (Size < 14 + 40) {
    return BA_ERR_TRUNCATED;
  }
  if ((Data[0] != 'B') || (Data[1] != 'M')) {
    return BA_ERR_FORMAT;
  }

  BfOffBits   = BaRdU32 (Data + 10);
  BiSize      = BaRdU32 (Data + 14);
  if (BiSize < 40) {
    return BA_ERR_UNSUPPORTED;    /* OS/2 老格式不支持 */
  }
  if ((BA_SIZE)14 + (BA_SIZE)BiSize > Size) {
    return BA_ERR_TRUNCATED;
  }

  Width     = BaRdU32 (Data + 18);
  RawHeight = (BA_I32)BaRdU32 (Data + 22);

  BaMemSet (B, 0, sizeof (BA_BMP));
  B->Width  = Width;
  if (RawHeight < 0) {
    /* 负高度 = 自上而下存储。用无符号取反避免 INT32_MIN 的有符号溢出。 */
    B->Height  = 0u - (BA_U32)RawHeight;
    B->TopDown = BA_TRUE;
  } else {
    B->Height  = (BA_U32)RawHeight;
    B->TopDown = BA_FALSE;
  }
  B->BitCount     = BaRdU16 (Data + 28);
  B->Compression  = BaRdU32 (Data + 30);
  ColorsUsed      = BaRdU32 (Data + 46);

  if ((B->Width == 0) || (B->Height == 0)) {
    return BA_ERR_FORMAT;
  }
  if ((BA_U64)B->Width * (BA_U64)B->Height > (BA_U64)BA_MAX_PIXELS) {
    return BA_ERR_TOO_BIG;
  }

  switch (B->BitCount) {
    case 1:
    case 4:
    case 8:
    case 16:
    case 24:
    case 32:
      break;
    default:
      return BA_ERR_UNSUPPORTED;
  }

  if ((B->Compression != BA_BMP_BI_RGB) && (B->Compression != BA_BMP_BI_BITFIELDS)) {
    return BA_ERR_UNSUPPORTED;    /* 不支持 RLE4/RLE8 */
  }
  if ((B->Compression == BA_BMP_BI_BITFIELDS) && (B->BitCount != 16) && (B->BitCount != 32)) {
    return BA_ERR_UNSUPPORTED;
  }

  /* ---- 通道掩码 ---- */
  if (B->Compression == BA_BMP_BI_BITFIELDS) {
    if (BiSize >= 52) {
      /* V4/V5 头，掩码在头内部偏移 40..56 */
      if ((BA_SIZE)14 + 56 > Size) {
        return BA_ERR_TRUNCATED;
      }
      B->MaskR = BaRdU32 (Data + 14 + 40);
      B->MaskG = BaRdU32 (Data + 14 + 44);
      B->MaskB = BaRdU32 (Data + 14 + 48);
      B->PaletteOfs = 14 + BiSize;
    } else {
      /* 紧凑 BITMAPINFOHEADER：掩码紧跟头之后 */
      if ((BA_SIZE)14 + 40 + 12 > Size) {
        return BA_ERR_TRUNCATED;
      }
      B->MaskR = BaRdU32 (Data + 14 + 40);
      B->MaskG = BaRdU32 (Data + 14 + 44);
      B->MaskB = BaRdU32 (Data + 14 + 48);
      B->PaletteOfs = 14 + 40 + 12;
    }
  } else {
    switch (B->BitCount) {
      case 16:
        B->MaskR = 0x7C00u;
        B->MaskG = 0x03E0u;
        B->MaskB = 0x001Fu;
        break;
      case 24:
      case 32:
        B->MaskR = 0x00FF0000u;
        B->MaskG = 0x0000FF00u;
        B->MaskB = 0x000000FFu;
        break;
      default:
        B->MaskR = B->MaskG = B->MaskB = 0;
        break;
    }
    B->PaletteOfs = 14 + BiSize;
  }

  /* ---- 调色板 ---- */
  B->PaletteCount = 0;
  if (B->BitCount <= 8) {
    BA_U32 Def = 1u << B->BitCount;
    B->PaletteCount = (ColorsUsed != 0) ? ColorsUsed : Def;
    if (B->PaletteCount > 256) {
      B->PaletteCount = 256;
    }
    if ((BA_SIZE)B->PaletteOfs + (BA_SIZE)B->PaletteCount * 4u > Size) {
      return BA_ERR_TRUNCATED;
    }
  }

  /* ---- 像素数据起点 ---- */
  B->RowStride = (BA_U32)((((BA_U64)B->Width * B->BitCount) + 31u) / 32u * 4u);
  MinPixel = (BA_SIZE)B->PaletteOfs + (BA_SIZE)B->PaletteCount * 4u;
  if ((BfOffBits < MinPixel) || ((BA_SIZE)BfOffBits > Size)) {
    B->PixelOfs = (BA_U32)MinPixel;
  } else {
    B->PixelOfs = BfOffBits;
  }

  if ((BA_U64)B->PixelOfs + (BA_U64)B->RowStride * (BA_U64)B->Height > (BA_U64)Size) {
    return BA_ERR_TRUNCATED;
  }

  return BA_OK;
}

BA_STATUS
BaBmpProbe (
  const BA_U8 *Data,
  BA_SIZE      Size,
  BA_U32      *Width,
  BA_U32      *Height
  )
{
  BA_BMP    B;
  BA_STATUS St;

  if ((Width == BA_NULL) || (Height == BA_NULL)) {
    return BA_ERR_INVALID;
  }
  St = BaBmpParse (Data, Size, &B);
  if (St != BA_OK) {
    return St;
  }
  *Width  = B.Width;
  *Height = B.Height;
  return BA_OK;
}

BA_STATUS
BaBmpDecode (
  const BA_U8 *Data,
  BA_SIZE      Size,
  BA_U8       *Out,
  BA_U32       Width,
  BA_U32       Height
  )
{
  BA_BMP   B;
  BA_STATUS St;
  BA_U32   MaskBitsR;
  BA_U32   MaskShiftR;
  BA_U32   MaskBitsG;
  BA_U32   MaskShiftG;
  BA_U32   MaskBitsB;
  BA_U32   MaskShiftB;
  const BA_U8 *Palette;
  BA_U32   Y;

  if (Out == BA_NULL) {
    return BA_ERR_INVALID;
  }
  St = BaBmpParse (Data, Size, &B);
  if (St != BA_OK) {
    return St;
  }
  /* 调用方给的宽高必须与文件一致，否则拒绝（防止越界写） */
  if ((B.Width != Width) || (B.Height != Height)) {
    return BA_ERR_INVALID;
  }

  BaBitCountAndShift (B.MaskR, &MaskBitsR, &MaskShiftR);
  BaBitCountAndShift (B.MaskG, &MaskBitsG, &MaskShiftG);
  BaBitCountAndShift (B.MaskB, &MaskBitsB, &MaskShiftB);

  Palette = Data + B.PaletteOfs;

  for (Y = 0; Y < B.Height; Y++) {
    /* 源行号：自下而上存储时最后一行是图像顶部 */
    BA_U32 SrcRow = B.TopDown ? Y : (B.Height - 1u - Y);
    const BA_U8 *P = Data + B.PixelOfs + (BA_SIZE)SrcRow * B.RowStride;
    BA_U8 *D = Out + (BA_SIZE)Y * B.Width * 4u;
    BA_U32 X;

    switch (B.BitCount) {
      case 24:
        for (X = 0; X < B.Width; X++) {
          D[0] = P[0];
          D[1] = P[1];
          D[2] = P[2];
          D[3] = 0xFF;
          P   += 3;
          D   += 4;
        }
        break;

      case 32:
        for (X = 0; X < B.Width; X++) {
          BA_U32 V = BaRdU32 (P);
          D[0] = BaExpandTo8 ((V & B.MaskB) >> MaskShiftB, MaskBitsB);
          D[1] = BaExpandTo8 ((V & B.MaskG) >> MaskShiftG, MaskBitsG);
          D[2] = BaExpandTo8 ((V & B.MaskR) >> MaskShiftR, MaskBitsR);
          D[3] = 0xFF;
          P   += 4;
          D   += 4;
        }
        break;

      case 16:
        for (X = 0; X < B.Width; X++) {
          BA_U32 V = (BA_U32)P[0] | ((BA_U32)P[1] << 8);
          D[0] = BaExpandTo8 ((V & B.MaskB) >> MaskShiftB, MaskBitsB);
          D[1] = BaExpandTo8 ((V & B.MaskG) >> MaskShiftG, MaskBitsG);
          D[2] = BaExpandTo8 ((V & B.MaskR) >> MaskShiftR, MaskBitsR);
          D[3] = 0xFF;
          P   += 2;
          D   += 4;
        }
        break;

      case 8:
        for (X = 0; X < B.Width; X++) {
          BA_U32 Idx = P[X];
          if (Idx >= B.PaletteCount) {
            Idx = 0;
          }
          D[0] = Palette[Idx * 4 + 0];
          D[1] = Palette[Idx * 4 + 1];
          D[2] = Palette[Idx * 4 + 2];
          D[3] = 0xFF;
          D   += 4;
        }
        break;

      case 4:
        for (X = 0; X < B.Width; X++) {
          BA_U32 Idx = (X & 1u) ? (BA_U32)(P[X >> 1] & 0x0Fu)
                                : (BA_U32)((P[X >> 1] >> 4) & 0x0Fu);
          if (Idx >= B.PaletteCount) {
            Idx = 0;
          }
          D[0] = Palette[Idx * 4 + 0];
          D[1] = Palette[Idx * 4 + 1];
          D[2] = Palette[Idx * 4 + 2];
          D[3] = 0xFF;
          D   += 4;
        }
        break;

      case 1:
        for (X = 0; X < B.Width; X++) {
          BA_U32 Idx = (BA_U32)((P[X >> 3] >> (7u - (X & 7u))) & 1u);
          if (Idx >= B.PaletteCount) {
            Idx = 0;
          }
          D[0] = Palette[Idx * 4 + 0];
          D[1] = Palette[Idx * 4 + 1];
          D[2] = Palette[Idx * 4 + 2];
          D[3] = 0xFF;
          D   += 4;
        }
        break;

      default:
        return BA_ERR_UNSUPPORTED;
    }
  }

  return BA_OK;
}

/* ================================================================== */
/* 目标矩形计算                                                       */
/* ================================================================== */
static BA_U32
BaRoundDiv (
  BA_U64 A,
  BA_U64 B
  )
{
  if (B == 0) {
    return 0;
  }
  return (BA_U32)((A + B / 2u) / B);
}

BA_STATUS
BaImageFitRect (
  BA_U32   SrcW,
  BA_U32   SrcH,
  BA_U32   DstW,
  BA_U32   DstH,
  BA_U32   ScaleMode,
  BA_RECT *DstRect,
  BA_RECT *SrcRect
  )
{
  BA_U32 W;
  BA_U32 H;

  if ((DstRect == BA_NULL) || (SrcRect == BA_NULL)) {
    return BA_ERR_INVALID;
  }
  if ((SrcW == 0) || (SrcH == 0) || (DstW == 0) || (DstH == 0)) {
    return BA_ERR_INVALID;
  }

  /* 默认：整幅源图 -> 整块目标 */
  SrcRect->X = 0;
  SrcRect->Y = 0;
  SrcRect->W = SrcW;
  SrcRect->H = SrcH;
  DstRect->X = 0;
  DstRect->Y = 0;
  DstRect->W = DstW;
  DstRect->H = DstH;

  switch (ScaleMode) {
    case BA_SCALE_STRETCH:
      /* 已经填好 */
      break;

    case BA_SCALE_FILL:
    {
      /* 等比放大到完全覆盖，然后从源图居中裁剪 */
      BA_U64 ByW = (BA_U64)DstW * (BA_U64)SrcH;
      BA_U64 ByH = (BA_U64)DstH * (BA_U64)SrcW;

      DstRect->W = DstW;
      DstRect->H = DstH;
      if (ByW > ByH) {
        /* 以宽为准：源图竖向裁剪 */
        BA_U32 CropH = (BA_U32)(((BA_U64)SrcW * (BA_U64)DstH) / (BA_U64)DstW);
        if (CropH == 0) {
          CropH = 1;
        }
        if (CropH > SrcH) {
          CropH = SrcH;
        }
        SrcRect->H = CropH;
        SrcRect->Y = (SrcH - CropH) / 2u;
      } else {
        BA_U32 CropW = (BA_U32)(((BA_U64)SrcH * (BA_U64)DstW) / (BA_U64)DstH);
        if (CropW == 0) {
          CropW = 1;
        }
        if (CropW > SrcW) {
          CropW = SrcW;
        }
        SrcRect->W = CropW;
        SrcRect->X = (SrcW - CropW) / 2u;
      }
      break;
    }

    case BA_SCALE_NATIVE:
    case BA_SCALE_CENTER:
      if ((SrcW <= DstW) && (SrcH <= DstH)) {
        /* 1:1 居中，不缩放 */
        DstRect->W = SrcW;
        DstRect->H = SrcH;
        DstRect->X = (DstW - SrcW) / 2u;
        DstRect->Y = (DstH - SrcH) / 2u;
        break;
      }
      /* 源图比屏幕大：退化为 fit（等比缩小，保证不裁剪、不留越界） */
      /* fall through */
    case BA_SCALE_FIT:
    default:
    {
      BA_U64 ByW = (BA_U64)DstW * (BA_U64)SrcH;   /* 按宽度铺满所需 */
      BA_U64 ByH = (BA_U64)DstH * (BA_U64)SrcW;   /* 按高度铺满所需 */

      if (ByW <= ByH) {
        /* 宽度是限制因素 */
        W = DstW;
        H = BaRoundDiv ((BA_U64)SrcH * (BA_U64)DstW, (BA_U64)SrcW);
      } else {
        H = DstH;
        W = BaRoundDiv ((BA_U64)SrcW * (BA_U64)DstH, (BA_U64)SrcH);
      }
      if (W == 0) {
        W = 1;
      }
      if (H == 0) {
        H = 1;
      }
      if (W > DstW) {
        W = DstW;
      }
      if (H > DstH) {
        H = DstH;
      }
      DstRect->W = W;
      DstRect->H = H;
      DstRect->X = (DstW - W) / 2u;
      DstRect->Y = (DstH - H) / 2u;
      break;
    }
  }

  return BA_OK;
}

/* ================================================================== */
/* 采样抽头 + 逐行缩放                                                */
/* ================================================================== */
static void
BaMakeTaps (
  BA_TAP *T,
  BA_U32  DstN,
  BA_U32  SrcN
  )
{
  BA_U32 I;

  if (SrcN == 0) {
    SrcN = 1;
  }
  for (I = 0; I < DstN; I++) {
    /* pos = (I + 0.5) * SrcN / DstN - 0.5  (16.16 定点，可负) */
    signed long long Num = ((signed long long)(2 * (long long)I + 1) * (signed long long)SrcN * 65536LL)
                           / (signed long long)(2 * (long long)DstN)
                           - 32768LL;

    if (Num <= 0) {
      T[I].I0 = 0;
      T[I].I1 = (SrcN > 1) ? 1u : 0u;
      T[I].F  = 0;
    } else if (Num >= (signed long long)(SrcN - 1u) * 65536LL) {
      T[I].I0 = SrcN - 1u;
      T[I].I1 = SrcN - 1u;
      T[I].F  = 0;
    } else {
      T[I].I0 = (BA_U32)((unsigned long long)Num >> 16);
      T[I].F  = (BA_U32)((unsigned long long)Num & 0xFFFFu);
      T[I].I1 = T[I].I0 + 1u;
      if (T[I].I1 >= SrcN) {
        T[I].I1 = SrcN - 1u;
      }
    }
  }
}

BA_STATUS
BaScalerInit (
  BA_SCALER *S,
  BA_U32     SrcX0,
  BA_U32     SrcY0,
  BA_U32     SrcW,
  BA_U32     SrcH,
  BA_U32     DstW,
  BA_U32     DstH,
  BA_TAP    *XT,
  BA_TAP    *YT
  )
{
  if ((S == BA_NULL) || (XT == BA_NULL) || (YT == BA_NULL)) {
    return BA_ERR_INVALID;
  }
  if ((SrcW == 0) || (SrcH == 0) || (DstW == 0) || (DstH == 0)) {
    return BA_ERR_INVALID;
  }

  S->SrcX0 = SrcX0;
  S->SrcY0 = SrcY0;
  S->SrcW  = SrcW;
  S->SrcH  = SrcH;
  S->DstW  = DstW;
  S->DstH  = DstH;
  S->XT    = XT;
  S->YT    = YT;

  BaMakeTaps (XT, DstW, SrcW);
  BaMakeTaps (YT, DstH, SrcH);
  return BA_OK;
}

/* 在源行里取一个 BGRX 像素（返回 32 位打包值） */
static BA_U32
BaSampleRow (
  const BA_U8  *Row,
  const BA_TAP *T,
  BA_U32        Filter
  )
{
  const BA_U8 *P;

  if (Filter == BA_FILTER_NEAREST) {
    P = Row + ((T->F >= 32768u) ? T->I1 : T->I0) * 4u;
    return (BA_U32)P[0] | ((BA_U32)P[1] << 8) | ((BA_U32)P[2] << 16) | ((BA_U32)P[3] << 24);
  }

  if (T->F == 0) {
    P = Row + T->I0 * 4u;
    return (BA_U32)P[0] | ((BA_U32)P[1] << 8) | ((BA_U32)P[2] << 16) | ((BA_U32)P[3] << 24);
  } else {
    const BA_U8 *A = Row + T->I0 * 4u;
    const BA_U8 *B = Row + T->I1 * 4u;
    BA_U32 F  = T->F;
    BA_U32 IF = 65536u - F;
    BA_U32 C0 = ((BA_U32)A[0] * IF + (BA_U32)B[0] * F) >> 16;
    BA_U32 C1 = ((BA_U32)A[1] * IF + (BA_U32)B[1] * F) >> 16;
    BA_U32 C2 = ((BA_U32)A[2] * IF + (BA_U32)B[2] * F) >> 16;
    BA_U32 C3 = ((BA_U32)A[3] * IF + (BA_U32)B[3] * F) >> 16;
    return C0 | (C1 << 8) | (C2 << 16) | (C3 << 24);
  }
}

void
BaScalerRow (
  const BA_SCALER *S,
  const BA_U8     *Src,
  BA_U32           SrcStride,
  BA_U32           DstY,
  BA_U8           *Row,
  BA_U32           Filter
  )
{
  const BA_U8 *Row0;
  const BA_U8 *Row1;
  BA_U32       Fy;
  BA_U32       X;

  if ((S == BA_NULL) || (Src == BA_NULL) || (Row == BA_NULL)) {
    return;
  }
  if (DstY >= S->DstH) {
    return;
  }

  Row0 = Src + (BA_SIZE)(S->SrcY0 + S->YT[DstY].I0) * SrcStride;
  Row1 = Src + (BA_SIZE)(S->SrcY0 + S->YT[DstY].I1) * SrcStride;

  Fy = S->YT[DstY].F;
  if (Filter == BA_FILTER_NEAREST) {
    Fy = (Fy >= 32768u) ? 65536u : 0u;
  }

  if (Fy == 0) {
    for (X = 0; X < S->DstW; X++) {
      BA_U32 V = BaSampleRow (Row0, &S->XT[X], Filter);
      Row[X * 4 + 0] = (BA_U8)(V & 0xFF);
      Row[X * 4 + 1] = (BA_U8)((V >> 8) & 0xFF);
      Row[X * 4 + 2] = (BA_U8)((V >> 16) & 0xFF);
      Row[X * 4 + 3] = (BA_U8)((V >> 24) & 0xFF);
    }
  } else if (Fy >= 65536u) {
    for (X = 0; X < S->DstW; X++) {
      BA_U32 V = BaSampleRow (Row1, &S->XT[X], Filter);
      Row[X * 4 + 0] = (BA_U8)(V & 0xFF);
      Row[X * 4 + 1] = (BA_U8)((V >> 8) & 0xFF);
      Row[X * 4 + 2] = (BA_U8)((V >> 16) & 0xFF);
      Row[X * 4 + 3] = (BA_U8)((V >> 24) & 0xFF);
    }
  } else {
    BA_U32 IFy = 65536u - Fy;
    for (X = 0; X < S->DstW; X++) {
      BA_U32 V0 = BaSampleRow (Row0, &S->XT[X], Filter);
      BA_U32 V1 = BaSampleRow (Row1, &S->XT[X], Filter);
      BA_U32 C0 = (((V0 & 0xFFu) * IFy) + ((V1 & 0xFFu) * Fy)) >> 16;
      BA_U32 C1 = ((((V0 >> 8) & 0xFFu) * IFy) + (((V1 >> 8) & 0xFFu) * Fy)) >> 16;
      BA_U32 C2 = ((((V0 >> 16) & 0xFFu) * IFy) + (((V1 >> 16) & 0xFFu) * Fy)) >> 16;
      BA_U32 C3 = ((((V0 >> 24) & 0xFFu) * IFy) + (((V1 >> 24) & 0xFFu) * Fy)) >> 16;
      Row[X * 4 + 0] = (BA_U8)C0;
      Row[X * 4 + 1] = (BA_U8)C1;
      Row[X * 4 + 2] = (BA_U8)C2;
      Row[X * 4 + 3] = (BA_U8)C3;
    }
  }
}
