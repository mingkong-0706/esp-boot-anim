/** @file
  BaGfx.c -- GOP 图形输出：模式选择、像素格式转换、缩放呈现。

  支持全部四种 GOP 像素格式：
    * PixelBlueGreenRedReserved8BitPerColor  -> 直接 memcpy（最快路径）
    * PixelRedGreenBlueReserved8BitPerColor  -> 交换 R/B
    * PixelBitMask (16/24/32bpp)             -> 8 位分量查表打包
    * PixelBltOnly                           -> 退回 Blt 逐行输出

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#include "BaUefi.h"
#include "BaGuids.h"
#include "BaPlat.h"

#define BA_GFX_MAX_DIM 16384u

/* ================================================================== */
/* 像素格式辅助                                                       */
/* ================================================================== */
static void
BaBitInfo (
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

/* 8 位分量 -> 目标位宽，并预先左移到目标位置 */
static BA_U32
BaMakeMapEntry (
  BA_U32 Value8,
  BA_U32 Bits,
  BA_U32 Shift
  )
{
  BA_U32 MaxV;
  BA_U32 V;

  if (Bits == 0) {
    return 0;
  }
  if (Bits >= 8) {
    V = (Bits == 8) ? Value8 : (Value8 << (Bits - 8));
  } else {
    MaxV = (1u << Bits) - 1u;
    V    = (Value8 * MaxV + 127u) / 255u;
  }
  return (V << Shift);
}

static void
BaBuildMaps (
  BA_GFX *G
  )
{
  BA_U32 I;

  for (I = 0; I < 256u; I++) {
    G->MapR[I] = BaMakeMapEntry (I, G->BitsR, G->ShiftR);
    G->MapG[I] = BaMakeMapEntry (I, G->BitsG, G->ShiftG);
    G->MapB[I] = BaMakeMapEntry (I, G->BitsB, G->ShiftB);
  }
}

/* ================================================================== */
/* 初始化                                                             */
/* ================================================================== */
static void
BaGfxSelectMode (
  EFI_GRAPHICS_OUTPUT_PROTOCOL *Gop,
  BA_U32                        WantW,
  BA_U32                        WantH
  )
{
  UINT32 I;
  UINT32 Best     = 0xFFFFFFFFu;
  UINT32 BestArea = 0;

  if ((Gop == NULL) || (Gop->Mode == NULL) || (Gop->QueryMode == NULL)) {
    return;
  }
  if (Gop->Mode->Info != NULL) {
    if ((Gop->Mode->Info->HorizontalResolution == WantW) &&
        (Gop->Mode->Info->VerticalResolution == WantH))
    {
      return;   /* 当前模式已经是想要的 */
    }
  }

  for (I = 0; I < Gop->Mode->MaxMode; I++) {
    UINTN                                 Size = 0;
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info = NULL;

    if (EFI_ERROR (Gop->QueryMode (Gop, I, &Size, &Info)) || (Info == NULL)) {
      continue;
    }
    if ((Info->HorizontalResolution == WantW) && (Info->VerticalResolution == WantH)) {
      Best = I;
      break;
    }
    if ((Info->HorizontalResolution >= WantW) && (Info->VerticalResolution >= WantH)) {
      UINT32 Area = (UINT32)Info->HorizontalResolution * (UINT32)Info->VerticalResolution;
      if ((BestArea == 0) || (Area < BestArea)) {
        BestArea = Area;
        Best     = I;
      }
    }
    /* 刻意不 FreePool(Info)：不同固件对这个缓冲区归属的约定不一致
       （有的返回内部静态数据），误释放会造成内存破坏。本程序是一次性
       启动程序，这点泄漏无关紧要。 */
  }

  if (Best != 0xFFFFFFFFu) {
    (VOID)Gop->SetMode (Gop, Best);
  }
}

BA_STATUS
BaGfxInit (
  BA_GFX          *G,
  const BA_CONFIG *Cfg
  )
{
  EFI_STATUS                            Status;
  EFI_GRAPHICS_OUTPUT_PROTOCOL         *Gop = NULL;
  EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info;
  BA_U32                                TotalBits;

  if (G == BA_NULL) {
    return BA_ERR_INVALID;
  }
  BaMemSet (G, 0, sizeof (BA_GFX));

  Status = gBS->LocateProtocol (&gBaGuidGraphicsOutput, NULL, (VOID **)&Gop);
  if (EFI_ERROR (Status) || (Gop == NULL)) {
    return BA_ERR_NOT_FOUND;
  }
  G->Gop = Gop;

  if ((Cfg != BA_NULL) && (Cfg->VideoWidth != 0) && (Cfg->VideoHeight != 0)) {
    BaGfxSelectMode (Gop, Cfg->VideoWidth, Cfg->VideoHeight);
  }

  if ((Gop->Mode == NULL) || (Gop->Mode->Info == NULL)) {
    G->Gop = BA_NULL;
    return BA_ERR_UNSUPPORTED;
  }
  Info = Gop->Mode->Info;

  G->Width  = Info->HorizontalResolution;
  G->Height = Info->VerticalResolution;
  if ((G->Width == 0) || (G->Height == 0) ||
      (G->Width > BA_GFX_MAX_DIM) || (G->Height > BA_GFX_MAX_DIM))
  {
    G->Gop = BA_NULL;
    return BA_ERR_UNSUPPORTED;
  }

  switch (Info->PixelFormat) {
    case PixelBlueGreenRedReserved8BitPerColor:
      G->Format = BA_PF_BGRX;
      G->Bpp    = 4;
      G->BitsR  = 8; G->ShiftR = 16;
      G->BitsG  = 8; G->ShiftG = 8;
      G->BitsB  = 8; G->ShiftB = 0;
      G->MapA   = 0xFF000000u;
      break;

    case PixelRedGreenBlueReserved8BitPerColor:
      G->Format = BA_PF_RGBX;
      G->Bpp    = 4;
      G->BitsR  = 8; G->ShiftR = 0;
      G->BitsG  = 8; G->ShiftG = 8;
      G->BitsB  = 8; G->ShiftB = 16;
      G->MapA   = 0xFF000000u;
      break;

    case PixelBitMask:
      G->MaskR = Info->PixelInformation.RedMask;
      G->MaskG = Info->PixelInformation.GreenMask;
      G->MaskB = Info->PixelInformation.BlueMask;
      BaBitInfo (G->MaskR, &G->BitsR, &G->ShiftR);
      BaBitInfo (G->MaskG, &G->BitsG, &G->ShiftG);
      BaBitInfo (G->MaskB, &G->BitsB, &G->ShiftB);
      TotalBits = G->BitsR + G->BitsG + G->BitsB;
      G->MapA   = 0;
      if (Info->PixelInformation.ReservedMask != 0) {
        BA_U32 RB = 0;
        BA_U32 RS = 0;
        BaBitInfo (Info->PixelInformation.ReservedMask, &RB, &RS);
        TotalBits += RB;
        if (RB > 0) {
          BA_U32 V = (RB >= 8) ? ((RB == 8) ? 0xFFu : (0xFFu << (RB - 8)))
                               : ((1u << RB) - 1u);
          G->MapA = V << RS;
        }
      }
      if (TotalBits <= 16u) {
        G->Format = BA_PF_MASK16;
        G->Bpp    = 2;
      } else if (TotalBits <= 24u) {
        G->Format = BA_PF_MASK24;
        G->Bpp    = 3;
      } else {
        G->Format = BA_PF_MASK32;
        G->Bpp    = 4;
      }
      break;

    case PixelBltOnly:
      /* 不能直接写显存，只能靠 Blt 输出 */
      G->Format = BA_PF_BLTONLY;
      G->Bpp    = 4;
      G->MapA   = 0;
      break;

    default:
      G->Gop = BA_NULL;
      return BA_ERR_UNSUPPORTED;
  }

  if (G->Format == BA_PF_BLTONLY) {
    G->Fb = BA_NULL;
  } else {
    G->Fb = (BA_U8 *)(UINTN)Gop->Mode->FrameBufferBase;
    if (G->Fb == BA_NULL) {
      G->Gop = BA_NULL;
      return BA_ERR_UNSUPPORTED;
    }
    G->Stride = (BA_U32)Info->PixelsPerScanLine * G->Bpp;
    if (G->Stride < G->Width * G->Bpp) {
      G->Stride = G->Width * G->Bpp;   /* 固件给了异常值：退化成紧凑排布 */
    }
  }

  if ((G->Format != BA_PF_BGRX) && (G->Format != BA_PF_RGBX)) {
    BaBuildMaps (G);
  }

  /* 工作缓冲 */
  G->RowBufCap  = G->Width;
  G->ConvBufCap = G->Width;
  G->XTapCap    = G->Width;
  G->YTapCap    = G->Height;

  G->RowBuf  = (BA_U8 *)BaAlloc ((BA_SIZE)G->RowBufCap * 4u);
  G->ConvBuf = (BA_U8 *)BaAlloc ((BA_SIZE)G->ConvBufCap * 4u);
  G->XTaps   = (BA_TAP *)BaAlloc ((BA_SIZE)G->XTapCap * sizeof (BA_TAP));
  G->YTaps   = (BA_TAP *)BaAlloc ((BA_SIZE)G->YTapCap * sizeof (BA_TAP));

  if ((G->RowBuf == BA_NULL) || (G->ConvBuf == BA_NULL) ||
      (G->XTaps == BA_NULL) || (G->YTaps == BA_NULL))
  {
    BaGfxShutdown (G);
    return BA_ERR_NO_MEMORY;
  }

  return BA_OK;
}

void
BaGfxShutdown (
  BA_GFX *G
  )
{
  if (G == BA_NULL) {
    return;
  }
  BaFree (G->RowBuf);
  BaFree (G->ConvBuf);
  BaFree (G->XTaps);
  BaFree (G->YTaps);
  G->RowBuf      = BA_NULL;
  G->ConvBuf     = BA_NULL;
  G->XTaps       = BA_NULL;
  G->YTaps       = BA_NULL;
  G->Gop         = BA_NULL;
  G->Fb          = BA_NULL;
  G->ScalerValid = BA_FALSE;
}

BA_BOOL
BaGfxValid (
  const BA_GFX *G
  )
{
  if (G == BA_NULL) {
    return BA_FALSE;
  }
  return (G->Gop != BA_NULL) ? BA_TRUE : BA_FALSE;
}

/* ================================================================== */
/* 输出                                                               */
/* ================================================================== */
/* 把 W 个 BGRX 像素转换成目标像素格式写入 Out（Out 至少 W*Bpp 字节） */
static void
BaConvRow (
  const BA_GFX *G,
  const BA_U8  *Src,
  BA_U32        W,
  BA_U8        *Out
  )
{
  BA_U32 I;

  switch (G->Format) {
    case BA_PF_BGRX:
    case BA_PF_BLTONLY:
      BaMemCopy (Out, Src, (BA_SIZE)W * 4u);
      break;

    case BA_PF_RGBX:
      for (I = 0; I < W; I++) {
        Out[0] = Src[2];
        Out[1] = Src[1];
        Out[2] = Src[0];
        Out[3] = 0xFF;
        Out   += 4;
        Src   += 4;
      }
      break;

    case BA_PF_MASK32:
      for (I = 0; I < W; I++) {
        BA_U32 V = G->MapB[Src[0]] | G->MapG[Src[1]] | G->MapR[Src[2]] | G->MapA;
        Out[0] = (BA_U8)(V & 0xFF);
        Out[1] = (BA_U8)((V >> 8) & 0xFF);
        Out[2] = (BA_U8)((V >> 16) & 0xFF);
        Out[3] = (BA_U8)((V >> 24) & 0xFF);
        Out   += 4;
        Src   += 4;
      }
      break;

    case BA_PF_MASK24:
      for (I = 0; I < W; I++) {
        BA_U32 V = G->MapB[Src[0]] | G->MapG[Src[1]] | G->MapR[Src[2]] | G->MapA;
        Out[0] = (BA_U8)(V & 0xFF);
        Out[1] = (BA_U8)((V >> 8) & 0xFF);
        Out[2] = (BA_U8)((V >> 16) & 0xFF);
        Out   += 3;
        Src   += 4;
      }
      break;

    case BA_PF_MASK16:
    default:
      for (I = 0; I < W; I++) {
        BA_U32 V = G->MapB[Src[0]] | G->MapG[Src[1]] | G->MapR[Src[2]] | G->MapA;
        Out[0] = (BA_U8)(V & 0xFF);
        Out[1] = (BA_U8)((V >> 8) & 0xFF);
        Out   += 2;
        Src   += 4;
      }
      break;
  }
}

/* 往显存搬数据：优先用固件自带的 gBS->CopyMem（EDK2 里是 SSE/AVX 优化过的），
   比我们自己的逐字节循环快得多 —— 1920x1080 每帧要往显存写 8MB，
   这是整个播放流程里最重的一步。 */
static void
BaCopyToVideo (
  void       *Dst,
  const void *Src,
  BA_SIZE     Len
  )
{
  if (Len == 0) {
    return;
  }
  if ((gBS != NULL) && (gBS->CopyMem != NULL)) {
    gBS->CopyMem (Dst, (VOID *)Src, (UINTN)Len);
  } else {
    BaMemCopy (Dst, Src, Len);
  }
}

void
BaGfxClear (
  BA_GFX *G,
  BA_U32  Bgrx
  )
{
  BA_U8  Pix[4];
  BA_U32 Row;
  BA_U32 X;
  UINTN  Bpp;

  if (G == BA_NULL) {
    return;
  }

  Pix[0] = (BA_U8)(Bgrx & 0xFF);
  Pix[1] = (BA_U8)((Bgrx >> 8) & 0xFF);
  Pix[2] = (BA_U8)((Bgrx >> 16) & 0xFF);
  Pix[3] = 0xFF;

  if (G->Fb != BA_NULL) {
    Bpp = (UINTN)G->Bpp;
    /* 先用一个像素生成一行，再用"指数翻倍"把它铺满（O(log W) 次大块拷贝） */
    BaConvRow (G, (const BA_U8 *)Pix, 1, G->ConvBuf);
    X = 1;
    while (X < G->Width) {
      BA_U32 N = X;
      if (N > G->Width - X) {
        N = G->Width - X;
      }
      BaMemCopy (G->ConvBuf + (BA_SIZE)X * Bpp, G->ConvBuf, (BA_SIZE)N * Bpp);
      X += N;
    }
    for (Row = 0; Row < G->Height; Row++) {
      BaCopyToVideo (G->Fb + (BA_SIZE)Row * G->Stride, G->ConvBuf,
                     (BA_SIZE)G->Width * Bpp);
    }
    return;
  }

  /* BltOnly：逐行 Blt */
  if ((G->Gop == BA_NULL) || (G->RowBuf == BA_NULL)) {
    return;
  }
  for (X = 0; X < G->Width; X++) {
    G->RowBuf[X * 4 + 0] = Pix[0];
    G->RowBuf[X * 4 + 1] = Pix[1];
    G->RowBuf[X * 4 + 2] = Pix[2];
    G->RowBuf[X * 4 + 3] = 0xFF;
  }
  for (Row = 0; Row < G->Height; Row++) {
    EFI_GRAPHICS_OUTPUT_PROTOCOL *Gop = (EFI_GRAPHICS_OUTPUT_PROTOCOL *)G->Gop;
    (VOID)Gop->Blt (Gop,
                    (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)G->RowBuf,
                    EfiBltBufferToVideo,
                    0, 0,
                    0, Row,
                    G->Width, 1,
                    (UINTN)G->Width * 4u);
  }
}

void
BaGfxDraw (
  BA_GFX      *G,
  const BA_U8 *Src,
  BA_U32       SrcW,
  BA_U32       SrcH,
  BA_U32       ScaleMode,
  BA_U32       Filter,
  BA_U32       BgBgrx
  )
{
  BA_RECT Dr;
  BA_RECT Sr;
  BA_U32  Y;
  BA_BOOL Identity;
  BA_U32  UseFilter = Filter;

  (VOID)BgBgrx;   /* 背景由调用方通过 BaGfxClear 铺好 */

  if ((G == BA_NULL) || (Src == BA_NULL) || (SrcW == 0) || (SrcH == 0)) {
    return;
  }
  if (G->Width == 0 || G->Height == 0) {
    return;
  }

  if (BaImageFitRect (SrcW, SrcH, G->Width, G->Height, ScaleMode, &Dr, &Sr) != BA_OK) {
    return;
  }
  if ((Dr.W == 0) || (Dr.H == 0) || (Dr.X + Dr.W > G->Width) || (Dr.Y + Dr.H > G->Height)) {
    return;
  }

  Identity = (BA_BOOL)((Dr.W == Sr.W) && (Dr.H == Sr.H));

  if (UseFilter == BA_FILTER_AUTO) {
    UseFilter = Identity ? BA_FILTER_NEAREST : BA_FILTER_BILINEAR;
  }

  if (!Identity) {
    if (!G->ScalerValid ||
        (G->CsSrcX != Sr.X) || (G->CsSrcY != Sr.Y) ||
        (G->CsSrcW != Sr.W) || (G->CsSrcH != Sr.H) ||
        (G->CsDstW != Dr.W) || (G->CsDstH != Dr.H))
    {
      if (BaScalerInit (&G->Scaler, Sr.X, Sr.Y, Sr.W, Sr.H, Dr.W, Dr.H,
                        G->XTaps, G->YTaps) != BA_OK)
      {
        return;
      }
      G->CsSrcX     = Sr.X;
      G->CsSrcY     = Sr.Y;
      G->CsSrcW     = Sr.W;
      G->CsSrcH     = Sr.H;
      G->CsDstW     = Dr.W;
      G->CsDstH     = Dr.H;
      G->ScalerValid = BA_TRUE;
    }
  }

  for (Y = 0; Y < Dr.H; Y++) {
    const BA_U8 *RowSrc;

    if (Identity) {
      RowSrc = Src + ((BA_SIZE)(Sr.Y + Y) * SrcW + Sr.X) * 4u;
    } else {
      BaScalerRow (&G->Scaler, Src, SrcW * 4u, Y, G->RowBuf, UseFilter);
      RowSrc = G->RowBuf;
    }

    if (G->Fb != BA_NULL) {
      BA_U8 *Dst = G->Fb + (BA_SIZE)(Dr.Y + Y) * G->Stride + (BA_SIZE)Dr.X * G->Bpp;
      if ((G->Format == BA_PF_BGRX) && (G->Bpp == 4)) {
        BaCopyToVideo (Dst, RowSrc, (BA_SIZE)Dr.W * 4u);
      } else {
        BaConvRow (G, RowSrc, Dr.W, G->ConvBuf);
        BaCopyToVideo (Dst, G->ConvBuf, (BA_SIZE)Dr.W * G->Bpp);
      }
    } else if ((G->Gop != BA_NULL) && (G->Format == BA_PF_BLTONLY)) {
      EFI_GRAPHICS_OUTPUT_PROTOCOL *Gop = (EFI_GRAPHICS_OUTPUT_PROTOCOL *)G->Gop;
      (VOID)Gop->Blt (Gop,
                      (EFI_GRAPHICS_OUTPUT_BLT_PIXEL *)RowSrc,
                      EfiBltBufferToVideo,
                      0, 0,
                      Dr.X, Dr.Y + Y,
                      Dr.W, 1,
                      (UINTN)Dr.W * 4u);
    }
  }
}
