/** @file
  main.c -- BootAnim 的 PC 端自测程序。

  目的：在**没有 EDK2、没有真机**的情况下，用本机编译器把 src/ 里跟 UEFI
        无关的全部逻辑跑一遍，并且跟 tools/baanim.py（Python 参考实现，
        已通过 887 项自检）产生的数据逐字节比对。

  编译运行：
      cd tools/hosttest
      make            # 或者手动： cc -I../../src main.c BaPlatHost.c \
                      #   ../../src/BaUtil.c ../../src/BaConfig.c \
                      #   ../../src/BaImage.c ../../src/BaAnim.c \
                      #   ../../src/BaFallback.c -o hosttest
      python ../selftest.py      # 先生成 _testdata/ 里的比对数据
      ./hosttest                 # 默认读 ../_testdata

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "Ba.h"
#include "BaPlat.h"

/* BaPlatHost.c 提供的探针与工具 */
extern BA_U32 gHostGfxDrawCalls;
extern BA_U32 gHostGfxClearCalls;
extern BA_U32 gHostLastDrawW;
extern BA_U32 gHostLastDrawH;
extern BA_U32 gHostLastDrawScale;
extern BA_U8 *gHostLastFrame[2];
void HostSetOwnDir (const char *Utf8Dir);

static int gPass = 0;
static int gFail = 0;

#define CHECK(cond, what)                                                  \
  do {                                                                     \
    if (cond) {                                                            \
      gPass++;                                                             \
    } else {                                                               \
      gFail++;                                                             \
      printf ("  FAIL: %s  (%s:%d)\n", (what), __FILE__, __LINE__);        \
    }                                                                      \
  } while (0)

/* ------------------------------------------------------------------ */
static unsigned char *
ReadWholeFile (
  const char *Path,
  size_t     *SizeOut
  )
{
  FILE          *Fp;
  unsigned char *Buf;
  long           Sz;

  *SizeOut = 0;
  Fp = fopen (Path, "rb");
  if (Fp == NULL) {
    return NULL;
  }
  if (fseek (Fp, 0, SEEK_END) != 0) {
    fclose (Fp);
    return NULL;
  }
  Sz = ftell (Fp);
  if (Sz <= 0) {
    fclose (Fp);
    return NULL;
  }
  rewind (Fp);
  Buf = (unsigned char *)malloc ((size_t)Sz);
  if (Buf == NULL) {
    fclose (Fp);
    return NULL;
  }
  if (fread (Buf, 1, (size_t)Sz, Fp) != (size_t)Sz) {
    free (Buf);
    fclose (Fp);
    return NULL;
  }
  fclose (Fp);
  *SizeOut = (size_t)Sz;
  return Buf;
}

static char gDir[1024];

/* 把数据目录变成绝对路径，避免因为 CWD 不同而找不到文件 */
static void
MakeAbs (
  const char *In,
  char       *Out,
  size_t      Cap
  )
{
#if defined(_WIN32)
  if (_fullpath (Out, In, Cap) != NULL) {
    return;
  }
#else
  {
    char *Rp = realpath (In, NULL);
    if (Rp != NULL) {
      snprintf (Out, Cap, "%s", Rp);
      free (Rp);
      return;
    }
  }
#endif
  snprintf (Out, Cap, "%s", In);
}

static void
JoinPath (
  char       *Out,
  size_t      Cap,
  const char *Name
  )
{
  snprintf (Out, Cap, "%s/%s", gDir, Name);
}

/* ================================================================== */
/* 1. .baa 解码 vs Python 参考输出                                    */
/* ================================================================== */
static void
TestBaaDecode (void)
{
  static const char *Cases[2][2] = {
    { "test_rle.baa", "test_rle.expected" },
    { "test_raw.baa", "test_rle.expected" },   /* 同一批帧，未压缩版本 */
  };
  int C;

  printf ("[1] .baa 解码与 Python 参考输出逐字节比对\n");

  for (C = 0; C < 2; C++) {
    char           Path[1200];
    size_t         BlobSize = 0;
    unsigned char *Blob;
    BA_BAA_HEADER  Hdr;
    BA_STATUS      St;
    size_t         ExpSize = 0;
    unsigned char *Exp;
    unsigned       I;
    BA_U32         FrameBytes;

    JoinPath (Path, sizeof (Path), Cases[C][0]);
    Blob = ReadWholeFile (Path, &BlobSize);
    if (Blob == NULL) {
      printf ("  跳过 %s（没找到，请先运行 python ../selftest.py）\n", Path);
      continue;
    }
    St = BaBaaParseHeader (Blob, (BA_SIZE)BlobSize, &Hdr);
    CHECK (St == BA_OK, "BaBaaParseHeader 应成功");
    if (St != BA_OK) {
      free (Blob);
      continue;
    }
    CHECK (Hdr.FrameCount == 20, "帧数应为 20");
    CHECK (Hdr.Width == 64 && Hdr.Height == 48, "尺寸应为 64x48");
    CHECK (Hdr.Fps == 24, "fps 应为 24");

    JoinPath (Path, sizeof (Path), Cases[C][1]);
    Exp = ReadWholeFile (Path, &ExpSize);
    if (Exp == NULL) {
      free (Blob);
      continue;
    }

    FrameBytes = Hdr.Width * Hdr.Height * 4u;
    CHECK ((size_t)Hdr.FrameCount * FrameBytes == ExpSize,
           "期望数据大小 = 帧数 x 帧字节");

    for (I = 0; I < Hdr.FrameCount; I++) {
      unsigned char IdxEntry[8];
      BA_U64        Off = 0;
      BA_U32        Len = 0;
      unsigned char *Raw;
      unsigned char *Out;

      memcpy (IdxEntry, Blob + Hdr.HeaderSize + (size_t)I * 8u, 8);
      St = BaBaaFrameLoc (IdxEntry, 8, (BA_SIZE)BlobSize, &Hdr, I, &Off, &Len);
      if (St != BA_OK) {
        CHECK (0, "BaBaaFrameLoc 应成功");
        break;
      }
      Raw = (unsigned char *)malloc (Len);
      Out = (unsigned char *)malloc (FrameBytes);
      if ((Raw == NULL) || (Out == NULL)) {
        free (Raw);
        free (Out);
        break;
      }
      memcpy (Raw, Blob + Off, Len);
      St = BaBaaDecodeFrame (Raw, Len, &Hdr, Out, FrameBytes);
      if (St != BA_OK) {
        CHECK (0, "BaBaaDecodeFrame 应成功");
      } else if (memcmp (Out, Exp + (size_t)I * FrameBytes, FrameBytes) != 0) {
        CHECK (0, "帧内容应与 Python 输出完全一致");
      } else {
        CHECK (1, "帧一致");
      }
      free (Raw);
      free (Out);
    }

    printf ("  %-14s %u 帧全部比对完成\n", Cases[C][0], (unsigned)Hdr.FrameCount);
    free (Blob);
    free (Exp);
  }
}

/* ================================================================== */
/* 2. RLE 损坏检测                                                    */
/* ================================================================== */
static void
TestRleErrors (void)
{
  unsigned char Out[64];
  BA_SIZE       Used = 0;

  printf ("[2] RLE 边界与损坏检测\n");

  /* 重复包：0x82 -> 重复 4 次 */
  {
    unsigned char Src[5] = { 0x82, 0x11, 0x22, 0x33, 0x44 };
    CHECK (BaRleDecode (Src, 5, Out, 16, &Used) == BA_OK, "合法重复包");
    CHECK (Out[0] == 0x11 && Out[15] == 0x44, "重复包内容正确");
    CHECK (Used == 5, "消耗字节数正确");
  }
  /* 字面量包：0x00 -> 1 个像素 */
  {
    unsigned char Src[5] = { 0x00, 0xAA, 0xBB, 0xCC, 0xDD };
    CHECK (BaRleDecode (Src, 5, Out, 4, &Used) == BA_OK, "合法字面量包");
    CHECK (Out[0] == 0xAA && Out[3] == 0xDD, "字面量内容正确");
  }
  /* 截断：字面量包声明 2 个像素但只有 4 字节 */
  {
    unsigned char Src[5] = { 0x01, 0x01, 0x02, 0x03, 0x04 };
    CHECK (BaRleDecode (Src, 5, Out, 8, &Used) != BA_OK, "截断必须报错");
  }
  /* 提前结束：输出还没满输入就没了 */
  {
    unsigned char Src[1] = { 0x00 };
    CHECK (BaRleDecode (Src, 1, Out, 8, &Used) != BA_OK, "包流不足必须报错");
  }
  /* 溢出：重复包会写出超过目标长度的像素 */
  {
    unsigned char Src[5] = { 0xFF, 0x01, 0x02, 0x03, 0x04 };  /* 129 个像素 */
    CHECK (BaRleDecode (Src, 5, Out, 16, &Used) != BA_OK, "写出越界必须报错");
  }
  /* 目标长度不是 4 的倍数 */
  {
    unsigned char Src[5] = { 0x00, 0x01, 0x02, 0x03, 0x04 };
    CHECK (BaRleDecode (Src, 5, Out, 5, &Used) != BA_OK, "目标长度非法必须报错");
  }
}

/* ================================================================== */
/* 3. BMP 解码 vs Pillow 输出                                         */
/* ================================================================== */
static void
TestBmpDecode (void)
{
  static const char *Cases[4] = { "bmp24", "bmp32", "bmp8", "bmp1" };
  int C;

  printf ("[3] BMP 解码与 Pillow 的 BGRX 输出逐字节比对\n");

  for (C = 0; C < 4; C++) {
    char           Path[1200];
    size_t         BmpSize = 0;
    size_t         ExpSize = 0;
    unsigned char *Bmp;
    unsigned char *Exp;
    unsigned char *Out;
    BA_U32         W = 0;
    BA_U32         H = 0;
    BA_STATUS      St;

    snprintf (Path, sizeof (Path), "%s/%s.bmp", gDir, Cases[C]);
    Bmp = ReadWholeFile (Path, &BmpSize);
    if (Bmp == NULL) {
      printf ("  跳过 %s（没找到）\n", Path);
      continue;
    }
    St = BaBmpProbe (Bmp, (BA_SIZE)BmpSize, &W, &H);
    CHECK (St == BA_OK, "BaBmpProbe 应成功");
    if (St != BA_OK) {
      free (Bmp);
      continue;
    }
    Out = (unsigned char *)malloc ((size_t)W * H * 4u);
    Exp = NULL;
    snprintf (Path, sizeof (Path), "%s/%s.bgrx", gDir, Cases[C]);
    Exp = ReadWholeFile (Path, &ExpSize);
    CHECK (Exp != NULL, "应能找到期望数据");
    CHECK (Out != NULL, "应能分配输出缓冲");
    if ((Out == NULL) || (Exp == NULL)) {
      free (Bmp);
      free (Out);
      free (Exp);
      continue;
    }
    CHECK (ExpSize == (size_t)W * H * 4u, "期望数据大小应与图片尺寸匹配");

    St = BaBmpDecode (Bmp, (BA_SIZE)BmpSize, Out, W, H);
    CHECK (St == BA_OK, "BaBmpDecode 应成功");
    if (St == BA_OK) {
      CHECK (memcmp (Out, Exp, ExpSize) == 0, "BMP 解码结果应与 Pillow 一致");
      printf ("  %-6s %ux%u  %s\n", Cases[C], (unsigned)W, (unsigned)H,
              (memcmp (Out, Exp, ExpSize) == 0) ? "一致" : "不一致");
    }

    /* 尺寸参数不匹配时必须拒绝（防止越界写） */
    if (W > 1) {
      St = BaBmpDecode (Bmp, (BA_SIZE)BmpSize, Out, W - 1, H);
      CHECK (St != BA_OK, "宽高不匹配时必须拒绝");
    }

    free (Bmp);
    free (Out);
    free (Exp);
  }
}

/* ================================================================== */
/* 4. 配置文件解析                                                    */
/* ================================================================== */
static void
TestConfig (void)
{
  char           Path[1200];
  size_t         Size = 0;
  unsigned char *Text;
  BA_CONFIG      Cfg;
  BA_U16         Want[BA_PATH_MAX];

  printf ("[4] bootanim.cfg 解析\n");

  snprintf (Path, sizeof (Path), "%s/sample.cfg", gDir);
  Text = ReadWholeFile (Path, &Size);
  if (Text == NULL) {
    printf ("  跳过（没找到 %s）\n", Path);
    return;
  }

  BaConfigDefault (&Cfg);
  CHECK (BaConfigParse ((const char *)Text, (BA_SIZE)Size, &Cfg) == BA_OK, "解析应成功");

  BaStrCopyA16 (Want, BA_PATH_MAX, "anim.baa");
  CHECK (BaStrEq16 (Cfg.Anim, Want), "ANIM");
  CHECK (Cfg.Fps == 24, "FPS=24");
  CHECK (Cfg.Loop == 1, "LOOP=1");
  CHECK (Cfg.Pacing == BA_PACING_FIXED, "PACING=fixed");
  CHECK (Cfg.Scale == BA_SCALE_FILL, "SCALE=fill");
  CHECK (Cfg.Filter == BA_FILTER_NEAREST, "FILTER=nearest");
  CHECK (Cfg.Background == 0x123456u, "BACKGROUND=123456");
  CHECK (Cfg.TimeoutMs == 9000, "TIMEOUT_MS=9000");
  CHECK (Cfg.LeadInMs == 50, "LEAD_IN_MS=50");
  CHECK (Cfg.SkipKey == 0, "SKIP_KEY=off");
  CHECK (Cfg.Debug == 1, "DEBUG=1");
  CHECK (Cfg.ClearFirst == 0, "CLEAR_FIRST=0");
  CHECK (Cfg.VideoWidth == 1024 && Cfg.VideoHeight == 768, "VIDEO_MODE=1024x768");
  BaStrCopyA16 (Want, BA_PATH_MAX, "\\EFI\\Microsoft\\Boot\\bootmgfw-orig.efi");
  CHECK (BaStrEqNoCase16 (Cfg.Chainload, Want), "CHAINLOAD");
  BaStrCopyA16 (Want, BA_PATH_MAX, "\\EFI\\Microsoft\\Boot\\bootmgfw.efi");
  CHECK (BaStrEqNoCase16 (Cfg.ChainloadFallback, Want), "CHAINLOAD_FALLBACK");

  /* 各种边界都要能安全地解析（不能崩） */
  {
    static const char *Bad[] = {
      "", "\n\n\n", "= = =", "FPS", "FPS=", "FPS=abc", "FPS=99999999999999999999",
      "SCALE=", "BACKGROUND=zzz", "VIDEO_MODE=x", "VIDEO_MODE=0x0",
      "#comment only", "FRAMES=-1", "TIMEOUT_MS=0x10",
    };
    unsigned I;
    for (I = 0; I < sizeof (Bad) / sizeof (Bad[0]); I++) {
      BA_CONFIG T;
      BaConfigDefault (&T);
      CHECK (BaConfigParse (Bad[I], BaStrLenA (Bad[I]), &T) == BA_OK,
             "畸形配置不应导致失败");
    }
    /* 十六进制数字与 0x 颜色都要认 */
    {
      static const char HexCfg[] = "TIMEOUT_MS=0x10\n";
      BA_CONFIG T;
      BaConfigDefault (&T);
      CHECK (BaConfigParse (HexCfg, sizeof (HexCfg) - 1, &T) == BA_OK, "0x 数字解析");
      CHECK (T.TimeoutMs == 16, "0x10 应解析为 16");
    }
  }

  free (Text);
}

/* ================================================================== */
/* 5. 缩放 / 采样                                                     */
/* ================================================================== */
static void
TestScaler (void)
{
  BA_RECT Dr;
  BA_RECT Sr;

  printf ("[5] 目标矩形与缩放采样\n");

  CHECK (BaImageFitRect (100, 50, 100, 50, BA_SCALE_NATIVE, &Dr, &Sr) == BA_OK, "native 应成功");
  CHECK (Dr.W == 100 && Dr.H == 50 && Dr.X == 0 && Dr.Y == 0, "native 1:1");

  CHECK (BaImageFitRect (200, 100, 100, 100, BA_SCALE_NATIVE, &Dr, &Sr) == BA_OK, "native 过大");
  CHECK (Dr.W <= 100 && Dr.H <= 100, "native 过大时必须缩小以免越界");

  CHECK (BaImageFitRect (200, 100, 100, 100, BA_SCALE_FIT, &Dr, &Sr) == BA_OK, "fit");
  CHECK (Dr.W == 100 && Dr.H == 50 && Dr.X == 0 && Dr.Y == 25, "fit 居中留边");

  CHECK (BaImageFitRect (200, 100, 100, 100, BA_SCALE_FILL, &Dr, &Sr) == BA_OK, "fill");
  CHECK (Dr.W == 100 && Dr.H == 100, "fill 铺满");
  CHECK (Sr.W == 100 && Sr.H == 100 && Sr.X == 50, "fill 居中裁剪源图");

  CHECK (BaImageFitRect (200, 100, 100, 100, BA_SCALE_STRETCH, &Dr, &Sr) == BA_OK, "stretch");
  CHECK (Dr.W == 100 && Dr.H == 100 && Sr.W == 200, "stretch 不裁剪");

  /* 采样：2x2 放大到 4x4。四角分别是 黑 / 红 / 绿 / 蓝，
     放大后四个角必须各自保持原色（双线性的边界钳位行为）。 */
  {
    BA_U8     Src[16];
    BA_U8     Row[16];
    BA_TAP    XT[8];
    BA_TAP    YT[8];
    BA_SCALER S;

    memset (Src, 0, sizeof (Src));
    Src[0 * 4 + 2] = 0x00;   /* (0,0) 黑 */
    Src[1 * 4 + 2] = 0xFF;   /* (1,0) 红 */
    Src[2 * 4 + 1] = 0xFF;   /* (0,1) 绿 */
    Src[3 * 4 + 0] = 0xFF;   /* (1,1) 蓝 */

    CHECK (BaScalerInit (&S, 0, 0, 2, 2, 4, 4, XT, YT) == BA_OK, "ScalerInit 应成功");
    CHECK (S.DstW == 4 && S.DstH == 4, "ScalerInit 参数");

    BaScalerRow (&S, Src, 8, 0, Row, BA_FILTER_BILINEAR);
    CHECK (Row[0] == 0 && Row[1] == 0 && Row[2] == 0, "双线性：(0,0) 应为黑色");
    CHECK (Row[4 * 3 + 2] == 0xFF && Row[4 * 3 + 1] == 0, "双线性：(3,0) 应为红色");

    BaScalerRow (&S, Src, 8, 3, Row, BA_FILTER_BILINEAR);
    CHECK (Row[0] == 0 && Row[1] == 0xFF && Row[2] == 0, "双线性：(0,3) 应为绿色");
    CHECK (Row[4 * 3 + 0] == 0xFF && Row[4 * 3 + 2] == 0, "双线性：(3,3) 应为蓝色");

    BaScalerRow (&S, Src, 8, 3, Row, BA_FILTER_NEAREST);
    CHECK (Row[4 * 3 + 0] == 0xFF, "最近邻：(3,3) 应为蓝色");

    /* 故意给一个越界的 DstY，必须安全地什么都不做 */
    memset (Row, 0x5A, sizeof (Row));
    BaScalerRow (&S, Src, 8, 99, Row, BA_FILTER_BILINEAR);
    CHECK (Row[0] == 0x5A, "越界 DstY 不应写数据");
  }
}

/* ================================================================== */
/* 6. 内置兜底动画                                                    */
/* ================================================================== */
static void
TestFallback (void)
{
  BA_U32 W = 320;
  BA_U32 H = 240;
  BA_U32 Bg = 0xFF000000u;   /* 黑 */
  BA_U8 *F0;
  BA_U8 *F1;
  BA_U32 X;
  BA_U32 Diff = 0;
  BA_U32 NonBg = 0;

  printf ("[6] 内置兜底动画渲染\n");

  F0 = (BA_U8 *)malloc ((size_t)W * H * 4u);
  F1 = (BA_U8 *)malloc ((size_t)W * H * 4u);
  CHECK (F0 != NULL && F1 != NULL, "分配缓冲");
  if ((F0 == NULL) || (F1 == NULL)) {
    free (F0);
    free (F1);
    return;
  }

  BaFallbackRender (F0, W, H, W * 4u, 0, 60, Bg);
  BaFallbackRender (F1, W, H, W * 4u, 15, 60, Bg);

  /* 四角必须是背景色（点在中间，不会画到角上） */
  CHECK (memcmp (F0, &Bg, 4) == 0, "左上角是背景色");
  CHECK (memcmp (F0 + (size_t)(H - 1) * W * 4u, &Bg, 4) == 0, "左下角是背景色");
  CHECK (memcmp (F0 + (size_t)(W - 1) * 4u, &Bg, 4) == 0, "右上角是背景色");

  for (X = 0; X < W * H; X++) {
    if (memcmp (F0 + (size_t)X * 4u, &Bg, 4) != 0) {
      NonBg++;
    }
    if (memcmp (F0 + (size_t)X * 4u, F1 + (size_t)X * 4u, 4) != 0) {
      Diff++;
    }
  }
  printf ("  非背景像素 %u，两种帧之间的差异像素 %u\n",
          (unsigned)NonBg, (unsigned)Diff);
  CHECK (NonBg > 200, "应该真的画出了圆点");
  CHECK (NonBg < W * H / 4, "圆点不应该占满屏幕");
  CHECK (Diff > 100, "不同帧之间应该有变化");

  /* 极端尺寸不能崩 */
  {
    BA_U8 Small[4 * 4 * 4];
    BaFallbackRender (Small, 1, 1, 4, 0, 1, Bg);
    BaFallbackRender (Small, 4, 4, 16, 3, 60, Bg);
    CHECK (1, "极小尺寸不崩溃");
  }

  free (F0);
  free (F1);
}

/* ================================================================== */
/* 7. 端到端：BaAnimPlay 跑完整个 .baa                                */
/* ================================================================== */
static void
TestPlayEndToEnd (void)
{
  BA_CONFIG Cfg;
  BA_GFX    G;
  BA_STATUS St;
  BA_U32    Played = 0;
  BA_BOOL   Skipped = BA_FALSE;
  char      Path[1200];
  char      ExpPath[1200];
  size_t    ExpSize = 0;
  unsigned char *Exp;
  BA_U32    FrameBytes = 64u * 48u * 4u;

  printf ("[7] 端到端：BaAnimPlay 播放 test_rle.baa\n");

  snprintf (Path, sizeof (Path), "%s/test_rle.baa", gDir);
  if (ReadWholeFile (Path, &ExpSize) == NULL) {
    printf ("  跳过（没找到 %s）\n", Path);
    return;
  }
  snprintf (ExpPath, sizeof (ExpPath), "%s/test_rle.expected", gDir);
  Exp = ReadWholeFile (ExpPath, &ExpSize);
  if (Exp == NULL) {
    printf ("  跳过（没找到 %s）\n", ExpPath);
    return;
  }

  memset (&G, 0, sizeof (G));
  G.Gop    = (void *)1;      /* 让 BaGfxValid() 认为图形可用 */
  G.Width  = 64;
  G.Height = 48;

  BaConfigDefault (&Cfg);
  BaStrCopyA16 (Cfg.Anim, BA_PATH_MAX, Path);
  Cfg.Fps        = 240;      /* 跑快一点：240fps -> 每帧 4ms */
  Cfg.Loop       = 1;
  Cfg.TimeoutMs  = 0;        /* 0 + Loop!=0 => 不限制时间，只播一遍 */
  Cfg.SkipKey    = 0;
  Cfg.ClearFirst = 1;
  Cfg.Scale      = BA_SCALE_NATIVE;
  Cfg.Filter     = BA_FILTER_AUTO;
  Cfg.Debug      = 0;
  BaSetDebug (BA_FALSE);

  gHostGfxDrawCalls  = 0;
  gHostGfxClearCalls = 0;

  St = BaAnimPlay (&G, &Cfg, &Played, &Skipped);
  CHECK (St == BA_OK, "BaAnimPlay 应成功");
  CHECK (Played == 20, "应播放 20 帧");
  CHECK (gHostGfxDrawCalls == 20, "BaGfxDraw 应被调用 20 次");
  CHECK (gHostGfxClearCalls == 1, "CLEAR_FIRST=1 时应清屏一次");
  CHECK (Skipped == BA_FALSE, "不应被跳过");
  CHECK (gHostLastDrawW == 64 && gHostLastDrawH == 48, "绘制尺寸正确");
  CHECK (gHostLastDrawScale == BA_SCALE_NATIVE, "缩放模式被正确传递");

  if (gHostLastFrame[1] != NULL) {
    CHECK (memcmp (gHostLastFrame[1], Exp + 19u * FrameBytes, FrameBytes) == 0,
           "最后一帧内容应与 Python 输出一致");
  }
  if (gHostLastFrame[0] != NULL) {
    CHECK (memcmp (gHostLastFrame[0], Exp + 18u * FrameBytes, FrameBytes) == 0,
           "倒数第二帧内容应与 Python 输出一致");
  }

  /* 循环 2 遍 */
  Cfg.Loop = 2;
  gHostGfxDrawCalls = 0;
  St = BaAnimPlay (&G, &Cfg, &Played, &Skipped);
  CHECK (St == BA_OK && Played == 40, "LOOP=2 应播放 40 帧");

  /* 坏文件：不存在 */
  BaStrCopyA16 (Cfg.Anim, BA_PATH_MAX, "/definitely/not/here.baa");
  gHostGfxDrawCalls = 0;
  St = BaAnimPlay (&G, &Cfg, &Played, &Skipped);
  CHECK (St != BA_OK && Played == 0, "目标不存在时应失败且不播放任何帧");
  CHECK (gHostGfxDrawCalls == 0, "失败时不应调用 BaGfxDraw");

  free (Exp);
}

/* ================================================================== */
int
main (
  int   argc,
  char *argv[]
  )
{
  if (argc > 1) {
    MakeAbs (argv[1], gDir, sizeof (gDir));
  } else {
    MakeAbs ("../_testdata", gDir, sizeof (gDir));
  }
  /* 置空"本程序目录"，这样测试里给的绝对路径会被原样使用 */
  HostSetOwnDir ("");
  BaSetDebug (0);

  printf ("BootAnim PC 端自测  (数据目录: %s)\n", gDir);
  printf ("=========================================================\n");

  TestBaaDecode ();
  TestRleErrors ();
  TestBmpDecode ();
  TestConfig ();
  TestScaler ();
  TestFallback ();
  TestPlayEndToEnd ();

  printf ("=========================================================\n");
  printf ("%d passed, %d failed\n", gPass, gFail);
  return (gFail == 0) ? 0 : 1;
}
