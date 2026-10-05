/** @file
  BaPlat.h -- 与固件/平台相关的接口（实现见 BaPlatUefi.c / BaGfx.c / BaChain.c）。

  这里声明的函数不暴露任何 UEFI 类型，方便上层代码保持干净，
  也方便在 PC 上替换成桩实现。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#ifndef BA_PLAT_H_
#define BA_PLAT_H_

#include "Ba.h"

/* ------------------------------------------------------------------ */
/* 文件                                                               */
/* ------------------------------------------------------------------ */
typedef struct BaFile BA_FILE;

/* 路径为空/相对时，自动以本程序所在目录为基准 */
BA_STATUS BaFileOpen    (const BA_U16 *Path, BA_FILE **Out);
BA_STATUS BaFileSizeGet (BA_FILE *F, BA_U64 *Size);
BA_STATUS BaFileReadAt  (BA_FILE *F, BA_U64 Offset, void *Buf, BA_SIZE Len, BA_SIZE *Got);
void      BaFileClose   (BA_FILE *F);
BA_STATUS BaFileExists  (const BA_U16 *Path);
BA_STATUS BaFileLoadAll (const BA_U16 *Path, BA_U8 **Data, BA_SIZE *Size);
/* 只取大小（内部会开关文件一次） */
BA_STATUS BaFileSizeOf  (const BA_U16 *Path, BA_U64 *Size);
/* 读入调用方提供的缓冲；Cap 为缓冲容量，Got 为实际读到的字节数 */
BA_STATUS BaFileLoadInto (const BA_U16 *Path, void *Buf, BA_SIZE Cap, BA_SIZE *Got);
void      BaFileCloseAll (void);

/* ------------------------------------------------------------------ */
/* 内存 / 时间 / 输入 / 控制台                                        */
/* ------------------------------------------------------------------ */
/* ImageHandle / SystemTable 即 UEFI 入口的两个参数 */
BA_STATUS  BaPlatInit     (void *ImageHandle, void *SystemTable);
const BA_U16 *BaPlatOwnDir  (void);
const BA_U16 *BaPlatOwnPath (void);
/* 相对路径的解析基准目录（以 '\' 结尾）。
   默认等于 BaPlatOwnDir()；读配置文件成功后会切换成配置文件所在目录，
   这样 "ANIM=anim.baa" 之类的相对路径就能正确定位到素材。 */
void          BaSetAssetDir (const BA_U16 *Dir);
const BA_U16 *BaGetAssetDir (void);
BA_BOOL    BaPlatIsSecureBootOn (void);
/* 是否在启动时按住了 Shift 之类（本程序未使用，预留） */
BA_BOOL    BaPlatHasAnyKey (void);

void      *BaAlloc     (BA_SIZE Size);
void      *BaAllocZero (BA_SIZE Size);
void       BaFree      (void *Ptr);

void       BaStallMs   (BA_U32 Ms);
BA_U64     BaTicksMs   (void);
BA_BOOL    BaKeyPressed (void);

/* ---- 高精度计时（帧节拍补偿用）------------------------------------
   UEFI 的 Boot Services 里没有任何可用的高精度时钟（GetTime 只有秒级），
   所以 x86 上用 RDTSC，并用 gBS->Stall 自校准出 ticks/ms。
   校准失败时 BaTimeIsExact() 返回 FALSE，调用方退化为固定延时。 */
void       BaTimeInit       (void);
BA_BOOL    BaTimeIsExact    (void);
BA_U64     BaTimeNow        (void);  /* 单位 ticks；仅当 BaTimeIsExact() 为真时有意义 */
BA_U32     BaTimeTicksPerMs (void);

/* 控制台只用于诊断和致命错误；进入图形模式后应尽量静默 */
void       BaConsoleInit    (BA_BOOL Debug);
void       BaConsoleRestore (void);
void       BaSetDebug  (BA_BOOL On);
BA_BOOL    BaGetDebug  (void);
void       BaPrint     (const char *Text);
void       BaPrintNum  (const char *Label, BA_U32 Value);
void       BaPrintHex  (const char *Label, BA_U32 Value);

/* ------------------------------------------------------------------ */
/* 图形输出 (BaGfx.c)                                                 */
/* ------------------------------------------------------------------ */
#define BA_PF_NONE    0
#define BA_PF_BGRX    1   /* PixelBlueGreenRedReserved8BitPerColor (32bpp) */
#define BA_PF_RGBX    2   /* PixelRedGreenBlueReserved8BitPerColor (32bpp) */
#define BA_PF_MASK16  3
#define BA_PF_MASK24  4
#define BA_PF_MASK32  5
#define BA_PF_BLTONLY 6   /* 只能通过 Blt 输出，不能直接写显存 */

typedef struct {
  void   *Gop;            /* EFI_GRAPHICS_OUTPUT_PROTOCOL* */
  BA_U8  *Fb;             /* 显存基址，NULL = 不可直接写 */
  BA_U32  Width;
  BA_U32  Height;
  BA_U32  Stride;         /* 每行字节数 */
  BA_U32  Format;         /* BA_PF_* */
  BA_U32  Bpp;            /* 每像素字节数 */
  BA_U32  MaskR;
  BA_U32  MaskG;
  BA_U32  MaskB;
  BA_U32  ShiftR;
  BA_U32  ShiftG;
  BA_U32  ShiftB;
  BA_U32  BitsR;
  BA_U32  BitsG;
  BA_U32  BitsB;

  /* 8 位分量 -> 目标像素位的查找表（BGRX/RGBX 模式不使用） */
  BA_U32  MapR[256];
  BA_U32  MapG[256];
  BA_U32  MapB[256];
  BA_U32  MapA;

  /* 工作缓冲 */
  BA_U8  *RowBuf;         /* BGRX 行缓冲，Width 像素 */
  BA_U32  RowBufCap;
  BA_U8  *ConvBuf;        /* 目标像素格式行缓冲，Width 像素 */
  BA_U32  ConvBufCap;
  BA_TAP *XTaps;
  BA_U32  XTapCap;
  BA_TAP *YTaps;
  BA_U32  YTapCap;

  BA_SCALER Scaler;
  BA_BOOL   ScalerValid;
  BA_U32    CsSrcX;
  BA_U32    CsSrcY;
  BA_U32    CsSrcW;
  BA_U32    CsSrcH;
  BA_U32    CsDstW;
  BA_U32    CsDstH;
  BA_U32    CsFilter;
} BA_GFX;

BA_STATUS BaGfxInit     (BA_GFX *G, const BA_CONFIG *Cfg);
void      BaGfxShutdown (BA_GFX *G);
BA_BOOL   BaGfxValid    (const BA_GFX *G);
/* 用 BGRX 颜色清屏（若不可直接写显存则用 Blt 填充） */
void      BaGfxClear    (BA_GFX *G, BA_U32 Bgrx);
/* 把一张 BGRX 图像按 ScaleMode 呈现到屏幕上 */
void      BaGfxDraw     (BA_GFX *G, const BA_U8 *Src, BA_U32 SrcW, BA_U32 SrcH,
                         BA_U32 ScaleMode, BA_U32 Filter, BA_U32 BgBgrx);

/* ------------------------------------------------------------------ */
/* 动画播放 (BaAnim.c) / 兜底动画 (BaFallback.c)                      */
/* ------------------------------------------------------------------ */
/* 播放配置里指定的动画。PlayedFrames 返回实际播放的帧数（0 = 没有素材）。 */
BA_STATUS BaAnimPlay (BA_GFX *G, const BA_CONFIG *Cfg,
                      BA_U32 *PlayedFrames, BA_BOOL *Skipped);
/* 完全不带素材的内置动画：保证"即使什么都没放也一定有画面" */
BA_STATUS BaFallbackPlay (BA_GFX *G, const BA_CONFIG *Cfg);

/* ------------------------------------------------------------------ */
/* 链式引导 (BaChain.c)                                               */
/* ------------------------------------------------------------------ */
/* 成功把控制权交给目标映像时不会返回；返回一定是失败。 */
BA_STATUS BaChainload (const BA_U16 *Path, BA_BOOL *WasSelf);

#endif /* BA_PLAT_H_ */
