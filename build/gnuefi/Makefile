# ===================================================================
#  Makefile (gnu-efi) -- 不需要 EDK2 的轻量构建方式
#
#  依赖: gcc/clang + binutils + gnu-efi 开发包
#        Debian/Ubuntu: sudo apt install gnu-efi
#        Fedora:        sudo dnf install gnu-efi gnu-efi-devel
#        Arch:          sudo pacman -S gnu-efi
#        MSYS2:         pacman -S gnu-efi  (用 mingw-w64 的 make)
#
#  用法:
#     make                 # 生成 dist/bootanim.efi
#     make clean
#
#  产物: dist/bootanim.efi
#
#  注意: 这条路径没有在开发机上实际编译验证过（开发机没有任何 C 工具链），
#        如果遇到问题请优先使用 EDK2 路径（build/edk2/build-edk2.bat）。
# ===================================================================

ARCH        ?= x86_64
EFI_INC_DIR ?= /usr/include/efi
EFI_LIB_DIR ?= /usr/lib
EFI_CRT_OBJ ?= $(EFI_LIB_DIR)/crt0-efi-$(ARCH).o
EFI_LDS     ?= $(EFI_LIB_DIR)/elf_$(ARCH)_efi.lds

CC          ?= gcc
LD          ?= ld
OBJCOPY     ?= objcopy

TOP     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
OBJDIR  := $(TOP)/build/gnuefi/obj
DISTDIR := $(TOP)/dist
TARGET  := $(DISTDIR)/bootanim.efi

SRCS := \
  $(TOP)/src/BootAnim.c \
  $(TOP)/src/BaAnim.c \
  $(TOP)/src/BaConfig.c \
  $(TOP)/src/BaFallback.c \
  $(TOP)/src/BaGfx.c \
  $(TOP)/src/BaGuids.c \
  $(TOP)/src/BaImage.c \
  $(TOP)/src/BaPlatUefi.c \
  $(TOP)/src/BaUtil.c

OBJS := $(patsubst $(TOP)/src/%.c,$(OBJDIR)/%.o,$(SRCS))

CFLAGS := -DBA_USE_GNUEFI -DGNU_EFI_USE_MS_ABI \
          -I$(EFI_INC_DIR) -I$(EFI_INC_DIR)/$(ARCH) -I$(EFI_INC_DIR)/protocol \
          -I$(TOP)/src \
          -O2 -g -Wall -Wno-error \
          -fPIC -fshort-wchar -ffreestanding -fno-stack-protector \
          -fno-strict-aliasing -mno-red-zone -maccumulate-outgoing-args

LDFLAGS := -Bsymbolic -shared -nostdlib -znocombreloc -T $(EFI_LDS) \
           -L$(EFI_LIB_DIR) $(EFI_CRT_OBJ)

LIBS := -lefi -lgnuefi $(shell $(CC) -print-libgcc-file-name)

.PHONY: all clean info

all: $(TARGET)

info:
	@echo "TOP        = $(TOP)"
	@echo "ARCH       = $(ARCH)"
	@echo "EFI_INC_DIR= $(EFI_INC_DIR)"
	@echo "EFI_LIB_DIR= $(EFI_LIB_DIR)"
	@echo "TARGET     = $(TARGET)"

$(OBJDIR):
	@mkdir -p $(OBJDIR)

$(DISTDIR):
	@mkdir -p $(DISTDIR)

$(OBJDIR)/%.o: $(TOP)/src/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJDIR)/bootanim.so: $(OBJS) | $(OBJDIR)
	$(LD) $(LDFLAGS) $(OBJS) -o $@ $(LIBS)

$(TARGET): $(OBJDIR)/bootanim.so | $(DISTDIR)
	$(OBJCOPY) \
	  -j .text -j .sdata -j .data -j .dynamic -j .dynsym \
	  -j .rel -j .rela -j .reloc \
	  --target=efi-app-$(ARCH) $< $@
	@echo "==> $@"

clean:
	rm -rf $(OBJDIR) $(TARGET)
