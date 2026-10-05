/** @file
  Ba.h -- ESP 开机动画程序 (BootAnim) 的公共定义。

  本文件以及 BaImage.c / BaConfig.c 完全不依赖 UEFI 头文件，
  因此可以在普通 PC 上用任何 C 编译器编译并做单元测试
  (见 tools/hosttest)。UEFI 相关的部分隔离在 BaPlat.h / BaUefi.h 里。

  二进制帧容器格式 (.baa) 的权威定义见 tools/baanim.py，
  那里的 Python 实现已经通过 887 项自检（含 3000 次损坏文件模糊测试），
  BaImage.c 里的解码器是它的逐字节等价移植。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#ifndef BA_H_
#define BA_H_

/* ------------------------------------------------------------------ */
/* 基础类型：不依赖任何系统头文件，保证 32/64 位下宽度一致             */
/* ------------------------------------------------------------------ */
typedef unsigned char      BA_U8;
typedef unsigned short     BA_U16;   /* 同时用作 CHAR16 */
typedef unsigned int       BA_U32;
typedef unsigned long long BA_U64;
typedef unsigned long long BA_SIZE;  /* 字节数/长度 */
typedef int                BA_BOOL;
typedef signed int         BA_I32;
typedef signed long long   BA_I64;

#define BA_TRUE   1
#define BA_FALSE  0

#define BA_NULL   ((void *)0)

/* ------------------------------------------------------------------ */
/* 状态码                                                             */
/* ------------------------------------------------------------------ */
typedef int BA_STATUS;

#define BA_OK               0
#define BA_ERR_NOT_FOUND    1
#define BA_ERR_IO           2
#define BA_ERR_FORMAT       3
#define BA_ERR_NO_MEMORY    4
#define BA_ERR_UNSUPPORTED  5
#define BA_ERR_INVALID      6
#define BA_ERR_TRUNCATED    7
#define BA_ERR_RLE          8
#define BA_ERR_TOO_BIG      9

/* ------------------------------------------------------------------ */
/* 尺寸上限（防御损坏/恶意文件导致的巨额内存申请）                     */
/* ------------------------------------------------------------------ */
#define BA_MAX_PIXELS      (8192u * 8192u)
#define BA_MAX_FRAMES      100000u
#define BA_PATH_MAX        260
#define BA_MAX_FRAME_BYTES (64u * 1024u * 1024u)   /* 单帧 64MB，足够 4K RGBA */

/* ------------------------------------------------------------------ */
/* 缩放 / 滤波模式                                                    */
/* ------------------------------------------------------------------ */
#define BA_SCALE_NATIVE    0   /* 1:1 居中（源比屏幕大时居中裁剪） */
#define BA_SCALE_FIT       1   /* 等比缩放到完全可见，四周留背景 */
#define BA_SCALE_FILL      2   /* 等比缩放到填满屏幕，超出部分裁剪 */
#define BA_SCALE_STRETCH   3   /* 直接拉伸，不保持宽高比 */
#define BA_SCALE_CENTER    4   /* BA_SCALE_NATIVE 的别名 */

#define BA_FILTER_AUTO     0   /* 源与目标同尺寸时走直通，否则双线性 */
#define BA_FILTER_NEAREST  1
#define BA_FILTER_BILINEAR 2

/* ------------------------------------------------------------------ */
/* 帧节拍方式                                                         */
/* ------------------------------------------------------------------ */
/* auto  : 有高精度计时（x86 TSC）时"补足"到目标帧间隔，否则退化为 fixed。
           这是默认值 —— 渲染再慢也不会把帧间隔额外拖长。 */
#define BA_PACING_AUTO     0
/* fixed : 每渲染完一帧再固定延时 FrameMs（1.0.0 的旧行为，会把渲染时间叠加） */
#define BA_PACING_FIXED    1
/* off   : 完全不等，能多快就多快 */
#define BA_PACING_OFF      2

/* ------------------------------------------------------------------ */
/* 配置文件                                                           */
/* ------------------------------------------------------------------ */
typedef struct {
  BA_U16  Anim[BA_PATH_MAX];              /* 帧数据文件；空 = 自动探测 */
  BA_U16  Chainload[BA_PATH_MAX];         /* 主链式引导目标 */
  BA_U16  ChainloadFallback[BA_PATH_MAX]; /* 备用链式引导目标 */
  BA_U32  Frames;        /* BMP 序列模式下的帧数；0 = 自动探测 */
  BA_U32  Enabled;       /* 0 = 完全不播动画，直接交回引导程序（临时开关） */
  BA_U32  Fps;           /* 0 = 用 .baa 头里的值，再不行用 30 */
  BA_U32  Loop;          /* 循环播放次数，0 = 一直播到 TIMEOUT_MS */
  BA_U32  Pacing;        /* BA_PACING_* */
  BA_U32  Scale;         /* BA_SCALE_* */
  BA_U32  Filter;        /* BA_FILTER_* */
  BA_U32  Background;    /* 0x00RRGGBB */
  BA_U32  TimeoutMs;     /* 整个动画的最长时长，0 = 不限制 */
  BA_U32  LeadInMs;      /* 开播前等待，0 = 立刻 */
  BA_U32  SkipKey;       /* 1 = 任意按键立即结束动画 */
  BA_U32  Debug;         /* 1 = 输出诊断信息到控制台 */
  BA_U32  ClearFirst;    /* 1 = 先清屏（擦掉固件厂商 logo） */
  BA_U32  VideoWidth;    /* 期望的视频模式宽；0 = 不切换 */
  BA_U32  VideoHeight;
} BA_CONFIG;

void      BaConfigDefault (BA_CONFIG *Cfg);
BA_STATUS BaConfigParse   (const char *Text, BA_SIZE Len, BA_CONFIG *Cfg);

/* ------------------------------------------------------------------ */
/* 图像 / 解码                                                        */
/* ------------------------------------------------------------------ */
typedef struct {
  BA_U32 X;
  BA_U32 Y;
  BA_U32 W;
  BA_U32 H;
} BA_RECT;

/* 双线性采样抽头，F 为 0..65535 的小数部分 */
typedef struct {
  BA_U32 I0;
  BA_U32 I1;
  BA_U32 F;
} BA_TAP;

typedef struct {
  BA_U32  SrcX0;   /* 采样区域在源图中的左上角 */
  BA_U32  SrcY0;
  BA_U32  SrcW;    /* 采样区域尺寸 */
  BA_U32  SrcH;
  BA_U32  DstW;
  BA_U32  DstH;
  BA_TAP *XT;      /* 长度 >= DstW，调用方提供 */
  BA_TAP *YT;      /* 长度 >= DstH，调用方提供 */
} BA_SCALER;

/* BMP 头解析：只取出宽高，不分配内存 */
BA_STATUS BaBmpProbe  (const BA_U8 *Data, BA_SIZE Size, BA_U32 *Width, BA_U32 *Height);

/* BMP 解码成 BGRX(4字节/像素, 自上而下)。Out 必须能容纳 Width*Height*4 字节。
   Width/Height 由 BaBmpProbe 得到。 */
BA_STATUS BaBmpDecode (const BA_U8 *Data, BA_SIZE Size, BA_U8 *Out,
                       BA_U32 Width, BA_U32 Height);

/* BAANIM01 包流的 RLE 解码。
   DstSize 必须等于 像素数*4；成功时通过 Used 返回消耗的源字节数。 */
BA_STATUS BaRleDecode (const BA_U8 *Src, BA_SIZE SrcSize,
                       BA_U8 *Dst, BA_SIZE DstSize, BA_SIZE *Used);

typedef struct {
  BA_U32 HeaderSize;
  BA_U32 FrameCount;
  BA_U32 Width;
  BA_U32 Height;
  BA_U32 Fps;
  BA_U32 Flags;
} BA_BAA_HEADER;

#define BA_BAA_FLAG_RLE 0x00000001u
#define BA_BAA_HEADER_MIN 64u
#define BA_BAA_MAGIC "BAANIM01"

/* 解析 .baa 头（只读前 64 字节，足够） */
BA_STATUS BaBaaParseHeader (const BA_U8 *Hdr, BA_SIZE Size, BA_BAA_HEADER *Out);

/* 取得第 Index 帧在文件中的偏移与长度（用于流式读取） */
BA_STATUS BaBaaFrameLoc   (const BA_U8 *IdxEntry, BA_SIZE IdxSize, BA_SIZE FileSize,
                           const BA_BAA_HEADER *Hdr, BA_U32 Index,
                           BA_U64 *Offset, BA_U32 *Length);

/* 把一帧（Raw = 索引指向的原始负载）解码到 Out（Width*Height*4 字节） */
BA_STATUS BaBaaDecodeFrame (const BA_U8 *Raw, BA_SIZE RawSize,
                            const BA_BAA_HEADER *Hdr, BA_U8 *Out, BA_SIZE OutSize);

/* 计算在 DstW x DstH 里放置 SrcW x SrcH 图像时的目标矩形与源裁剪矩形。
   两个输出矩形必然满足：DstRect 完全落在 [0,DstW)x[0,DstH) 内，
   SrcRect 完全落在 [0,SrcW)x[0,SrcH) 内。 */
BA_STATUS BaImageFitRect (BA_U32 SrcW, BA_U32 SrcH, BA_U32 DstW, BA_U32 DstH,
                          BA_U32 ScaleMode, BA_RECT *DstRect, BA_RECT *SrcRect);

/* 初始化缩放抽头。XT 至少 DstW 项，YT 至少 DstH 项。
   SrcX0/SrcY0/SrcW/SrcH 描述源图中要采样的区域。 */
BA_STATUS BaScalerInit (BA_SCALER *S, BA_U32 SrcX0, BA_U32 SrcY0,
                        BA_U32 SrcW, BA_U32 SrcH, BA_U32 DstW, BA_U32 DstH,
                        BA_TAP *XT, BA_TAP *YT);

/* 生成目标第 DstY 行（DstW 个 BGRX 像素）到 Row。
   SrcStride 为源图每行字节数（通常 SrcW*4）。 */
void      BaScalerRow  (const BA_SCALER *S, const BA_U8 *Src, BA_U32 SrcStride,
                        BA_U32 DstY, BA_U8 *Row, BA_U32 Filter);

/* 用 BGRX 色值填满一块缓冲（Stride 为每行字节数） */
void      BaImageFillBgrx (BA_U8 *Dst, BA_U32 W, BA_U32 H, BA_U32 Stride, BA_U32 Bgrx);

/* ------------------------------------------------------------------ */
/* 小工具                                                             */
/* ------------------------------------------------------------------ */
void   BaMemSet  (void *Dst, BA_U8 Val, BA_SIZE Len);
void   BaMemCopy (void *Dst, const void *Src, BA_SIZE Len);
BA_I32 BaMemCmp  (const void *A, const void *B, BA_SIZE Len);
BA_SIZE BaStrLen16 (const BA_U16 *S);
BA_SIZE BaStrLenA  (const char *S);
int    BaStrEq16   (const BA_U16 *A, const BA_U16 *B);          /* 全部相等 */
int    BaStrEqNoCase16 (const BA_U16 *A, const BA_U16 *B);
int    BaStrEqNoCaseA  (const char *A, const char *B);
void   BaStrCopy16 (BA_U16 *Dst, BA_SIZE Cap, const BA_U16 *Src);
void   BaStrCopyA16 (BA_U16 *Dst, BA_SIZE Cap, const char *Src);
/* UTF-8 -> UTF-16，返回写入的码元数（不含结尾 0） */
BA_SIZE BaUtf8ToUtf16 (BA_U16 *Dst, BA_SIZE Cap, const char *Src, BA_SIZE SrcLen);
/* 取路径中的文件名部分（"\\EFI\\Boot\\a.efi" -> "a.efi"） */
const BA_U16 *BaPathBase (const BA_U16 *Path);

#endif /* BA_H_ */
