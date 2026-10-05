/** @file
  BaAnim.c -- 动画播放器：流式读取 .baa 或 BMP 帧序列并输出到屏幕。

  设计要点（为了"不能出问题"）：
    * 全程流式，一次只在内存里保留 1~2 帧，几十 MB 的动画也不会爆内存；
    * 每帧都有完整的边界校验，损坏文件只会导致该帧被跳过，不会崩；
    * 播放总帧数同时受 LOOP 与 TIMEOUT_MS 双重限制，任何情况下都会退出；
    * 用 BaTicksMs 做二次兜底（万一单帧解码异常缓慢也不会卡死）。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

/* 注意：本文件刻意只依赖 Ba.h / BaPlat.h，不包含 BaUefi.h，
   这样它也能在 PC 上用 tools/hosttest 完整地跑一遍。 */
#include "BaPlat.h"

/* 起播后多少毫秒内忽略按键（避免用户在固件菜单里按住回车就跳过动画） */
#define BA_ANIM_KEY_ARM_MS 400u

/* .baa 文件不超过这个大小就整个读进内存。
   为什么要这样：UEFI 的 FAT 驱动每次 SetPosition 都要从文件头顺着簇链走一遍，
   逐帧随机读取会反复重走 FAT，在 1080p/60 帧这种规模上很可观。
   一次性读进来之后每帧只是内存指针运算。超过这个大小才退回流式读取。 */
#define BA_ANIM_CACHE_MAX (32u * 1024u * 1024u)

typedef struct {
  BA_BOOL       IsBaa;
  BA_U32        Width;
  BA_U32        Height;
  BA_U32        Fps;
  BA_U32        FrameCount;
  BA_BAA_HEADER Hdr;
  BA_FILE      *File;         /* .baa 流式模式下的文件句柄 */
  BA_U64        FileSize;
  BA_U8        *Blob;         /* .baa 整个文件的内存缓存（<= BA_ANIM_CACHE_MAX 时） */
  BA_U16        Pattern[BA_PATH_MAX];   /* BMP 序列模式的文件名模板 */
  BA_U8        *RawBuf;       /* 压缩负载缓冲 */
  BA_U32        RawCap;
  BA_U8        *BmpBuf;       /* BMP 整文件缓冲（序列模式复用） */
  BA_U32        BmpCap;
} BA_ANIM;

/* ================================================================== */
/* 文件名模板                                                         */
/* ================================================================== */
/* 在 Pat 里把 "%04d" 这类占位符替换成 Index；同时支持 "%%" */
static void
BaFormatPattern (
  const BA_U16 *Pat,
  BA_U32        Index,
  BA_U16       *Out,
  BA_SIZE       Cap
  )
{
  BA_SIZE I = 0;
  BA_SIZE O = 0;

  if ((Out == BA_NULL) || (Cap < 2)) {
    return;
  }
  Out[0] = 0;
  if (Pat == BA_NULL) {
    return;
  }

  while ((Pat[I] != 0) && (O + 1 < Cap)) {
    if (Pat[I] != '%') {
      Out[O] = Pat[I];
      O++;
      I++;
      continue;
    }
    I++;
    if (Pat[I] == '%') {
      Out[O] = '%';
      O++;
      I++;
      continue;
    }
    {
      BA_U32 Width = 0;
      BA_BOOL Zero = BA_FALSE;
      char   Num[16];
      int    N = 0;
      int    K;

      if (Pat[I] == '0') {
        Zero = BA_TRUE;
        I++;
      }
      while ((Pat[I] >= '0') && (Pat[I] <= '9')) {
        Width = Width * 10u + (BA_U32)(Pat[I] - '0');
        I++;
      }
      if (Width > 12u) {
        Width = 12u;
      }
      if ((Pat[I] == 'd') || (Pat[I] == 'i') || (Pat[I] == 'u')) {
        I++;
      }
      /* 生成十进制数字（至少 Width 位） */
      {
        BA_U32 V = Index;
        if (V == 0) {
          Num[N] = '0';
          N++;
        }
        while ((V > 0) && (N < 12)) {
          Num[N] = (char)('0' + (V % 10u));
          N++;
          V /= 10u;
        }
      }
      while ((BA_U32)N < Width) {
        if (O + 1 < Cap) {
          Out[O] = (BA_U16)(Zero ? '0' : ' ');
          O++;
        }
        Width--;   /* 用 Width 递减来补齐，避免再引入变量 */
      }
      for (K = N - 1; K >= 0; K--) {
        if (O + 1 < Cap) {
          Out[O] = (BA_U16)Num[K];
          O++;
        }
      }
    }
  }
  Out[O] = 0;
}

/* 从 "...frame0000.bmp" 推导出 "...frame%04d.bmp" */
static BA_BOOL
BaPatternFromName (
  const BA_U16 *Name,
  BA_U16       *Out,
  BA_SIZE       Cap
  )
{
  BA_SIZE Len = BaStrLen16 (Name);
  BA_SIZE Dot = Len;
  BA_SIZE I;
  BA_SIZE RunStart;
  BA_SIZE RunEnd;
  BA_SIZE RunLen;
  BA_U32  W = 0;
  BA_SIZE O = 0;

  if ((Name == BA_NULL) || (Len == 0) || (Cap < 2)) {
    return BA_FALSE;
  }
  /* 找扩展名起点 */
  for (I = Len; I > 0; I--) {
    if (Name[I - 1] == '.') {
      Dot = I - 1;
      break;
    }
    if ((Name[I - 1] == '\\') || (Name[I - 1] == '/')) {
      break;
    }
  }

  /* 在最后一个分隔符与扩展名之间找末尾连续数字 */
  RunEnd = Dot;
  RunStart = RunEnd;
  while ((RunStart > 0) && (Name[RunStart - 1] >= '0') && (Name[RunStart - 1] <= '9')) {
    RunStart--;
  }
  RunLen = RunEnd - RunStart;
  if (RunLen == 0) {
    return BA_FALSE;
  }

  for (I = 0; I < RunStart; I++) {
    if (O + 1 >= Cap) {
      return BA_FALSE;
    }
    Out[O] = Name[I];
    O++;
  }
  /* 输出 "%0Nd" */
  if (O + 6 >= Cap) {
    return BA_FALSE;
  }
  Out[O] = '%';
  O++;
  W      = (BA_U32)RunLen;
  if (W >= 10u) {
    Out[O] = (BA_U16)('0' + (W / 10u));
    O++;
  }
  Out[O] = (BA_U16)('0' + (W % 10u));
  O++;
  Out[O] = 'd';
  O++;
  for (I = RunEnd; I < Len; I++) {
    if (O + 1 >= Cap) {
      return BA_FALSE;
    }
    Out[O] = Name[I];
    O++;
  }
  Out[O] = 0;
  return BA_TRUE;
}

/* ================================================================== */
/* 打开 / 关闭                                                        */
/* ================================================================== */
static BA_STATUS
BaAnimOpenBaa (
  BA_ANIM     *A,
  const BA_U16 *Path
  )
{
  BA_STATUS St;
  BA_U8     HdrBuf[BA_BAA_HEADER_MIN];
  BA_SIZE   Got = 0;
  BA_U64    Size = 0;

  A->File = BA_NULL;
  A->Blob = BA_NULL;

  /* 先尝试整个读进内存：这样每帧的读取就完全没有 FAT 开销 */
  St = BaFileSizeOf (Path, &Size);
  if (St != BA_OK) {
    return St;
  }
  if ((Size > 0) && (Size <= (BA_U64)BA_ANIM_CACHE_MAX)) {
    BA_SIZE BlobSize = 0;
    St = BaFileLoadAll (Path, &A->Blob, &BlobSize);
    if (St == BA_OK) {
      A->FileSize = (BA_U64)BlobSize;
      if (BlobSize < BA_BAA_HEADER_MIN) {
        return BA_ERR_TRUNCATED;
      }
      St = BaBaaParseHeader (A->Blob, BlobSize, &A->Hdr);
      if (St != BA_OK) {
        return St;
      }
      A->IsBaa      = BA_TRUE;
      A->Width      = A->Hdr.Width;
      A->Height     = A->Hdr.Height;
      A->Fps        = A->Hdr.Fps;
      A->FrameCount = A->Hdr.FrameCount;
      return BA_OK;
    }
    /* 内存不够：Blob 置空，退回流式读取 */
    A->Blob = BA_NULL;
  }

  St = BaFileOpen (Path, &A->File);
  if (St != BA_OK) {
    return St;
  }
  St = BaFileSizeGet (A->File, &A->FileSize);
  if (St != BA_OK) {
    return St;
  }
  St = BaFileReadAt (A->File, 0, HdrBuf, BA_BAA_HEADER_MIN, &Got);
  if ((St != BA_OK) || (Got != BA_BAA_HEADER_MIN)) {
    return BA_ERR_TRUNCATED;
  }
  St = BaBaaParseHeader (HdrBuf, (BA_SIZE)A->FileSize, &A->Hdr);
  if (St != BA_OK) {
    return St;
  }

  A->IsBaa      = BA_TRUE;
  A->Width      = A->Hdr.Width;
  A->Height     = A->Hdr.Height;
  A->Fps        = A->Hdr.Fps;
  A->FrameCount = A->Hdr.FrameCount;
  return BA_OK;
}

static BA_STATUS
BaAnimOpenBmpSeq (
  BA_ANIM      *A,
  const BA_U16 *Pattern,
  BA_U32        WantFrames,
  const BA_CONFIG *Cfg
  )
{
  BA_U16   Name[BA_PATH_MAX];
  BA_U32   W = 0;
  BA_U32   H = 0;
  BA_U8   *Buf = BA_NULL;
  BA_SIZE  Size = 0;
  BA_U32   Count = 0;
  BA_STATUS St;

  /* 第一帧 */
  BaFormatPattern (Pattern, 0, Name, BA_PATH_MAX);
  St = BaFileLoadAll (Name, &Buf, &Size);
  if (St != BA_OK) {
    return St;
  }
  St = BaBmpProbe (Buf, Size, &W, &H);
  BaFree (Buf);
  if (St != BA_OK) {
    return St;
  }

  if (WantFrames > 0) {
    Count = WantFrames;
  } else {
    /* 自动探测：一直找到第一个不存在的文件 */
    Count = 1;
    while (Count < BA_MAX_FRAMES) {
      BA_U64 TS = 0;
      BaFormatPattern (Pattern, Count, Name, BA_PATH_MAX);
      if (BaFileSizeOf (Name, &TS) != BA_OK) {
        break;
      }
      Count++;
    }
  }
  if (Count == 0) {
    Count = 1;
  }

  A->IsBaa      = BA_FALSE;
  A->Width      = W;
  A->Height     = H;
  A->Fps        = (Cfg != BA_NULL) ? Cfg->Fps : 0;
  A->FrameCount = Count;
  BaStrCopy16 (A->Pattern, BA_PATH_MAX, Pattern);
  return BA_OK;
}

static void
BaAnimFreeBufs (
  BA_ANIM *A
  )
{
  BaFree (A->RawBuf);
  BaFree (A->BmpBuf);
  BaFree (A->Blob);
  A->RawBuf = BA_NULL;
  A->BmpBuf = BA_NULL;
  A->Blob   = BA_NULL;
  A->RawCap = 0;
  A->BmpCap = 0;
}

void
BaAnimClose (
  BA_ANIM *A
  )
{
  if (A == BA_NULL) {
    return;
  }
  if (A->File != BA_NULL) {
    BaFileClose (A->File);
    A->File = BA_NULL;
  }
  BaAnimFreeBufs (A);
}

/* ================================================================== */
/* 读取单帧                                                           */
/* ================================================================== */
static BA_STATUS
BaAnimReadFrame (
  BA_ANIM *A,
  BA_U32   Index,
  BA_U8   *Out,
  BA_SIZE  OutSize
  )
{
  BA_STATUS St;

  if (A->IsBaa) {
    BA_U8   IdxEntry[8];
    BA_SIZE Got = 0;
    BA_U64  Off = 0;
    BA_U32  Len = 0;
    const BA_U8 *RawPtr = BA_NULL;

    if (A->Blob != BA_NULL) {
      /* 内存缓存路径：没有任何文件 I/O */
      const BA_U8 *Idx = A->Blob + (BA_SIZE)A->Hdr.HeaderSize + (BA_SIZE)Index * 8u;
      St = BaBaaFrameLoc (Idx, 8, (BA_SIZE)A->FileSize, &A->Hdr, Index, &Off, &Len);
      if (St != BA_OK) {
        return St;
      }
      if (Len == 0) {
        return BA_ERR_FORMAT;
      }
      RawPtr = A->Blob + (BA_SIZE)Off;
      return BaBaaDecodeFrame (RawPtr, Len, &A->Hdr, Out, OutSize);
    }

    St = BaFileReadAt (A->File,
                       (BA_U64)A->Hdr.HeaderSize + (BA_U64)Index * 8u,
                       IdxEntry, 8, &Got);
    if ((St != BA_OK) || (Got != 8)) {
      return BA_ERR_TRUNCATED;
    }
    St = BaBaaFrameLoc (IdxEntry, 8, (BA_SIZE)A->FileSize, &A->Hdr, Index, &Off, &Len);
    if (St != BA_OK) {
      return St;
    }
    if (Len == 0) {
      return BA_ERR_FORMAT;
    }

    if ((A->RawBuf == BA_NULL) || (A->RawCap < Len)) {
      BA_U32 NewCap = A->RawCap;
      BA_U8 *NewBuf;
      if (NewCap == 0) {
        /* 正常情况：RLE 负载不会比原始数据大多少 */
        BA_U64 Want = (BA_U64)A->Width * (BA_U64)A->Height * 4u;
        Want += Want / 128u + 4096u;
        if (Want > (BA_U64)BA_MAX_FRAME_BYTES) {
          Want = BA_MAX_FRAME_BYTES;
        }
        NewCap = (BA_U32)Want;
      }
      while (NewCap < Len) {
        NewCap = (NewCap > (BA_MAX_FRAME_BYTES / 2u)) ? BA_MAX_FRAME_BYTES : (NewCap * 2u);
        if (NewCap < Len && NewCap >= BA_MAX_FRAME_BYTES) {
          return BA_ERR_TOO_BIG;
        }
      }
      NewBuf = (BA_U8 *)BaAlloc (NewCap);
      if (NewBuf == BA_NULL) {
        return BA_ERR_NO_MEMORY;
      }
      BaFree (A->RawBuf);
      A->RawBuf = NewBuf;
      A->RawCap = NewCap;
    }

    St = BaFileReadAt (A->File, Off, A->RawBuf, Len, &Got);
    if ((St != BA_OK) || (Got != Len)) {
      return BA_ERR_TRUNCATED;
    }
    return BaBaaDecodeFrame (A->RawBuf, Len, &A->Hdr, Out, OutSize);
  } else {
    /* BMP 序列 */
    BA_U16   Name[BA_PATH_MAX];
    BA_SIZE  Size = 0;
    BA_U64   Need = 0;
    BA_U32   W = 0;
    BA_U32   H = 0;

    BaFormatPattern (A->Pattern, Index, Name, BA_PATH_MAX);
    St = BaFileSizeOf (Name, &Need);
    if (St != BA_OK) {
      return St;
    }
    if ((Need == 0) || (Need > (BA_U64)BA_MAX_FRAME_BYTES)) {
      return BA_ERR_TOO_BIG;
    }
    if ((A->BmpBuf == BA_NULL) || ((BA_U64)A->BmpCap < Need)) {
      BA_U8 *NewBuf = (BA_U8 *)BaAlloc ((BA_SIZE)Need);
      if (NewBuf == BA_NULL) {
        return BA_ERR_NO_MEMORY;
      }
      BaFree (A->BmpBuf);
      A->BmpBuf = NewBuf;
      A->BmpCap = (BA_U32)Need;
    }
    Size = (BA_SIZE)A->BmpCap;
    St   = BaFileLoadInto (Name, A->BmpBuf, Size, &Size);
    if (St != BA_OK) {
      return St;
    }
    St = BaBmpProbe (A->BmpBuf, Size, &W, &H);
    if (St != BA_OK) {
      return St;
    }
    if ((W != A->Width) || (H != A->Height)) {
      return BA_ERR_FORMAT;
    }
    return BaBmpDecode (A->BmpBuf, Size, Out, W, H);
  }
}

/* ================================================================== */
/* 播放                                                               */
/* ================================================================== */
static BA_STATUS
BaAnimTryOpen (
  BA_ANIM      *A,
  const BA_U16 *Path,
  const BA_CONFIG *Cfg
  )
{
  BA_STATUS St;
  BA_FILE  *F = NULL;
  BA_U8     Magic[8];
  BA_SIZE   Got = 0;

  BaMemSet (A, 0, sizeof (BA_ANIM));

  /* 先用内容判断是不是 .baa */
  St = BaFileOpen (Path, &F);
  if (St != BA_OK) {
    return St;
  }
  St = BaFileReadAt (F, 0, Magic, 8, &Got);
  BaFileClose (F);
  if ((St == BA_OK) && (Got == 8) && (BaMemCmp (Magic, BA_BAA_MAGIC, 8) == 0)) {
    return BaAnimOpenBaa (A, Path);
  }

  /* 否则当作 BMP 序列。路径可能是目录（以分隔符结尾），也可能直接
     指向第一帧文件名——后者会自动推导出 %04d 模板。 */
  {
    BA_U16 Pat[BA_PATH_MAX];
    BA_SIZE Len = BaStrLen16 (Path);

    if ((Len > 0) && ((Path[Len - 1] == '\\') || (Path[Len - 1] == '/'))) {
      /* 用显式数组而不是 L"..."，这样在 wchar_t 不是 2 字节的平台上
         （比如 Linux）也能直接编译 */
      static const BA_U16 Suffix[] = {
        'f', 'r', 'a', 'm', 'e', '%', '0', '4', 'd', '.', 'b', 'm', 'p', 0
      };
      BaStrCopy16 (Pat, BA_PATH_MAX, Path);
      if (Len + 16 < BA_PATH_MAX) {
        BA_SIZE O = BaStrLen16 (Pat);
        BA_SIZE K = 0;
        while ((Suffix[K] != 0) && (O + 1 < BA_PATH_MAX)) {
          Pat[O] = Suffix[K];
          O++;
          K++;
        }
        Pat[O] = 0;
      }
    } else if (!BaPatternFromName (Path, Pat, BA_PATH_MAX)) {
      /* 文件名里没有数字：当成单帧 */
      BaStrCopy16 (Pat, BA_PATH_MAX, Path);
    }
    return BaAnimOpenBmpSeq (A, Pat, (Cfg != BA_NULL) ? Cfg->Frames : 0, Cfg);
  }
}

BA_STATUS
BaAnimPlay (
  BA_GFX          *G,
  const BA_CONFIG *Cfg,
  BA_U32          *PlayedFrames,
  BA_BOOL         *Skipped
  )
{
  BA_ANIM  A;
  BA_U16   Path[BA_PATH_MAX];
  BA_STATUS St;
  BA_U32   Fps;
  BA_U32   FrameMs;
  BA_U32   Pacing;
  BA_U64   Total;
  BA_U64   MaxByTime;
  BA_U32   BgBgrx;
  BA_U8   *FrameBuf = BA_NULL;
  BA_U32   Played = 0;
  BA_U32   Fail = 0;
  BA_U32   Pass;
  BA_U64   StartMs;
  BA_U64   FrameUsedTickSum = 0;
  BA_BOOL  Skip = BA_FALSE;
  BA_U32   Index = 0;

  if (PlayedFrames != BA_NULL) {
    *PlayedFrames = 0;
  }
  if (Skipped != BA_NULL) {
    *Skipped = BA_FALSE;
  }
  if ((G == BA_NULL) || !BaGfxValid (G)) {
    return BA_ERR_UNSUPPORTED;
  }

  /* ---- 决定要播放什么 ---- */
  Path[0] = 0;
  if ((Cfg != BA_NULL) && (Cfg->Anim[0] != 0)) {
    BaStrCopy16 (Path, BA_PATH_MAX, Cfg->Anim);
  } else {
    /* 默认探测顺序（"shim" 安装时程序本体在 \EFI\Microsoft\Boot\ 下，
       素材却放在 \EFI\BootAnim\ 下，所以两种前缀都要试）：
         1. <本程序目录>\anim.baa
         2. \EFI\BootAnim\anim.baa          <- 推荐布局
         3. <本程序目录>\frames\frame0000.bmp
         4. \EFI\BootAnim\frames\frame0000.bmp
         5. <本程序目录>\frame0000.bmp
         6. \EFI\BootAnim\frame0000.bmp
    */
    BA_U16      Dir[BA_PATH_MAX];
    const BA_U16 *Base = (BaGetAssetDir ()[0] != 0) ? BaGetAssetDir () : BaPlatOwnDir ();
    BA_SIZE     D = BaStrLen16 (Base);
    BA_SIZE     I;
    BA_U16      Try[BA_PATH_MAX];
    const char *Cands[3];
    BA_U32      C;
    BA_U32      P;
    BA_BOOL     Found = BA_FALSE;

    for (I = 0; (I <= D) && (I + 1 < BA_PATH_MAX); I++) {
      Dir[I] = Base[I];
    }
    Dir[BA_PATH_MAX - 1] = 0;
    for (I = BaStrLen16 (Dir); I > 0; I--) {
      if ((Dir[I - 1] == '\\') || (Dir[I - 1] == '/')) {
        Dir[I] = 0;
        break;
      }
    }
    if (Dir[0] == 0) {
      /* 拿不到自身路径：直接用绝对默认目录 */
      const char *Fallback = "\\EFI\\BootAnim\\";
      for (I = 0; (Fallback[I] != 0) && (I + 1 < BA_PATH_MAX); I++) {
        Dir[I] = (BA_U16)(unsigned char)Fallback[I];
      }
      Dir[I] = 0;
    }

    Cands[0] = "anim.baa";
    Cands[1] = "frames\\frame0000.bmp";
    Cands[2] = "frame0000.bmp";

    for (P = 0; (P < 2u) && !Found; P++) {
      const char *BasePath = (P == 0)
                               ? BA_NULL                       /* 用 Dir */
                               : "\\EFI\\BootAnim\\";
      for (C = 0; (C < 3u) && !Found; C++) {
        BA_SIZE O = 0;
        BA_SIZE K;
        const char *S = Cands[C];

        Try[0] = 0;
        if (BasePath == BA_NULL) {
          for (K = 0; (Dir[K] != 0) && (O + 1 < BA_PATH_MAX); K++) {
            Try[O] = Dir[K];
            O++;
          }
        } else {
          for (K = 0; (BasePath[K] != 0) && (O + 1 < BA_PATH_MAX); K++) {
            Try[O] = (BA_U16)(unsigned char)BasePath[K];
            O++;
          }
        }
        for (K = 0; (S[K] != 0) && (O + 1 < BA_PATH_MAX); K++) {
          Try[O] = (BA_U16)(unsigned char)S[K];
          O++;
        }
        Try[O] = 0;
        if (Try[0] == 0) {
          continue;
        }
        if (BaFileExists (Try) == BA_OK) {
          BaStrCopy16 (Path, BA_PATH_MAX, Try);
          Found = BA_TRUE;
        }
      }
    }

    if (!Found) {
      return BA_ERR_NOT_FOUND;
    }
  }

  St = BaAnimTryOpen (&A, Path, Cfg);
  if (St != BA_OK) {
    BaPrintNum ("bootanim: open anim failed, status=", (BA_U32)St);
    return St;
  }
  if ((A.Width == 0) || (A.Height == 0) || (A.FrameCount == 0)) {
    BaAnimClose (&A);
    return BA_ERR_FORMAT;
  }
  if ((BA_U64)A.Width * (BA_U64)A.Height > (BA_U64)BA_MAX_PIXELS) {
    BaAnimClose (&A);
    return BA_ERR_TOO_BIG;
  }

  /* ---- 参数 ---- */
  Fps = (Cfg != BA_NULL) ? Cfg->Fps : 0;
  if (Fps == 0) {
    Fps = A.Fps;
  }
  if ((Fps == 0) || (Fps > 240u)) {
    Fps = 30u;
  }
  FrameMs = (1000u + Fps / 2u) / Fps;
  if (FrameMs == 0) {
    FrameMs = 1;
  }

  Pacing = (Cfg != BA_NULL) ? Cfg->Pacing : BA_PACING_AUTO;
  if (Pacing > BA_PACING_OFF) {
    Pacing = BA_PACING_AUTO;
  }

  MaxByTime = 0xFFFFFFFFFFFFFFFFull;
  {
    /* 安全性兜底：LOOP=0（无限循环）又没有设置 TIMEOUT_MS 时，强制给一个
       15 秒上限。配置写错绝不能导致机器开不了机。 */
    BA_U32 EffTimeout = (Cfg != BA_NULL) ? Cfg->TimeoutMs : 15000u;
    if ((EffTimeout == 0) && ((Cfg == BA_NULL) || (Cfg->Loop == 0))) {
      EffTimeout = 15000u;
    }
    if (EffTimeout != 0) {
      MaxByTime = ((BA_U64)EffTimeout * (BA_U64)Fps + 999u) / 1000u;
      if (MaxByTime == 0) {
        MaxByTime = 1;
      }
    }
  }

  if ((Cfg == BA_NULL) || (Cfg->Loop == 0)) {
    Total = MaxByTime;
  } else {
    Total = (BA_U64)Cfg->Loop * (BA_U64)A.FrameCount;
  }
  if (Total > MaxByTime) {
    Total = MaxByTime;
  }
  if (Total == 0) {
    Total = 1;
  }
  if (Total > 0xFFFFFFFFull) {
    Total = 0xFFFFFFFFull;
  }

  BgBgrx = 0xFF000000u;
  if (Cfg != BA_NULL) {
    BgBgrx |= (Cfg->Background & 0x00FFFFFFu);
  }

  FrameBuf = (BA_U8 *)BaAlloc ((BA_SIZE)A.Width * (BA_SIZE)A.Height * 4u);
  if (FrameBuf == BA_NULL) {
    BaAnimClose (&A);
    return BA_ERR_NO_MEMORY;
  }

  if ((Cfg == BA_NULL) || (Cfg->ClearFirst != 0)) {
    BaGfxClear (G, BgBgrx);
  }
  if ((Cfg != BA_NULL) && (Cfg->LeadInMs != 0)) {
    BaStallMs (Cfg->LeadInMs);
  }

  StartMs = BaTicksMs ();

  BaPrintNum ("bootanim: frames=", A.FrameCount);
  BaPrintNum ("bootanim: size w=", A.Width);
  BaPrintNum ("bootanim: size h=", A.Height);
  BaPrintNum ("bootanim: fps=", Fps);
  BaPrintNum ("bootanim: play total=", (BA_U32)Total);
  BaPrintNum ("bootanim: pacing=", Pacing);
  BaPrintNum ("bootanim: cached=", (A.Blob != BA_NULL) ? 1u : 0u);
  BaPrintNum ("bootanim: hi-res timer=", BaTimeIsExact () ? 1u : 0u);

  for (Pass = 0; Pass < 0xFFFFFFFFu; Pass++) {
    BA_U64  Elapsed;
    BA_U64  T0 = 0;
    BA_BOOL UseHiRes;

    if ((BA_U64)Played >= Total) {
      break;
    }

    /* 记录本帧开始时刻（仅高精度计时可用时），帧尾只补足差额，
       这样渲染再慢也不会被额外叠加一整个帧间隔。 */
    UseHiRes = (BA_BOOL)((Pacing == BA_PACING_AUTO) && BaTimeIsExact ());
    if (UseHiRes) {
      T0 = BaTimeNow ();
    }

    St = BaAnimReadFrame (&A, Index, FrameBuf, (BA_SIZE)A.Width * (BA_SIZE)A.Height * 4u);
    if (St == BA_OK) {
      BaGfxDraw (G,
                 FrameBuf, A.Width, A.Height,
                 (Cfg != BA_NULL) ? Cfg->Scale : BA_SCALE_FIT,
                 (Cfg != BA_NULL) ? Cfg->Filter : BA_FILTER_AUTO,
                 BgBgrx);
      Played++;
      Fail = 0;
    } else {
      Fail++;
      BaPrintNum ("bootanim: frame decode failed, status=", (BA_U32)St);
      /* 连续 3 帧失败就收工：既避免坏文件把开机卡死（否则循环会一直空转），
         也保证一帧都没成功时上层能改走内置兜底动画。 */
      if (Fail >= 3) {
        break;
      }
    }

    Index++;
    if (Index >= A.FrameCount) {
      Index = 0;
    }

    /* 按键跳过（前 400ms 不响应，避免固件菜单里的按键误触发） */
    if ((Cfg != BA_NULL) && (Cfg->SkipKey != 0)) {
      Elapsed = (StartMs != 0) ? (BaTicksMs () - StartMs) : (BA_U64)Played * FrameMs;
      if (Elapsed > BA_ANIM_KEY_ARM_MS) {
        if (BaKeyPressed ()) {
          Skip = BA_TRUE;
          break;
        }
      }
    }

    /* 时间兜底：即使每帧解码都很慢也一定会退出 */
    if (((Cfg != BA_NULL) && (Cfg->TimeoutMs != 0)) && (StartMs != 0)) {
      Elapsed = BaTicksMs () - StartMs;
      if (Elapsed > (BA_U64)Cfg->TimeoutMs + 3000u) {
        BaPrint ("bootanim: wall-clock timeout\r\n");
        break;
      }
    }

    /* ---- 帧节拍 ---- */
    if (Pacing != BA_PACING_OFF) {
      if (UseHiRes) {
        BA_U64 UsedMs = (BaTimeNow () - T0) / (BA_U64)BaTimeTicksPerMs ();
        if (UsedMs < (BA_U64)FrameMs) {
          BaStallMs ((BA_U32)((BA_U64)FrameMs - UsedMs));
        }
        FrameUsedTickSum += (BaTimeNow () - T0);
      } else {
        BaStallMs (FrameMs);
      }
    } else if (UseHiRes) {
      FrameUsedTickSum += (BaTimeNow () - T0);
    }
  }

  if (BaTimeIsExact () && (Played > 0)) {
    BaPrintNum ("bootanim: avg frame ms=",
                (BA_U32)(FrameUsedTickSum / ((BA_U64)BaTimeTicksPerMs () * (BA_U64)Played)));
  }

  BaPrintNum ("bootanim: played=", Played);

  BaAnimClose (&A);
  BaFree (FrameBuf);

  if (PlayedFrames != BA_NULL) {
    *PlayedFrames = Played;
  }
  if (Skipped != BA_NULL) {
    *Skipped = Skip;
  }
  return (Played > 0) ? BA_OK : BA_ERR_FORMAT;
}
