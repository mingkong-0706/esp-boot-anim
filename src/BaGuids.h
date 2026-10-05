/** @file
  BaGuids.h -- 本程序用到的 UEFI GUID。

  刻意不使用 EDK2 的 gEfiXxxGuid 全局变量，也不使用 gnu-efi 的
  EFI_XXX_GUID 花括号宏，而是在 BaGuids.c 里直接用字面值定义一份，
  这样同一份代码在 EDK2 与 gnu-efi 下都能编译，且 INF 里不需要
  [Protocols] 段（固件是按 GUID 数值匹配的）。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#ifndef BA_GUIDS_H_
#define BA_GUIDS_H_

#include "BaUefi.h"

extern EFI_GUID gBaGuidGraphicsOutput;   /* EFI_GRAPHICS_OUTPUT_PROTOCOL */
extern EFI_GUID gBaGuidLoadedImage;      /* EFI_LOADED_IMAGE_PROTOCOL */
extern EFI_GUID gBaGuidSimpleFs;         /* EFI_SIMPLE_FILE_SYSTEM_PROTOCOL */
extern EFI_GUID gBaGuidFileInfo;         /* EFI_FILE_INFO */
extern EFI_GUID gBaGuidGlobalVariable;   /* EFI_GLOBAL_VARIABLE */
extern EFI_GUID gBaGuidDevicePath;       /* EFI_DEVICE_PATH_PROTOCOL */

#endif /* BA_GUIDS_H_ */
