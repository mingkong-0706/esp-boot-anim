/** @file
  BaPlatHost.c -- 在 PC 上实现 BaPlat.h 的平台层，用来编译并测试 src/ 里
                  与 UEFI 无关的那些模块（BaImage / BaConfig / BaAnim /
                  BaFallback）。

  文件访问直接用 stdio，内存用 malloc，时间用 clock_gettime/time。
  BaGfxDraw / BaGfxClear 是计数用的桩：它们把"被画上去的最后一帧"留下来，
  测试程序可以拿它跟 Python 参考实现的输出逐字节比对。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "Ba.h"
#include "BaPlat.h"

/* ================================================================== */
/* 供测试程序读取的"探针"                                             */
/* ================================================================== */
BA_U32 gHostGfxDrawCalls = 0;
BA_U32 gHostGfxClearCalls = 0;
BA_U32 gHostLastDrawW = 0;
BA_U32 gHostLastDrawH = 0;
BA_U32 gHostLastDrawScale = 0;
BA_U8 *gHostLastFrame[2] = { NULL, NULL };   /* [0]=倒数第二帧 [1]=最后一帧 */
BA_U32 gHostLastFrameCap = 0;

/* ================================================================== */
/* 内存                                                               */
/* ================================================================== */
void *
BaAlloc (
  BA_SIZE Size
  )
{
  if (Size == 0) {
    return NULL;
  }
  return malloc ((size_t)Size);
}

void *
BaAllocZero (
  BA_SIZE Size
  )
{
  if (Size == 0) {
    return NULL;
  }
  return calloc (1, (size_t)Size);
}

void
BaFree (
  void *Ptr
  )
{
  free (Ptr);
}

/* ================================================================== */
/* 时间 / 输入                                                        */
/* ================================================================== */
void
BaStallMs (
  BA_U32 Ms
  )
{
  (void)Ms;   /* 测试时不真的等待，跑得快一点 */
}

BA_U64
BaTicksMs (
  void
  )
{
#if defined(CLOCK_MONOTONIC)
  struct timespec Ts;

  if (clock_gettime (CLOCK_MONOTONIC, &Ts) == 0) {
    return (BA_U64)Ts.tv_sec * 1000u + (BA_U64)(Ts.tv_nsec / 1000000);
  }
#endif
  return (BA_U64)time (NULL) * 1000u;
}

/* ---- 高精度计时：PC 上用 clock_gettime(CLOCK_MONOTONIC) ----
   这里刻意让它返回"不可用"，这样 hosttest 走的是 fixed 节拍分支，
   测试跑得快，也顺便覆盖了退化为固定延时的代码路径。 */
void
BaTimeInit (
  void
  )
{
}

BA_BOOL
BaTimeIsExact (
  void
  )
{
  return BA_FALSE;
}

BA_U64
BaTimeNow (
  void
  )
{
  return BaTicksMs ();
}

BA_U32
BaTimeTicksPerMs (
  void
  )
{
  return 1u;
}

BA_BOOL
BaKeyPressed (
  void
  )
{
  return BA_FALSE;
}

BA_BOOL
BaPlatHasAnyKey (
  void
  )
{
  return BA_FALSE;
}

/* ================================================================== */
/* 控制台                                                             */
/* ================================================================== */
static BA_BOOL gHostDebug = BA_FALSE;

void
BaSetDebug (
  BA_BOOL On
  )
{
  gHostDebug = On;
}

BA_BOOL
BaGetDebug (
  void
  )
{
  return gHostDebug;
}

void
BaConsoleInit (
  BA_BOOL Debug
  )
{
  gHostDebug = Debug;
}

void
BaConsoleRestore (
  void
  )
{
}

void
BaPrint (
  const char *Text
  )
{
  if (gHostDebug && (Text != NULL)) {
    fputs (Text, stdout);
  }
}

void
BaPrintNum (
  const char *Label,
  BA_U32      Value
  )
{
  if (gHostDebug) {
    printf ("%s%u\n", (Label != NULL) ? Label : "", (unsigned)Value);
  }
}

void
BaPrintHex (
  const char *Label,
  BA_U32      Value
  )
{
  if (gHostDebug) {
    printf ("%s0x%x\n", (Label != NULL) ? Label : "", (unsigned)Value);
  }
}

/* ================================================================== */
/* 路径                                                               */
/* ================================================================== */
static BA_U16 gHostOwnDir[BA_PATH_MAX];
static BA_U16 gHostAssetDir[BA_PATH_MAX];

BA_STATUS
BaPlatInit (
  void *ImageHandle,
  void *SystemTable
  )
{
  (void)ImageHandle;
  (void)SystemTable;
  gHostOwnDir[0]  = 0;
  gHostAssetDir[0] = 0;
  return BA_OK;
}

const BA_U16 *
BaPlatOwnDir (
  void
  )
{
  return gHostOwnDir;
}

const BA_U16 *
BaPlatOwnPath (
  void
  )
{
  return gHostOwnDir;
}

void
BaSetAssetDir (
  const BA_U16 *Dir
  )
{
  BaStrCopy16 (gHostAssetDir, BA_PATH_MAX, Dir);
}

const BA_U16 *
BaGetAssetDir (
  void
  )
{
  return gHostAssetDir;
}

BA_BOOL
BaPlatIsSecureBootOn (
  void
  )
{
  return BA_FALSE;
}

/* UTF-16 -> UTF-8（够测试用例用） */
static void
HostPathToUtf8 (
  const BA_U16 *In,
  char         *Out,
  size_t        Cap
  )
{
  size_t O = 0;
  size_t I = 0;

  while ((In[I] != 0) && (O + 1 < Cap)) {
    BA_U32 C = In[I];

    if ((C >= 0xD800u) && (C < 0xDC00u) && (In[I + 1] >= 0xDC00u) && (In[I + 1] < 0xE000u)) {
      C = 0x10000u + ((C - 0xD800u) << 10) + (In[I + 1] - 0xDC00u);
      I++;
    }
    if (C < 0x80u) {
      Out[O++] = (char)C;
    } else if (C < 0x800u) {
      if (O + 2 >= Cap) {
        break;
      }
      Out[O++] = (char)(0xC0u | (C >> 6));
      Out[O++] = (char)(0x80u | (C & 0x3Fu));
    } else if (C < 0x10000u) {
      if (O + 3 >= Cap) {
        break;
      }
      Out[O++] = (char)(0xE0u | (C >> 12));
      Out[O++] = (char)(0x80u | ((C >> 6) & 0x3Fu));
      Out[O++] = (char)(0x80u | (C & 0x3Fu));
    } else {
      if (O + 4 >= Cap) {
        break;
      }
      Out[O++] = (char)(0xF0u | (C >> 18));
      Out[O++] = (char)(0x80u | ((C >> 12) & 0x3Fu));
      Out[O++] = (char)(0x80u | ((C >> 6) & 0x3Fu));
      Out[O++] = (char)(0x80u | (C & 0x3Fu));
    }
    I++;
  }
  Out[O] = 0;
}

/* UTF-8 -> UTF-16（用 src/BaUtil.c 里的 BaUtf8ToUtf16 即可） */
static void
HostPathFromUtf8 (
  const char *In,
  BA_U16     *Out,
  BA_SIZE     Cap
  )
{
  BaUtf8ToUtf16 (Out, Cap, In, BaStrLenA (In));
}

/* 去掉 UTF-16 路径里的 BOM（Windows 上 wchar_t 是 2 字节时可以直转） */
struct BaFile {
  FILE *Fp;
};

BA_STATUS
BaFileOpen (
  const BA_U16 *Path,
  BA_FILE     **Out
  )
{
  char  Utf8[1024];
  FILE *Fp;
  BA_FILE *F;

  if ((Path == NULL) || (Out == NULL)) {
    return BA_ERR_INVALID;
  }
  *Out = NULL;
  HostPathToUtf8 (Path, Utf8, sizeof (Utf8));

  Fp = fopen (Utf8, "rb");
  if (Fp == NULL) {
    return BA_ERR_NOT_FOUND;
  }
  F = (BA_FILE *)malloc (sizeof (BA_FILE));
  if (F == NULL) {
    fclose (Fp);
    return BA_ERR_NO_MEMORY;
  }
  F->Fp = Fp;
  *Out  = F;
  return BA_OK;
}

BA_STATUS
BaFileSizeGet (
  BA_FILE *F,
  BA_U64  *Size
  )
{
  long Pos;

  if ((F == NULL) || (Size == NULL)) {
    return BA_ERR_INVALID;
  }
  Pos = ftell (F->Fp);
  if (fseek (F->Fp, 0, SEEK_END) != 0) {
    return BA_ERR_IO;
  }
  *Size = (BA_U64)ftell (F->Fp);
  fseek (F->Fp, Pos, SEEK_SET);
  return BA_OK;
}

BA_STATUS
BaFileReadAt (
  BA_FILE *F,
  BA_U64   Offset,
  void    *Buf,
  BA_SIZE  Len,
  BA_SIZE *Got
  )
{
  size_t R;

  if (Got != NULL) {
    *Got = 0;
  }
  if ((F == NULL) || (Buf == NULL)) {
    return BA_ERR_INVALID;
  }
  if (fseek (F->Fp, (long)Offset, SEEK_SET) != 0) {
    return BA_ERR_IO;
  }
  R = fread (Buf, 1, (size_t)Len, F->Fp);
  if (Got != NULL) {
    *Got = (BA_SIZE)R;
  }
  return (R == (size_t)Len) ? BA_OK : BA_ERR_TRUNCATED;
}

void
BaFileClose (
  BA_FILE *F
  )
{
  if (F == NULL) {
    return;
  }
  if (F->Fp != NULL) {
    fclose (F->Fp);
  }
  free (F);
}

void
BaFileCloseAll (
  void
  )
{
}

BA_STATUS
BaFileExists (
  const BA_U16 *Path
  )
{
  BA_FILE *F = NULL;
  BA_STATUS St = BaFileOpen (Path, &F);

  if (St == BA_OK) {
    BaFileClose (F);
  }
  return St;
}

BA_STATUS
BaFileSizeOf (
  const BA_U16 *Path,
  BA_U64       *Size
  )
{
  BA_FILE *F = NULL;
  BA_STATUS St;

  if (Size == NULL) {
    return BA_ERR_INVALID;
  }
  St = BaFileOpen (Path, &F);
  if (St != BA_OK) {
    return St;
  }
  St = BaFileSizeGet (F, Size);
  BaFileClose (F);
  return St;
}

BA_STATUS
BaFileLoadInto (
  const BA_U16 *Path,
  void         *Buf,
  BA_SIZE       Cap,
  BA_SIZE      *Got
  )
{
  BA_FILE *F = NULL;
  BA_U64   Len = 0;
  BA_SIZE  Rd = 0;
  BA_STATUS St;

  if (Got != NULL) {
    *Got = 0;
  }
  St = BaFileOpen (Path, &F);
  if (St != BA_OK) {
    return St;
  }
  St = BaFileSizeGet (F, &Len);
  if (St != BA_OK) {
    BaFileClose (F);
    return St;
  }
  if ((BA_U64)Cap < Len) {
    BaFileClose (F);
    return BA_ERR_TRUNCATED;
  }
  St = BaFileReadAt (F, 0, Buf, (BA_SIZE)Len, &Rd);
  BaFileClose (F);
  if (Got != NULL) {
    *Got = Rd;
  }
  return St;
}

BA_STATUS
BaFileLoadAll (
  const BA_U16 *Path,
  BA_U8       **Data,
  BA_SIZE      *Size
  )
{
  BA_FILE *F = NULL;
  BA_U64   Len = 0;
  BA_SIZE  Rd = 0;
  BA_U8   *Buf;
  BA_STATUS St;

  if ((Data == NULL) || (Size == NULL)) {
    return BA_ERR_INVALID;
  }
  *Data = NULL;
  *Size = 0;
  St = BaFileOpen (Path, &F);
  if (St != BA_OK) {
    return St;
  }
  St = BaFileSizeGet (F, &Len);
  if ((St != BA_OK) || (Len == 0)) {
    BaFileClose (F);
    return (St != BA_OK) ? St : BA_ERR_FORMAT;
  }
  Buf = (BA_U8 *)malloc ((size_t)Len);
  if (Buf == NULL) {
    BaFileClose (F);
    return BA_ERR_NO_MEMORY;
  }
  St = BaFileReadAt (F, 0, Buf, (BA_SIZE)Len, &Rd);
  BaFileClose (F);
  if ((St != BA_OK) || (Rd != (BA_SIZE)Len)) {
    free (Buf);
    return BA_ERR_TRUNCATED;
  }
  *Data = Buf;
  *Size = (BA_SIZE)Len;
  return BA_OK;
}

/* ================================================================== */
/* 图形桩                                                             */
/* ================================================================== */
BA_BOOL
BaGfxValid (
  const BA_GFX *G
  )
{
  return ((G != NULL) && (G->Gop != NULL)) ? BA_TRUE : BA_FALSE;
}

void
BaGfxClear (
  BA_GFX *G,
  BA_U32  Bgrx
  )
{
  (void)G;
  (void)Bgrx;
  gHostGfxClearCalls++;
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
  BA_SIZE Need = (BA_SIZE)SrcW * (BA_SIZE)SrcH * 4u;

  (void)G;
  (void)Filter;
  (void)BgBgrx;

  gHostGfxDrawCalls++;
  gHostLastDrawW     = SrcW;
  gHostLastDrawH     = SrcH;
  gHostLastDrawScale = ScaleMode;

  if ((Src == NULL) || (Need == 0)) {
    return;
  }
  if (gHostLastFrameCap < Need) {
    free (gHostLastFrame[0]);
    free (gHostLastFrame[1]);
    gHostLastFrame[0] = (BA_U8 *)malloc ((size_t)Need);
    gHostLastFrame[1] = (BA_U8 *)malloc ((size_t)Need);
    gHostLastFrameCap = (BA_U32)Need;
  }
  if ((gHostLastFrame[0] == NULL) || (gHostLastFrame[1] == NULL)) {
    return;
  }
  memcpy (gHostLastFrame[0], gHostLastFrame[1], (size_t)Need);   /* 旧的最后一帧->倒数第二 */
  memcpy (gHostLastFrame[1], Src, (size_t)Need);
}

BA_STATUS
BaChainload (
  const BA_U16 *Path,
  BA_BOOL      *WasSelf
  )
{
  (void)Path;
  if (WasSelf != NULL) {
    *WasSelf = BA_FALSE;
  }
  return BA_ERR_NOT_FOUND;
}

/* 测试程序用来设置"本程序目录"的小工具 */
void
HostSetOwnDir (
  const char *Utf8Dir
  )
{
  HostPathFromUtf8 (Utf8Dir, gHostOwnDir, BA_PATH_MAX);
}
