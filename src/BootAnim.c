/** @file
  BootAnim.c -- 程序入口：读配置 -> 初始化图形 -> 播放动画 -> 交回给
                Windows Boot Manager。

  流程（每一步失败都有兜底，绝不黑屏、绝不卡住）：

     BaPlatInit          关看门狗、定位自身所在卷
     BaLoadConfig        读 <程序目录>\bootanim.cfg（没有就用默认值）
     BaGfxInit           拿 GOP、必要时切分辨率、分配工作缓冲
     BaAnimPlay          播放 .baa 或 BMP 帧序列
        └─ 失败/0 帧  ->  BaFallbackPlay（内置转圈动画，不需要素材）
     BaGfxShutdown       释放自己的内存
     BaChainload         交给 bootmgfw-orig.efi（失败则依次尝试备用目标）

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#include "BaUefi.h"
#include "BaPlat.h"

#define BA_VERSION "1.1.0"

/* 安装脚本会用这两个字符串来判断 ESP 上的 bootmgfw.efi 到底是
   "微软原版" 还是 "已经被我们替换过的 shim"。绝对不要删掉它们。 */
static const char   gBaMarkerA[] = "BOOTANIM-EFI-LOADER-MARKER-v1";
static const BA_U16 gBaMarkerW[] = L"BOOTANIM-EFI-LOADER-MARKER-v1";

/* 素材目录的推荐位置（shim 安装时程序本体在 \EFI\Microsoft\Boot\，
   素材统一放在这个绝对路径下） */
#define BA_ASSET_DIR "\\EFI\\BootAnim\\"

/* ================================================================== */
/* 配置                                                               */
/* ================================================================== */
static void
BaLoadConfig (
  BA_CONFIG *Cfg
  )
{
  static const char *Dirs[2]  = { BA_NULL, BA_ASSET_DIR };   /* BA_NULL = 本程序目录 */
  static const char *Names[2] = { "bootanim.cfg", "BOOTANIM.CFG" };
  const BA_U16 *OwnDir;
  BA_SIZE       OwnLen;
  BA_U32        D;
  BA_U32        N;

  OwnDir = BaPlatOwnDir ();
  OwnLen = BaStrLen16 (OwnDir);

  for (D = 0; D < 2u; D++) {
    for (N = 0; N < 2u; N++) {
      BA_U16   Path[BA_PATH_MAX];
      BA_U8   *Data = BA_NULL;
      BA_SIZE  Size = 0;
      BA_SIZE  O    = 0;
      BA_SIZE  K;
      const char *Base = Dirs[D];

      if (Base == BA_NULL) {
        if (OwnLen + 20u >= BA_PATH_MAX) {
          continue;
        }
        for (K = 0; (K < OwnLen) && (O + 1 < BA_PATH_MAX); K++) {
          Path[O] = OwnDir[K];
          O++;
        }
      } else {
        for (K = 0; (Base[K] != 0) && (O + 1 < BA_PATH_MAX); K++) {
          Path[O] = (BA_U16)(unsigned char)Base[K];
          O++;
        }
      }
      for (K = 0; (Names[N][K] != 0) && (O + 1 < BA_PATH_MAX); K++) {
        Path[O] = (BA_U16)(unsigned char)Names[N][K];
        O++;
      }
      Path[O] = 0;
      if (Path[0] == 0) {
        continue;
      }

      if (BaFileLoadAll (Path, &Data, &Size) == BA_OK) {
        if ((Size > 0) && (Size < (1024u * 1024u))) {
          BA_U16 Dir[BA_PATH_MAX];
          BA_SIZE L;

          BaConfigParse ((const char *)Data, Size, Cfg);
          BaPrintNum ("bootanim: config loaded, bytes=", (BA_U32)Size);

          /* 相对路径（比如 ANIM=anim.baa）以"配置文件所在目录"为基准，
             这样无论程序本体放在 \EFI\Microsoft\Boot\ 还是
             \EFI\BootAnim\，素材都能被正确找到。 */
          BaStrCopy16 (Dir, BA_PATH_MAX, Path);
          for (L = BaStrLen16 (Dir); L > 0; L--) {
            if ((Dir[L - 1] == '\\') || (Dir[L - 1] == '/')) {
              Dir[L] = 0;
              BaSetAssetDir (Dir);
              break;
            }
          }
        }
        BaFree (Data);
        return;
      }
    }
  }

  BaPrint ("bootanim: no bootanim.cfg, using built-in defaults\r\n");
}

/* ================================================================== */
/* 入口                                                               */
/* ================================================================== */
EFI_STATUS
EFIAPI
BA_ENTRY (
  EFI_HANDLE        ImageHandle,
  EFI_SYSTEM_TABLE *SystemTable
  )
{
  BA_CONFIG Cfg;
  BA_GFX    G;
  BA_STATUS St;
  BA_U32    Played  = 0;
  BA_BOOL   Skipped = BA_FALSE;
  BA_BOOL   WasSelf = BA_FALSE;
  BA_BOOL   GfxReady = BA_FALSE;

  St = BaPlatInit ((void *)ImageHandle, (void *)SystemTable);
  if (St != BA_OK) {
    return EFI_DEVICE_ERROR;
  }

  BaConfigDefault (&Cfg);
  BaLoadConfig (&Cfg);
  BaConsoleInit ((Cfg.Debug != 0) ? BA_TRUE : BA_FALSE);

  BaPrint ("bootanim v" BA_VERSION " starting\r\n");
  if (Cfg.Debug != 0) {
    /* 让 gBaMarkerA / gBaMarkerW 两个标记真正进入二进制，安装脚本靠它们
       识别"这个 bootmgfw.efi 是不是我们的 shim"。 */
    BaPrint (gBaMarkerA);
    BaPrint ("\r\n");
    (VOID)BaStrLen16 (gBaMarkerW);
  }
  if (BaPlatIsSecureBootOn ()) {
    BaPrint ("bootanim: Secure Boot is ON (unsigned loader would be refused)\r\n");
  }

  /* ---------------- 播放 ---------------- */
  if (Cfg.Enabled == 0) {
    /* 配置里关掉了：什么都不画，立刻交回引导程序。
       相当于"保留安装但临时禁用"，把 ENABLED 改回 1 就恢复。 */
    BaPrint ("bootanim: disabled by config (ENABLED=0), skipping animation\r\n");
  } else {
    St = BaGfxInit (&G, &Cfg);
    if (St == BA_OK) {
      GfxReady = BA_TRUE;

      St = BaAnimPlay (&G, &Cfg, &Played, &Skipped);
      if ((St != BA_OK) || (Played == 0)) {
        BaPrint ("bootanim: no usable animation, using built-in fallback\r\n");
        (VOID)BaFallbackPlay (&G, &Cfg);
      }

      BaGfxShutdown (&G);
    } else {
      BaPrintNum ("bootanim: graphics unavailable, status=", (BA_U32)St);
    }
  }
  (VOID)GfxReady;
  (VOID)Skipped;

  /* ---------------- 交回控制权 ---------------- */
  BaPrint ("bootanim: handing over to boot manager\r\n");

  /* 1) 配置里的主目标 */
  if (Cfg.Chainload[0] != 0) {
    St = BaChainload (Cfg.Chainload, &WasSelf);
    if (WasSelf) {
      BaPrint ("bootanim: CHAINLOAD points to itself, trying fallback\r\n");
    }
  }

  /* 2) 配置里的备用目标 */
  if (Cfg.ChainloadFallback[0] != 0) {
    (VOID)BaChainload (Cfg.ChainloadFallback, &WasSelf);
  }

  /* 3) 最后再兜底试一遍最常见的两个路径（自链保护会自动跳过自己） */
  (VOID)BaChainload (L"\\EFI\\Microsoft\\Boot\\bootmgfw.efi", &WasSelf);
  (VOID)BaChainload (L"\\EFI\\Boot\\bootx64.efi", &WasSelf);

  /* ---------------- 全部失败 ---------------- */
  BaConsoleRestore ();
  BaPrint ("\r\nbootanim: FATAL - no boot target could be loaded.\r\n");
  BaPrint ("bootanim: restore \\EFI\\Microsoft\\Boot\\bootmgfw-orig.efi to bootmgfw.efi\r\n");
  BaPrint ("bootanim: (see docs/ recovery instructions)\r\n");

  /* 返回错误，让固件去尝试启动顺序里的下一个条目 */
  return EFI_ABORTED;
}
