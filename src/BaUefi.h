/** @file
  BaUefi.h -- UEFI 头文件兼容层。

  默认走 EDK2 (UefiApplication)；如果定义了 BA_USE_GNUEFI，
  则改用 gnu-efi 的头文件（见 build/gnuefi/Makefile）。

  这里刻意不使用任何 EDK2 的 *Lib 头文件：所有服务都通过
  gST->BootServices / gST->RuntimeServices 直接调用，
  这样在 EDK2 和 gnu-efi 两套环境下代码完全一致。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#ifndef BA_UEFI_H_
#define BA_UEFI_H_

#if defined(BA_USE_GNUEFI)

/* ---------------- gnu-efi ---------------- */
#include <efi.h>
#include <efilib.h>
#include <efiprot.h>
#include <efigop.h>

#define BA_ENTRY efi_main

#ifndef EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID
#define EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID \
  { 0x9042a9de, 0x23dc, 0x4a38, { 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a } }
#endif

#ifndef EFI_LOADED_IMAGE_PROTOCOL_GUID
#define EFI_LOADED_IMAGE_PROTOCOL_GUID \
  { 0x5b1b31a1, 0x9562, 0x11d2, { 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#endif

#ifndef EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID
#define EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID \
  { 0x964e5b22, 0x6459, 0x11d2, { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#endif

#ifndef EFI_DEVICE_PATH_PROTOCOL_GUID
#define EFI_DEVICE_PATH_PROTOCOL_GUID \
  { 0x09576e91, 0x6d3f, 0x11d2, { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#endif

#ifndef EFI_FILE_INFO_ID
#define EFI_FILE_INFO_ID \
  { 0x09576e92, 0x6d3f, 0x11d2, { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#endif

#ifndef EFI_GLOBAL_VARIABLE
#define EFI_GLOBAL_VARIABLE \
  { 0x8be4df61, 0x93ca, 0x11d2, { 0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c } }
#endif

/* 媒体设备路径节点的类型/子类型（gnu-efi 里不一定有） */
#ifndef MEDIA_DEVICE_PATH
#define MEDIA_DEVICE_PATH 0x04
#endif
#ifndef MEDIA_FILEPATH_DP
#define MEDIA_FILEPATH_DP 0x04
#endif

#else

/* ---------------- EDK2 ---------------- */
#include <Uefi.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Protocol/GraphicsOutput.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#include <Protocol/SimpleTextIn.h>
#include <Protocol/DevicePath.h>
#include <Guid/FileInfo.h>

#define BA_ENTRY UefiMain

#endif /* BA_USE_GNUEFI */

#ifndef EFIAPI
#define EFIAPI
#endif

#endif /* BA_UEFI_H_ */
