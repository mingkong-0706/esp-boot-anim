## @file
#  BootAnimPkg -- EDK2 platform description for the ESP boot animation app.
#
#  Usage (after this folder and src/ are copied into <edk2>\BootAnimPkg\):
#     cd <edk2>
#     edksetup.bat Rebuild
#     build -p BootAnimPkg\BootAnimPkg.dsc -a X64 -t VS2022 -b RELEASE
#
#  Or just use build\edk2\build-edk2.bat / build-edk2.sh, which copy the
#  files into place and then call build for you.
#
#  NOTE: this file is kept pure ASCII on purpose -- EDK2's build tools parse
#  INF/DSC/DEC files, and a non-UTF-8 locale on Windows can mis-decode
#  non-ASCII comments and fail the build.  Chinese explanations live in
#  README.md and the Chinese build guide instead.
#
#  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
##

[Defines]
  PLATFORM_NAME                  = BootAnimPkg
  PLATFORM_GUID                  = 9a1c4e77-3d2b-4f80-b6e5-1c7a9d0e5f32
  PLATFORM_VERSION               = 1.0
  DSC_SPECIFICATION              = 0x00010005
  OUTPUT_DIRECTORY               = Build/BootAnimPkg
  SUPPORTED_ARCHITECTURES        = X64|IA32
  BUILD_TARGETS                  = DEBUG|RELEASE
  SKUID_IDENTIFIER               = DEFAULT

#
# This starter list is enough for most EDK2 versions.  If build reports
#     error 4000: Instance of library class [XxxLib] is not found
# then run the helper, which only ADDS the missing mappings (and drops any
# mapping whose .inf does not exist on disk):
#     python3 build/edk2/make_dsc.py <edk2-dir>
# It also scans MdePkg/Library/**/*.inf for LIBRARY_CLASS declarations, so it
# keeps working as EDK2 adds new library classes over time.
#
[LibraryClasses]
  BaseLib|MdePkg/Library/BaseLib/BaseLib.inf
  BaseMemoryLib|MdePkg/Library/BaseMemoryLib/BaseMemoryLib.inf
  RegisterFilterLib|MdePkg/Library/RegisterFilterLibNull/RegisterFilterLibNull.inf
  DebugLib|MdePkg/Library/BaseDebugLibNull/BaseDebugLibNull.inf
  DebugPrintErrorLevelLib|MdePkg/Library/BaseDebugPrintErrorLevelLib/BaseDebugPrintErrorLevelLib.inf
  PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  PrintLib|MdePkg/Library/BasePrintLib/BasePrintLib.inf
  MemoryAllocationLib|MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf
  UefiBootServicesTableLib|MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf
  UefiApplicationEntryPoint|MdePkg/Library/UefiApplicationEntryPoint/UefiApplicationEntryPoint.inf

[Components]
  BootAnimPkg/BootAnim.inf
