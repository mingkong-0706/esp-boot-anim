/** @file
  BaFallback.c -- 内置兜底动画（完全不需要任何素材文件）。

  用途：即使 ESP 上一个帧数据都没有（或者文件坏了），开机画面也一定是
  一段正常的、平滑的"转圈"动画，而不是黑屏、花屏或卡住。

  BaFallbackRender() 是纯函数（只操作一块 BGRX 内存），可以在 PC 上
  直接单元测试；BaFallbackPlay() 负责把它送上屏幕。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

/* 注意：本文件刻意只依赖 Ba.h / BaPlat.h，不包含 BaUefi.h，
   这样 BaFallbackRender 与 BaFallbackPlay 都能在 PC 上测试。 */
#include "BaPlat.h"

#define BA_FB_FRAMES 60u
#define BA_FB_FPS    30u
#define BA_FB_DOTS   5u

/* ================================================================== */
/* 数学小工具                                                         */
/* ================================================================== */
static BA_U32
BaISqrt (
  BA_U32 V
  )
{
  BA_U32 R   = 0;
  BA_U32 Bit = 1u << 30;

  while (Bit > V) {
    Bit >>= 2;
  }
  while (Bit != 0) {
    if (V >= R + Bit) {
      V -= R + Bit;
      R  = (R >> 1) + Bit;
    } else {
      R >>= 1;
    }
    Bit >>= 2;
  }
  return R;
}

/* Bhaskara 近似：x ∈ [0, Half] 时返回 sin(pi*x/Half) * 1024 */
static BA_I32
BaSinPart (
  BA_U32 X,
  BA_U32 Half
  )
{
  BA_I64 P;

  if (Half == 0) {
    return 0;
  }
  P = (BA_I64)X * (BA_I64)(Half - X);
  if (P <= 0) {
    return 0;
  }
  return (BA_I32)((16384LL * P) / (5LL * (BA_I64)Half * (BA_I64)Half - 4LL * P));
}

/* Phase ∈ [0, Period) 的正弦，返回 -1024..1024 */
static BA_I32
BaSinQ10 (
  BA_U32 Phase,
  BA_U32 Period
  )
{
  BA_U32 Half;

  if (Period < 2u) {
    return 0;
  }
  Half  = Period / 2u;
  Phase = Phase % Period;
  if (Phase < Half) {
    return BaSinPart (Phase, Half);
  }
  return -BaSinPart (Phase - Half, Half);
}

/* ================================================================== */
/* 绘制                                                               */
/* ================================================================== */
/* 把 Src 色按 Alpha(0..256) 混到 Dst 指向的 BGRX 像素上。
   打包约定：bit0..7 = Blue, bit8..15 = Green, bit16..23 = Red
   （与 BGRX 内存布局一致；小端机上数值恰好是 0x00RRGGBB）。 */
static void
BaBlendPixel (
  BA_U8  *Dst,
  BA_U32  Src,
  BA_U32  Alpha
  )
{
  BA_U32 SB;
  BA_U32 SG;
  BA_U32 SR;
  BA_U32 A;
  BA_U32 IA;

  if (Alpha == 0) {
    return;
  }
  A  = (Alpha > 256u) ? 256u : Alpha;
  IA = 256u - A;
  SB = Src & 0xFFu;
  SG = (Src >> 8) & 0xFFu;
  SR = (Src >> 16) & 0xFFu;

  Dst[0] = (BA_U8)((SB * A + (BA_U32)Dst[0] * IA) / 256u);
  Dst[1] = (BA_U8)((SG * A + (BA_U32)Dst[1] * IA) / 256u);
  Dst[2] = (BA_U8)((SR * A + (BA_U32)Dst[2] * IA) / 256u);
  Dst[3] = 0xFF;
}

/* 画一个带 1 像素抗锯齿边缘的实心圆 */
static void
BaDrawDot (
  BA_U8  *Buf,
  BA_U32  W,
  BA_U32  H,
  BA_U32  Stride,
  BA_I32  Cx,
  BA_I32  Cy,
  BA_I32  R,
  BA_U32  Color,
  BA_U32  Alpha
  )
{
  BA_I32 X0;
  BA_I32 X1;
  BA_I32 Y0;
  BA_I32 Y1;
  BA_I32 Y;
  BA_I32 RR;

  if ((R <= 0) || (Buf == NULL)) {
    return;
  }
  X0 = Cx - R - 1;
  X1 = Cx + R + 1;
  Y0 = Cy - R - 1;
  Y1 = Cy + R + 1;
  if (X0 < 0) {
    X0 = 0;
  }
  if (Y0 < 0) {
    Y0 = 0;
  }
  if (X1 > (BA_I32)W - 1) {
    X1 = (BA_I32)W - 1;
  }
  if (Y1 > (BA_I32)H - 1) {
    Y1 = (BA_I32)H - 1;
  }

  RR = R * R;

  for (Y = Y0; Y <= Y1; Y++) {
    BA_I32 X;
    BA_I32 Dy  = Y - Cy;
    BA_U8 *Row = Buf + (BA_SIZE)Y * Stride;

    for (X = X0; X <= X1; X++) {
      BA_I32 Dx  = X - Cx;
      BA_I32 D2  = Dx * Dx + Dy * Dy;
      BA_U32 Cov = 0;

      if (D2 > RR) {
        continue;
      }
      /* 覆盖率 cover = clamp(R - dist + 0.5, 0, 1)，用 0..256 表示。
         BaISqrt(D2*256) = dist*16，再乘 16 即 dist*256。 */
      {
        BA_U32 DistX16 = BaISqrt ((BA_U32)((BA_U32)D2 << 8));
        BA_I32 Cov256  = (BA_I32)R * 256 + 128 - (BA_I32)(DistX16 * 16);
        if (Cov256 <= 0) {
          continue;
        }
        if (Cov256 >= 256) {
          Cov256 = 256;
        }
        Cov = (BA_U32)Cov256;
      }
      BaBlendPixel (Row + (BA_SIZE)X * 4u, Color, (Alpha * Cov) / 256u);
    }
  }
}

/* ================================================================== */
/* 纯渲染函数                                                         */
/* ================================================================== */
void
BaFallbackRender (
  BA_U8  *Buf,
  BA_U32  W,
  BA_U32  H,
  BA_U32  Stride,
  BA_U32  Frame,
  BA_U32  FrameCount,
  BA_U32  BgBgrx
  )
{
  BA_U32       K;
  BA_I32       Cx;
  BA_I32       Cy;
  BA_I32       RingR;
  BA_I32       BaseR;
  BA_U32       Period;
  const BA_U32 DotColor = 0x000078D4u;   /* bit16..23=R=0x00, bit8..15=G=0x78, bit0..7=B=0xD4 -> 蓝色 #0078D4 */

  if ((Buf == NULL) || (W == 0) || (H == 0)) {
    return;
  }
  if (FrameCount == 0) {
    FrameCount = 1;
  }
  Frame %= FrameCount;

  BaImageFillBgrx (Buf, W, H, Stride, BgBgrx);

  Cx    = (BA_I32)(W / 2u);
  Cy    = (BA_I32)(H / 2u);
  RingR = (BA_I32)(H / 16u);          /* 环半径 ≈ 屏幕高的 6.25% */
  if (RingR < 8) {
    RingR = 8;
  }
  BaseR = (BA_I32)(H / 90u);          /* 基准点半径 ≈ 屏幕高的 1.1% */
  if (BaseR < 3) {
    BaseR = 3;
  }

  Period = FrameCount * 32u;          /* 一整轮明暗循环的相位刻度 */

  for (K = 0; K < BA_FB_DOTS; K++) {
    /* 5 颗点固定在 72° 间隔上，"明暗+大小"的相位依次滞后 -> 追尾效果 */
    BA_U32 Ph       = ((Frame * 32u) + (Period / BA_FB_DOTS) * (BA_FB_DOTS - 1u - K)) % Period;
    BA_I32 S        = BaSinQ10 (Ph, Period);        /* -1024..1024 */
    BA_U32 AngPhase = (BA_U32)(((BA_U32)2048u * K / BA_FB_DOTS) % 2048u);
    BA_I32 Cos      = BaSinQ10 ((BA_U32)((AngPhase + 512u) % 2048u), 2048u);
    BA_I32 Sin      = BaSinQ10 (AngPhase, 2048u);
    BA_I32 Rad;
    BA_U32 Alpha;
    BA_I32 Dx;
    BA_I32 Dy;

    /* 大小在 BaseR..2*BaseR 之间呼吸 */
    Rad = BaseR + (BA_I32)(((BA_I64)(S + 1024) * (BA_I64)BaseR) / (2 * 1024));
    if (Rad < 2) {
      Rad = 2;
    }
    /* 亮度在 160..256 之间呼吸 */
    Alpha = (BA_U32)(160 + ((S + 1024) * 96) / 2048);

    Dx = (BA_I32)(((BA_I64)Cos * (BA_I64)RingR) / 1024);
    Dy = (BA_I32)(((BA_I64)Sin * (BA_I64)RingR) / 1024);

    BaDrawDot (Buf, W, H, Stride, Cx + Dx, Cy + Dy, Rad, DotColor, Alpha);
  }
}

/* ================================================================== */
/* 播放                                                               */
/* ================================================================== */
BA_STATUS
BaFallbackPlay (
  BA_GFX          *G,
  const BA_CONFIG *Cfg
  )
{
  BA_U8  *Buf;
  BA_U32  W;
  BA_U32  H;
  BA_U32  Frame;
  BA_U32  Total;
  BA_U32  BgBgrx;
  BA_U32  Pacing;
  BA_U64  StartMs;
  BA_U32  FrameMs = (1000u + BA_FB_FPS / 2u) / BA_FB_FPS;

  if ((G == BA_NULL) || !BaGfxValid (G)) {
    return BA_ERR_UNSUPPORTED;
  }
  W = G->Width;
  H = G->Height;

  BgBgrx = 0xFF000000u;
  if (Cfg != BA_NULL) {
    BgBgrx |= (Cfg->Background & 0x00FFFFFFu);
  }

  Buf = (BA_U8 *)BaAlloc ((BA_SIZE)W * (BA_SIZE)H * 4u);
  if (Buf == BA_NULL) {
    return BA_ERR_NO_MEMORY;
  }

  Total = BA_FB_FRAMES;
  if ((Cfg != BA_NULL) && (Cfg->TimeoutMs != 0)) {
    BA_U32 MaxFrames = (Cfg->TimeoutMs * BA_FB_FPS) / 1000u;
    if (MaxFrames == 0) {
      MaxFrames = 1;
    }
    if (MaxFrames < Total) {
      Total = MaxFrames;
    }
  }

  BaPrintNum ("bootanim: fallback frames=", Total);

  Pacing = (Cfg != BA_NULL) ? Cfg->Pacing : BA_PACING_AUTO;
  if (Pacing > BA_PACING_OFF) {
    Pacing = BA_PACING_AUTO;
  }

  StartMs = BaTicksMs ();
  for (Frame = 0; Frame < Total; Frame++) {
    BA_U64  Elapsed = (StartMs != 0) ? (BaTicksMs () - StartMs) : (BA_U64)Frame * FrameMs;
    BA_U64  T0 = 0;
    BA_BOOL UseHiRes = (BA_BOOL)((Pacing == BA_PACING_AUTO) && BaTimeIsExact ());

    if (UseHiRes) {
      T0 = BaTimeNow ();
    }

    BaFallbackRender (Buf, W, H, W * 4u, Frame, BA_FB_FRAMES, BgBgrx);
    BaGfxDraw (G, Buf, W, H, BA_SCALE_NATIVE, BA_FILTER_NEAREST, BgBgrx);

    if ((Cfg != BA_NULL) && (Cfg->SkipKey != 0) && (Elapsed > 400u)) {
      if (BaKeyPressed ()) {
        break;
      }
    }
    if ((Cfg != BA_NULL) && (Cfg->TimeoutMs != 0) &&
        (Elapsed > (BA_U64)Cfg->TimeoutMs + 3000u))
    {
      break;
    }

    /* 与 BaAnimPlay 相同的节拍策略：只补足差额 */
    if (Pacing != BA_PACING_OFF) {
      if (UseHiRes) {
        BA_U64 UsedMs = (BaTimeNow () - T0) / (BA_U64)BaTimeTicksPerMs ();
        if (UsedMs < (BA_U64)FrameMs) {
          BaStallMs ((BA_U32)((BA_U64)FrameMs - UsedMs));
        }
      } else {
        BaStallMs (FrameMs);
      }
    }
  }

  BaFree (Buf);
  return BA_OK;
}
