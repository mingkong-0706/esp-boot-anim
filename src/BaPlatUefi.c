/** @file
  BaPlatUefi.c -- UEFI 平台层：内存 / 文件 / 时间 / 键盘 / 控制台。

  同一份代码同时支持 EDK2 与 gnu-efi：所有服务都直接走
  gST->BootServices / gST->RuntimeServices，不依赖任何 *Lib，
  也刻意不使用任何可变参数（避免 EDK2 与 gnu-efi 的 VA_* 宏差异）。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#include "BaUefi.h"
#include "BaGuids.h"
#include "BaPlat.h"

/* ================================================================== */
/* 全局状态                                                           */
/* ================================================================== */
static EFI_HANDLE            gBaImageHandle  = NULL;
static EFI_SYSTEM_TABLE     *gBaST           = NULL;
static EFI_BOOT_SERVICES    *gBaBS           = NULL;
static EFI_RUNTIME_SERVICES *gBaRT           = NULL;
static EFI_HANDLE            gBaDeviceHandle = NULL;
static EFI_FILE_PROTOCOL    *gBaRoot         = NULL;
static BA_BOOL               gBaDebug        = BA_FALSE;
static BA_BOOL               gBaRootFailed   = BA_FALSE;

static CHAR16 gBaOwnPath[BA_PATH_MAX];
static CHAR16 gBaOwnDir[BA_PATH_MAX];
static CHAR16 gBaAssetDir[BA_PATH_MAX];

struct BaFile {
  EFI_FILE_PROTOCOL *File;
};

/* ================================================================== */
/* 诊断输出                                                           */
/* ================================================================== */
static void
BaOut (
  const CHAR16 *Str
  )
{
  if ((gBaST != NULL) && (gBaST->ConOut != NULL) && (Str != NULL)) {
    gBaST->ConOut->OutputString (gBaST->ConOut, (CHAR16 *)Str);
  }
}

void
BaSetDebug (
  BA_BOOL On
  )
{
  gBaDebug = On;
}

BA_BOOL
BaGetDebug (
  void
  )
{
  return gBaDebug;
}

void
BaPrint (
  const char *Text
  )
{
  CHAR16 Buf[256];
  BA_SIZE I = 0;

  if (!gBaDebug || (Text == NULL)) {
    return;
  }
  while (Text[I] != 0) {
    BA_SIZE N = 0;

    while ((Text[I] != 0) && (N + 1 < (sizeof (Buf) / sizeof (Buf[0])))) {
      Buf[N] = (CHAR16)(unsigned char)Text[I];
      N++;
      I++;
    }
    Buf[N] = 0;
    BaOut (Buf);
  }
}

/* 把无符号数写成十进制 */
static void
BaAppendU32 (
  char   *Out,
  BA_SIZE Cap,
  BA_SIZE *Pos,
  BA_U32   Value,
  BA_U32   Base,
  BA_BOOL  Upper
  )
{
  char   Tmp[16];
  int    N = 0;

  if (Value == 0) {
    if (*Pos + 1 < Cap) {
      Out[(*Pos)++] = '0';
    }
    Out[*Pos] = 0;
    return;
  }
  while ((Value > 0) && (N < 15)) {
    BA_U32 D = Value % Base;
    if (D < 10u) {
      Tmp[N] = (char)('0' + D);
    } else {
      Tmp[N] = (char)((Upper ? 'A' : 'a') + (D - 10u));
    }
    N++;
    Value /= Base;
  }
  while (N > 0) {
    N--;
    if (*Pos + 1 < Cap) {
      Out[(*Pos)++] = Tmp[N];
    }
  }
  Out[*Pos] = 0;
}

void
BaPrintNum (
  const char *Label,
  BA_U32      Value
  )
{
  char    Out[96];
  BA_SIZE P = 0;
  BA_SIZE I = 0;

  if (!gBaDebug) {
    return;
  }
  if (Label != NULL) {
    while ((Label[I] != 0) && (P + 1 < sizeof (Out))) {
      Out[P++] = Label[I++];
    }
  }
  BaAppendU32 (Out, sizeof (Out), &P, Value, 10u, BA_FALSE);
  if (P + 1 < sizeof (Out)) {
    Out[P++] = '\r';
  }
  if (P + 1 < sizeof (Out)) {
    Out[P++] = '\n';
  }
  Out[P] = 0;
  BaPrint (Out);
}

void
BaPrintHex (
  const char *Label,
  BA_U32      Value
  )
{
  char    Out[96];
  BA_SIZE P = 0;
  BA_SIZE I = 0;

  if (!gBaDebug) {
    return;
  }
  if (Label != NULL) {
    while ((Label[I] != 0) && (P + 1 < sizeof (Out))) {
      Out[P++] = Label[I++];
    }
  }
  if (P + 1 < sizeof (Out)) {
    Out[P++] = '0';
  }
  if (P + 1 < sizeof (Out)) {
    Out[P++] = 'x';
  }
  BaAppendU32 (Out, sizeof (Out), &P, Value, 16u, BA_FALSE);
  if (P + 1 < sizeof (Out)) {
    Out[P++] = '\r';
  }
  if (P + 1 < sizeof (Out)) {
    Out[P++] = '\n';
  }
  Out[P] = 0;
  BaPrint (Out);
}

void
BaConsoleInit (
  BA_BOOL Debug
  )
{
  gBaDebug = Debug;
  if ((gBaST != NULL) && (gBaST->ConOut != NULL)) {
    /* 动画期间隐藏光标，否则屏幕上会有一个闪烁的方块 */
    gBaST->ConOut->EnableCursor (gBaST->ConOut, FALSE);
  }
}

void
BaConsoleRestore (
  void
  )
{
  if ((gBaST != NULL) && (gBaST->ConOut != NULL)) {
    gBaST->ConOut->EnableCursor (gBaST->ConOut, TRUE);
  }
}

/* ================================================================== */
/* 内存                                                               */
/* ================================================================== */
void *
BaAlloc (
  BA_SIZE Size
  )
{
  EFI_STATUS Status;
  VOID      *Ptr = NULL;

  if ((gBaBS == NULL) || (Size == 0)) {
    return BA_NULL;
  }
  Status = gBaBS->AllocatePool (EfiLoaderData, (UINTN)Size, &Ptr);
  if (EFI_ERROR (Status)) {
    return BA_NULL;
  }
  return Ptr;
}

void *
BaAllocZero (
  BA_SIZE Size
  )
{
  void *P = BaAlloc (Size);

  if (P != BA_NULL) {
    BaMemSet (P, 0, Size);
  }
  return P;
}

void
BaFree (
  void *Ptr
  )
{
  if ((Ptr != BA_NULL) && (gBaBS != NULL)) {
    gBaBS->FreePool (Ptr);
  }
}

/* ================================================================== */
/* 时间                                                               */
/* ================================================================== */
void
BaStallMs (
  BA_U32 Ms
  )
{
  if ((gBaBS == NULL) || (gBaBS->Stall == NULL)) {
    return;
  }
  /* Stall 的参数是微秒；分片调用，避免单次数值过大 */
  while (Ms > 0) {
    BA_U32 Chunk = (Ms > 1000u) ? 1000u : Ms;
    gBaBS->Stall ((UINTN)Chunk * 1000u);
    Ms -= Chunk;
  }
}

/* ---------------- 高精度计时：x86 TSC + 自校准 ---------------- */
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || \
    defined(__i386__) || defined(__amd64__)
#define BA_HAVE_RDTSC 1
#endif

static BA_U64 gBaTscPerMs = 0;

#if defined(BA_HAVE_RDTSC)
#if defined(_MSC_VER)
#include <intrin.h>
static BA_U64
BaRdTsc (
  void
  )
{
  return (BA_U64)__rdtsc ();
}
#else
static BA_U64
BaRdTsc (
  void
  )
{
  BA_U32 Lo;
  BA_U32 Hi;

  __asm__ __volatile__ ("rdtsc" : "=a"(Lo), "=d"(Hi));
  return (((BA_U64)Hi << 32) | (BA_U64)Lo);
}
#endif
#endif /* BA_HAVE_RDTSC */

void
BaTimeInit (
  void
  )
{
  gBaTscPerMs = 0;
#if defined(BA_HAVE_RDTSC)
  if ((gBaBS != NULL) && (gBaBS->Stall != NULL)) {
    BA_U64 T0;
    BA_U64 T1;
    BA_U64 Delta;

    T0 = BaRdTsc ();
    gBaBS->Stall (20000);          /* 固定 20 ms，用来标定 TSC 频率 */
    T1    = BaRdTsc ();
    Delta = T1 - T0;

    /* 合理性检查：20ms 内 TSC 增量应落在 100MHz~100GHz 之间
       （100MHz -> 2e6 ticks，100GHz -> 2e9 ticks） */
    if ((Delta > (20000ull * 100ull)) && (Delta < (20000ull * 100000ull))) {
      gBaTscPerMs = Delta / 20u;
    }
  }
#endif
}

BA_BOOL
BaTimeIsExact (
  void
  )
{
  return (gBaTscPerMs != 0) ? BA_TRUE : BA_FALSE;
}

BA_U64
BaTimeNow (
  void
  )
{
#if defined(BA_HAVE_RDTSC)
  if (gBaTscPerMs != 0) {
    return BaRdTsc ();
  }
#endif
  return BaTicksMs ();
}

BA_U32
BaTimeTicksPerMs (
  void
  )
{
  return (gBaTscPerMs != 0) ? (BA_U32)gBaTscPerMs : 1u;
}

static BA_I32
BaDaysFromCivil (
  BA_I32 Year,
  BA_U32 Month,
  BA_U32 Day
  )
{
  BA_I32  Y = Year;
  BA_U32  M = Month;
  BA_I32  Era;
  BA_U32  Yoe;
  BA_U32  Mp;
  BA_U32  Doy;
  BA_U32  Doe;

  if (M <= 2u) {
    Y -= 1;
  }
  Era = (Y >= 0) ? (Y / 400) : ((Y - 399) / 400);
  Yoe = (BA_U32)(Y - Era * 400);
  Mp  = (M > 2u) ? (M - 3u) : (M + 9u);
  Doy = (153u * Mp + 2u) / 5u + Day - 1u;
  Doe = Yoe * 365u + Yoe / 4u - Yoe / 100u + Doy;
  return Era * 146097 + (BA_I32)Doe - 719468;
}

BA_U64
BaTicksMs (
  void
  )
{
  EFI_TIME Time;
  BA_I32   Days;
  BA_U64   Secs;

  if ((gBaRT == NULL) || (gBaRT->GetTime == NULL)) {
    return 0;
  }
  BaMemSet (&Time, 0, sizeof (Time));
  if (EFI_ERROR (gBaRT->GetTime (&Time, NULL))) {
    return 0;
  }
  if ((Time.Month < 1) || (Time.Month > 12) || (Time.Day < 1) || (Time.Day > 31)) {
    return 0;
  }

  Days = BaDaysFromCivil ((BA_I32)Time.Year, (BA_U32)Time.Month, (BA_U32)Time.Day);
  Secs = (BA_U64)(BA_I64)Days * 86400u
         + (BA_U64)Time.Hour * 3600u
         + (BA_U64)Time.Minute * 60u
         + (BA_U64)Time.Second;
  return Secs * 1000u + (BA_U64)(Time.Nanosecond / 1000000u);
}

/* ================================================================== */
/* 键盘                                                               */
/* ================================================================== */
BA_BOOL
BaKeyPressed (
  void
  )
{
  EFI_INPUT_KEY Key;

  if ((gBaST == NULL) || (gBaST->ConIn == NULL)) {
    return BA_FALSE;
  }
  if ((gBaST->ConIn->WaitForKey != NULL) && (gBaBS->CheckEvent != NULL)) {
    if (EFI_ERROR (gBaBS->CheckEvent (gBaST->ConIn->WaitForKey))) {
      return BA_FALSE;
    }
  }
  if (EFI_ERROR (gBaST->ConIn->ReadKeyStroke (gBaST->ConIn, &Key))) {
    return BA_FALSE;
  }
  return BA_TRUE;
}

BA_BOOL
BaPlatHasAnyKey (
  void
  )
{
  return BaKeyPressed ();
}

/* ================================================================== */
/* 设备路径工具                                                       */
/* ================================================================== */
static BOOLEAN
BaDpIsEnd (
  const EFI_DEVICE_PATH_PROTOCOL *Node
  )
{
  return (BOOLEAN)((Node->Type == 0x7Fu) && (Node->SubType == 0xFFu));
}

static UINT16
BaDpLen (
  const EFI_DEVICE_PATH_PROTOCOL *Node
  )
{
  return (UINT16)((UINT16)Node->Length[0] | ((UINT16)Node->Length[1] << 8));
}

/* ================================================================== */
/* 初始化                                                             */
/* ================================================================== */
BA_STATUS
BaPlatInit (
  void *ImageHandle,
  void *SystemTable
  )
{
  EFI_STATUS                      Status;
  EFI_LOADED_IMAGE_PROTOCOL      *Li = NULL;
  const EFI_DEVICE_PATH_PROTOCOL *Node;
  BA_SIZE                         I;

  gBaImageHandle = (EFI_HANDLE)ImageHandle;
  gBaST          = (EFI_SYSTEM_TABLE *)SystemTable;

  if (gBaST == NULL) {
    return BA_ERR_INVALID;
  }
  gBaBS = gBaST->BootServices;
  gBaRT = gBaST->RuntimeServices;
  if (gBaBS == NULL) {
    return BA_ERR_INVALID;
  }

  gBaOwnPath[0] = 0;
  gBaOwnDir[0]  = 0;

  /* 关掉看门狗：默认 5 分钟的超时会在长时间解码/播放时把机器复位 */
  if (gBaBS->SetWatchdogTimer != NULL) {
    gBaBS->SetWatchdogTimer (0, 0, 0, NULL);
  }

  /* 取本程序所在卷与自身路径 */
  Status = gBaBS->HandleProtocol (gBaImageHandle,
                                  &gBaGuidLoadedImage,
                                  (VOID **)&Li);
  if (!EFI_ERROR (Status) && (Li != NULL)) {
    gBaDeviceHandle = Li->DeviceHandle;

    Node = Li->FilePath;
    while ((Node != NULL) && !BaDpIsEnd (Node)) {
      if ((Node->Type == MEDIA_DEVICE_PATH) && (Node->SubType == MEDIA_FILEPATH_DP)) {
        const CHAR16 *Name = (const CHAR16 *)((const UINT8 *)Node + 4);
        BaStrCopy16 (gBaOwnPath, BA_PATH_MAX, Name);
        break;
      }
      if (BaDpLen (Node) < 4) {
        break;
      }
      Node = (const EFI_DEVICE_PATH_PROTOCOL *)((const UINT8 *)Node + BaDpLen (Node));
    }
  }

  /* 目录 = 最后一个分隔符（含）之前的部分 */
  BaStrCopy16 (gBaOwnDir, BA_PATH_MAX, gBaOwnPath);
  for (I = BaStrLen16 (gBaOwnDir); I > 0; I--) {
    if ((gBaOwnDir[I - 1] == '\\') || (gBaOwnDir[I - 1] == '/')) {
      gBaOwnDir[I] = 0;
      break;
    }
  }
  if (I == 0) {
    gBaOwnDir[0] = 0;
  }

  /* 标定高精度计时（约 20ms），供帧节拍补偿使用 */
  BaTimeInit ();

  return BA_OK;
}

const BA_U16 *
BaPlatOwnDir (
  void
  )
{
  return gBaOwnDir;
}

const BA_U16 *
BaPlatOwnPath (
  void
  )
{
  return gBaOwnPath;
}

void
BaSetAssetDir (
  const BA_U16 *Dir
  )
{
  if (Dir == NULL) {
    gBaAssetDir[0] = 0;
    return;
  }
  BaStrCopy16 (gBaAssetDir, BA_PATH_MAX, Dir);
}

const BA_U16 *
BaGetAssetDir (
  void
  )
{
  return gBaAssetDir;
}

BA_BOOL
BaPlatIsSecureBootOn (
  void
  )
{
  UINT8      Data   = 0;
  UINTN      Size   = sizeof (Data);
  EFI_STATUS Status;

  if ((gBaRT == NULL) || (gBaRT->GetVariable == NULL)) {
    return BA_FALSE;
  }
  Status = gBaRT->GetVariable (L"SecureBoot",
                               &gBaGuidGlobalVariable,
                               NULL,
                               &Size,
                               &Data);
  if (EFI_ERROR (Status) || (Size != 1)) {
    return BA_FALSE;
  }
  return (Data != 0) ? BA_TRUE : BA_FALSE;
}

/* ================================================================== */
/* 文件                                                               */
/* ================================================================== */
static BA_STATUS
BaEnsureRoot (
  void
  )
{
  EFI_STATUS                       Status;
  EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *Fs = NULL;

  if (gBaRoot != NULL) {
    return BA_OK;
  }
  if (gBaRootFailed || (gBaDeviceHandle == NULL)) {
    return BA_ERR_NOT_FOUND;
  }

  Status = gBaBS->HandleProtocol (gBaDeviceHandle,
                                  &gBaGuidSimpleFs,
                                  (VOID **)&Fs);
  if (EFI_ERROR (Status) || (Fs == NULL)) {
    gBaRootFailed = BA_TRUE;
    return BA_ERR_NOT_FOUND;
  }
  Status = Fs->OpenVolume (Fs, &gBaRoot);
  if (EFI_ERROR (Status) || (gBaRoot == NULL)) {
    gBaRootFailed = BA_TRUE;
    return BA_ERR_NOT_FOUND;
  }
  return BA_OK;
}

/* 把路径规整成 UEFI 形式（'/' 换成 '\'，相对路径补上本程序目录） */
static void
BaBuildPath (
  const BA_U16 *Path,
  CHAR16       *Out,
  BA_SIZE       Cap
  )
{
  BA_SIZE O = 0;
  BA_SIZE I = 0;
  BA_BOOL NeedDir;

  if ((Out == NULL) || (Cap < 2)) {
    return;
  }
  Out[0] = 0;
  if (Path == NULL) {
    return;
  }

  NeedDir = (BA_BOOL)((Path[0] != '\\') && (Path[0] != '/'));

  if (NeedDir) {
    const CHAR16 *Prefix = (gBaAssetDir[0] != 0) ? gBaAssetDir : gBaOwnDir;
    I = 0;
    while ((Prefix[I] != 0) && (O + 1 < Cap)) {
      CHAR16 C = Prefix[I];
      if (C == '/') {
        C = '\\';
      }
      Out[O] = C;
      O++;
      I++;
    }
  }

  I = 0;
  while ((Path[I] != 0) && (O + 1 < Cap)) {
    CHAR16 C = Path[I];
    if (C == '/') {
      C = '\\';
    }
    Out[O] = C;
    O++;
    I++;
  }
  Out[O] = 0;
}

BA_STATUS
BaFileOpen (
  const BA_U16 *Path,
  BA_FILE     **Out
  )
{
  EFI_STATUS Status;
  CHAR16     Full[BA_PATH_MAX];
  BA_FILE   *F;
  BA_STATUS  St;

  if ((Path == NULL) || (Out == NULL)) {
    return BA_ERR_INVALID;
  }
  *Out = NULL;

  St = BaEnsureRoot ();
  if (St != BA_OK) {
    return St;
  }

  BaBuildPath (Path, Full, BA_PATH_MAX);
  if (Full[0] == 0) {
    return BA_ERR_INVALID;
  }

  F = (BA_FILE *)BaAlloc (sizeof (BA_FILE));
  if (F == NULL) {
    return BA_ERR_NO_MEMORY;
  }

  Status = gBaRoot->Open (gBaRoot, &F->File, Full, EFI_FILE_MODE_READ, 0);
  if (EFI_ERROR (Status) || (F->File == NULL)) {
    BaFree (F);
    return BA_ERR_NOT_FOUND;
  }

  *Out = F;
  return BA_OK;
}

BA_STATUS
BaFileSizeGet (
  BA_FILE *F,
  BA_U64  *Size
  )
{
  EFI_STATUS     Status;
  EFI_FILE_INFO *Info;
  UINTN          InfoSize;
  /* 必须保证 8 字节对齐：EFI_FILE_INFO 里有 UINT64 成员，
     直接把一个字节数组强转过去在某些平台上会触发对齐异常。 */
  union {
    UINT64 Aligner;
    BA_U8  Bytes[256];
  } Small;
  VOID          *Heap = NULL;

  if ((F == NULL) || (Size == NULL)) {
    return BA_ERR_INVALID;
  }
  *Size = 0;

  InfoSize = sizeof (Small.Bytes);
  Info     = (EFI_FILE_INFO *)Small.Bytes;
  Status   = F->File->GetInfo (F->File, &gBaGuidFileInfo, &InfoSize, Info);
  if (Status == EFI_BUFFER_TOO_SMALL) {
    if ((InfoSize < sizeof (EFI_FILE_INFO)) || (InfoSize > (64u * 1024u * 1024u))) {
      return BA_ERR_IO;
    }
    Heap = BaAlloc ((BA_SIZE)InfoSize);
    if (Heap == NULL) {
      return BA_ERR_NO_MEMORY;
    }
    Info   = (EFI_FILE_INFO *)Heap;
    Status = F->File->GetInfo (F->File, &gBaGuidFileInfo, &InfoSize, Info);
  }
  if (EFI_ERROR (Status)) {
    BaFree (Heap);
    return BA_ERR_IO;
  }

  *Size = (BA_U64)Info->FileSize;
  BaFree (Heap);
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
  EFI_STATUS Status;
  UINTN      Want;

  if (Got != NULL) {
    *Got = 0;
  }
  if ((F == NULL) || (Buf == NULL)) {
    return BA_ERR_INVALID;
  }
  if (Len == 0) {
    return BA_OK;
  }
  if (Len > 0x40000000u) {
    return BA_ERR_INVALID;
  }

  Status = F->File->SetPosition (F->File, (UINT64)Offset);
  if (EFI_ERROR (Status)) {
    return BA_ERR_IO;
  }

  Want   = (UINTN)Len;
  Status = F->File->Read (F->File, &Want, Buf);
  if (EFI_ERROR (Status)) {
    return BA_ERR_IO;
  }
  if (Got != NULL) {
    *Got = (BA_SIZE)Want;
  }
  return BA_OK;
}

void
BaFileClose (
  BA_FILE *F
  )
{
  if (F == NULL) {
    return;
  }
  if (F->File != NULL) {
    F->File->Close (F->File);
    F->File = NULL;
  }
  BaFree (F);
}

void
BaFileCloseAll (
  void
  )
{
  if (gBaRoot != NULL) {
    gBaRoot->Close (gBaRoot);
    gBaRoot = NULL;
  }
}

BA_STATUS
BaFileExists (
  const BA_U16 *Path
  )
{
  BA_FILE  *F  = NULL;
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
  BA_FILE  *F  = NULL;
  BA_STATUS St;

  if (Size == NULL) {
    return BA_ERR_INVALID;
  }
  *Size = 0;
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
  BA_FILE  *F   = NULL;
  BA_U64    Len = 0;
  BA_SIZE   Rd  = 0;
  BA_STATUS St;

  if (Got != NULL) {
    *Got = 0;
  }
  if ((Buf == NULL) || (Cap == 0)) {
    return BA_ERR_INVALID;
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
  if (Len == 0) {
    BaFileClose (F);
    return BA_ERR_FORMAT;
  }
  if ((BA_U64)Cap < Len) {
    BaFileClose (F);
    return BA_ERR_TRUNCATED;
  }

  St = BaFileReadAt (F, 0, Buf, (BA_SIZE)Len, &Rd);
  BaFileClose (F);
  if ((St != BA_OK) || (Rd != (BA_SIZE)Len)) {
    return (St != BA_OK) ? St : BA_ERR_TRUNCATED;
  }
  if (Got != NULL) {
    *Got = Rd;
  }
  return BA_OK;
}

BA_STATUS
BaFileLoadAll (
  const BA_U16 *Path,
  BA_U8       **Data,
  BA_SIZE      *Size
  )
{
  BA_FILE  *F   = NULL;
  BA_U64    Len = 0;
  BA_SIZE   Got = 0;
  BA_U8    *Buf;
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
  if (St != BA_OK) {
    BaFileClose (F);
    return St;
  }
  if (Len == 0) {
    BaFileClose (F);
    return BA_ERR_FORMAT;
  }
  if (Len > (BA_U64)(256u * 1024u * 1024u)) {
    BaFileClose (F);
    return BA_ERR_TOO_BIG;
  }

  Buf = (BA_U8 *)BaAlloc ((BA_SIZE)Len);
  if (Buf == NULL) {
    BaFileClose (F);
    return BA_ERR_NO_MEMORY;
  }

  St = BaFileReadAt (F, 0, Buf, (BA_SIZE)Len, &Got);
  BaFileClose (F);
  if ((St != BA_OK) || (Got != (BA_SIZE)Len)) {
    BaFree (Buf);
    return (St != BA_OK) ? St : BA_ERR_TRUNCATED;
  }

  *Data = Buf;
  *Size = (BA_SIZE)Len;
  return BA_OK;
}

/* ================================================================== */
/* 链式引导                                                           */
/* ================================================================== */
static BA_SIZE
BaDpSize (
  const EFI_DEVICE_PATH_PROTOCOL *Dp
  )
{
  BA_SIZE N = 0;

  if (Dp == NULL) {
    return 0;
  }
  while (!BaDpIsEnd (Dp)) {
    UINT16 L = BaDpLen (Dp);
    if (L < 4) {
      return 0;
    }
    N += L;
    Dp = (const EFI_DEVICE_PATH_PROTOCOL *)((const UINT8 *)Dp + L);
  }
  return N + 4u;   /* 加上 END 节点 */
}

BA_STATUS
BaChainload (
  const BA_U16 *Path,
  BA_BOOL      *WasSelf
  )
{
  EFI_STATUS                      Status;
  CHAR16                          Full[BA_PATH_MAX];
  BA_FILE                        *F = NULL;
  BA_STATUS                       St;
  EFI_DEVICE_PATH_PROTOCOL       *VolDp = NULL;
  BA_SIZE                         VolSize;
  BA_SIZE                         FpSize;
  BA_SIZE                         Total;
  EFI_DEVICE_PATH_PROTOCOL       *Dp;
  UINT8                          *P;
  EFI_HANDLE                      NewHandle = NULL;
  BA_SIZE                         NameLen;

  if (WasSelf != NULL) {
    *WasSelf = BA_FALSE;
  }
  if (Path == NULL) {
    return BA_ERR_INVALID;
  }

  BaBuildPath (Path, Full, BA_PATH_MAX);
  if (Full[0] == 0) {
    return BA_ERR_INVALID;
  }

  /* ---- 自链保护：绝不把自己再加载一遍（否则会无限递归） ---- */
  if ((gBaOwnPath[0] != 0) && BaStrEqNoCase16 (Full, gBaOwnPath)) {
    if (WasSelf != NULL) {
      *WasSelf = BA_TRUE;
    }
    BaPrint ("bootanim: refuse to chainload self\r\n");
    return BA_ERR_INVALID;
  }

  /* ---- 确认目标文件存在 ---- */
  St = BaFileOpen (Full, &F);
  if (St != BA_OK) {
    BaPrint ("bootanim: chain target not found\r\n");
    return St;
  }
  BaFileClose (F);

  /* ---- 构造 "卷设备路径 + 文件路径节点" 的完整设备路径 ---- */
  if (gBaDeviceHandle == NULL) {
    return BA_ERR_NOT_FOUND;
  }
  Status = gBaBS->HandleProtocol (gBaDeviceHandle,
                                  &gBaGuidDevicePath,
                                  (VOID **)&VolDp);
  if (EFI_ERROR (Status) || (VolDp == NULL)) {
    return BA_ERR_NOT_FOUND;
  }
  VolSize = BaDpSize (VolDp);
  if (VolSize < 4) {
    return BA_ERR_NOT_FOUND;
  }

  NameLen = BaStrLen16 (Full);
  FpSize  = 4u + (NameLen + 1u) * 2u;          /* 节点头 + 双字节结尾 0 */
  Total   = (VolSize - 4u) + FpSize + 4u;

  Dp = (EFI_DEVICE_PATH_PROTOCOL *)BaAlloc (Total);
  if (Dp == NULL) {
    return BA_ERR_NO_MEMORY;
  }
  P = (UINT8 *)Dp;
  BaMemCopy (P, VolDp, VolSize - 4u);          /* 卷路径（不含 END） */
  P += (VolSize - 4u);

  P[0] = MEDIA_DEVICE_PATH;
  P[1] = MEDIA_FILEPATH_DP;
  P[2] = (UINT8)(FpSize & 0xFFu);
  P[3] = (UINT8)((FpSize >> 8) & 0xFFu);
  BaMemCopy (P + 4, Full, (NameLen + 1u) * 2u);
  P += FpSize;

  P[0] = 0x7Fu;   /* END_DEVICE_PATH_TYPE */
  P[1] = 0xFFu;   /* END_ENTIRE_DEVICE_PATH_SUBTYPE */
  P[2] = 4u;
  P[3] = 0u;

  /* ---- 交出去之前把自己的文件句柄都关掉 ---- */
  BaFileCloseAll ();

  Status = gBaBS->LoadImage (FALSE,
                             gBaImageHandle,
                             Dp,
                             NULL,
                             0,
                             &NewHandle);
  BaFree (Dp);

  if (EFI_ERROR (Status) || (NewHandle == NULL)) {
    BaPrint ("bootanim: LoadImage failed\r\n");
    if (Status == EFI_SECURITY_VIOLATION) {
      BaPrint ("bootanim: blocked by Secure Boot\r\n");
    }
    BaPrintHex ("bootanim: status=", (BA_U32)Status);
    return BA_ERR_IO;
  }

  BaPrint ("bootanim: starting image\r\n");
  Status = gBaBS->StartImage (NewHandle, NULL, NULL);

  /* 只有目标映像返回了（正常启动是不会返回的）才会走到这里 */
  BaPrintHex ("bootanim: StartImage returned=", (BA_U32)Status);
  if (gBaBS->UnloadImage != NULL) {
    gBaBS->UnloadImage (NewHandle);
  }
  return BA_ERR_IO;
}
