/** @file
  BaUtil.c -- 不依赖任何系统库的小工具实现（内存 / 字符串 / UTF-8 转换）。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#include "Ba.h"

/* ------------------------------------------------------------------ */
/* 内存                                                               */
/* ------------------------------------------------------------------ */
void
BaMemSet (
  void   *Dst,
  BA_U8   Val,
  BA_SIZE Len
  )
{
  BA_U8 *P = (BA_U8 *)Dst;

  if (P == BA_NULL) {
    return;
  }
  while (Len-- > 0) {
    *P++ = Val;
  }
}

void
BaMemCopy (
  void       *Dst,
  const void *Src,
  BA_SIZE     Len
  )
{
  BA_U8       *D = (BA_U8 *)Dst;
  const BA_U8 *S = (const BA_U8 *)Src;

  if ((D == BA_NULL) || (S == BA_NULL)) {
    return;
  }
  /* 逐字节拷贝：EFI 环境里没有 memcpy，而且这里的数据量是几 MB 级别，
     编译器会自动把它优化成 rep movsb / 向量拷贝，性能足够。 */
  while (Len-- > 0) {
    *D++ = *S++;
  }
}

BA_I32
BaMemCmp (
  const void *A,
  const void *B,
  BA_SIZE     Len
  )
{
  const BA_U8 *P = (const BA_U8 *)A;
  const BA_U8 *Q = (const BA_U8 *)B;

  while (Len-- > 0) {
    if (*P != *Q) {
      return (BA_I32)*P - (BA_I32)*Q;
    }
    P++;
    Q++;
  }
  return 0;
}

/* ------------------------------------------------------------------ */
/* 字符串                                                             */
/* ------------------------------------------------------------------ */
BA_SIZE
BaStrLen16 (
  const BA_U16 *S
  )
{
  BA_SIZE N = 0;

  if (S == BA_NULL) {
    return 0;
  }
  while (S[N] != 0) {
    N++;
  }
  return N;
}

BA_SIZE
BaStrLenA (
  const char *S
  )
{
  BA_SIZE N = 0;

  if (S == BA_NULL) {
    return 0;
  }
  while (S[N] != 0) {
    N++;
  }
  return N;
}

/* 路径比较用的归一化：大写转小写，'/' 与 '\\' 视为同一个字符 */
static BA_U16
BaNormChar (
  BA_U16 C
  )
{
  if ((C >= 'A') && (C <= 'Z')) {
    C = (BA_U16)(C - 'A' + 'a');
  }
  if (C == '/') {
    C = '\\';
  }
  return C;
}

int
BaStrEq16 (
  const BA_U16 *A,
  const BA_U16 *B
  )
{
  BA_SIZE I = 0;

  if ((A == BA_NULL) || (B == BA_NULL)) {
    return 0;
  }
  for (;;) {
    if (A[I] != B[I]) {
      return 0;
    }
    if (A[I] == 0) {
      return 1;
    }
    I++;
  }
}

int
BaStrEqNoCase16 (
  const BA_U16 *A,
  const BA_U16 *B
  )
{
  BA_SIZE I = 0;

  if ((A == BA_NULL) || (B == BA_NULL)) {
    return 0;
  }
  for (;;) {
    if (BaNormChar (A[I]) != BaNormChar (B[I])) {
      return 0;
    }
    if (A[I] == 0) {
      return 1;
    }
    I++;
  }
}

int
BaStrEqNoCaseA (
  const char *A,
  const char *B
  )
{
  BA_SIZE I = 0;
  BA_U16  Ca;
  BA_U16  Cb;

  if ((A == BA_NULL) || (B == BA_NULL)) {
    return 0;
  }
  for (;;) {
    Ca = (BA_U16)(unsigned char)A[I];
    Cb = (BA_U16)(unsigned char)B[I];
    if (BaNormChar (Ca) != BaNormChar (Cb)) {
      return 0;
    }
    if (Ca == 0) {
      return 1;
    }
    I++;
  }
}

void
BaStrCopy16 (
  BA_U16       *Dst,
  BA_SIZE       Cap,
  const BA_U16 *Src
  )
{
  BA_SIZE I = 0;

  if ((Dst == BA_NULL) || (Cap == 0)) {
    return;
  }
  if (Src != BA_NULL) {
    while ((I + 1 < Cap) && (Src[I] != 0)) {
      Dst[I] = Src[I];
      I++;
    }
  }
  Dst[I] = 0;
}

void
BaStrCopyA16 (
  BA_U16      *Dst,
  BA_SIZE      Cap,
  const char  *Src
  )
{
  BA_SIZE I = 0;

  if ((Dst == BA_NULL) || (Cap == 0)) {
    return;
  }
  if (Src != BA_NULL) {
    while ((I + 1 < Cap) && (Src[I] != 0)) {
      Dst[I] = (BA_U16)(unsigned char)Src[I];
      I++;
    }
  }
  Dst[I] = 0;
}

/* ------------------------------------------------------------------ */
/* UTF-8 -> UTF-16                                                    */
/* ------------------------------------------------------------------ */
BA_SIZE
BaUtf8ToUtf16 (
  BA_U16     *Dst,
  BA_SIZE     Cap,
  const char *Src,
  BA_SIZE     SrcLen
  )
{
  BA_SIZE I = 0;
  BA_SIZE O = 0;

  if ((Dst == BA_NULL) || (Cap == 0)) {
    return 0;
  }
  if (Src == BA_NULL) {
    Dst[0] = 0;
    return 0;
  }

  while (I < SrcLen) {
    BA_U32 C = (BA_U32)(unsigned char)Src[I];
    BA_U32 Cp;

    if (C < 0x80) {
      Cp = C;
      I += 1;
    } else if ((C & 0xE0) == 0xC0) {
      if ((I + 1 >= SrcLen) || (((unsigned char)Src[I + 1] & 0xC0) != 0x80)) {
        Cp = 0xFFFD;
        I += 1;
      } else {
        Cp = ((C & 0x1Fu) << 6) | ((BA_U32)(unsigned char)Src[I + 1] & 0x3Fu);
        I += 2;
        if (Cp < 0x80) {
          Cp = 0xFFFD;   /* 过长编码 */
        }
      }
    } else if ((C & 0xF0) == 0xE0) {
      if ((I + 2 >= SrcLen) ||
          (((unsigned char)Src[I + 1] & 0xC0) != 0x80) ||
          (((unsigned char)Src[I + 2] & 0xC0) != 0x80))
      {
        Cp = 0xFFFD;
        I += 1;
      } else {
        Cp = ((C & 0x0Fu) << 12) |
             (((BA_U32)(unsigned char)Src[I + 1] & 0x3Fu) << 6) |
             ((BA_U32)(unsigned char)Src[I + 2] & 0x3Fu);
        I += 3;
        if (Cp < 0x800) {
          Cp = 0xFFFD;
        }
      }
    } else if ((C & 0xF8) == 0xF0) {
      if ((I + 3 >= SrcLen) ||
          (((unsigned char)Src[I + 1] & 0xC0) != 0x80) ||
          (((unsigned char)Src[I + 2] & 0xC0) != 0x80) ||
          (((unsigned char)Src[I + 3] & 0xC0) != 0x80))
      {
        Cp = 0xFFFD;
        I += 1;
      } else {
        Cp = ((C & 0x07u) << 18) |
             (((BA_U32)(unsigned char)Src[I + 1] & 0x3Fu) << 12) |
             (((BA_U32)(unsigned char)Src[I + 2] & 0x3Fu) << 6) |
             ((BA_U32)(unsigned char)Src[I + 3] & 0x3Fu);
        I += 4;
        if ((Cp < 0x10000) || (Cp > 0x10FFFF)) {
          Cp = 0xFFFD;
        }
      }
    } else {
      Cp = 0xFFFD;
      I += 1;
    }

    if (Cp >= 0x10000) {
      BA_U32 V = Cp - 0x10000;
      if (O + 2 >= Cap) {
        break;
      }
      Dst[O++] = (BA_U16)(0xD800 + (V >> 10));
      Dst[O++] = (BA_U16)(0xDC00 + (V & 0x3FF));
    } else {
      if (O + 1 >= Cap) {
        break;
      }
      Dst[O++] = (BA_U16)Cp;
    }
  }

  Dst[O] = 0;
  return O;
}

const BA_U16 *
BaPathBase (
  const BA_U16 *Path
  )
{
  const BA_U16 *Base = Path;
  BA_SIZE       I;

  if (Path == BA_NULL) {
    return BA_NULL;
  }
  for (I = 0; Path[I] != 0; I++) {
    if ((Path[I] == '\\') || (Path[I] == '/')) {
      Base = &Path[I + 1];
    }
  }
  return Base;
}
