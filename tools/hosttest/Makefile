# ===================================================================
#  BootAnim PC 端自测
#
#  用法（在 tools/hosttest 目录里）：
#      python ../selftest.py      # 先生成 _testdata/ 里的比对数据
#      make
#      ./hosttest                 # 默认读 ../_testdata
#      ./hosttest /path/to/_testdata
#
#  Windows 上用 MSYS2 / WSL / clang 都行；没有 make 的话直接手动编译：
#      cc -O1 -g -Wall -I../../src main.c BaPlatHost.c \
#         ../../src/BaUtil.c ../../src/BaConfig.c ../../src/BaImage.c \
#         ../../src/BaAnim.c ../../src/BaFallback.c -o hosttest
#
#  注意：这里只编译与 UEFI 无关的模块。BaGfx.c / BaPlatUefi.c /
#        BaGuids.c / BootAnim.c 需要 UEFI 头文件，只能在 EDK2 里编。
# ===================================================================

CC      ?= cc
CFLAGS  ?= -O1 -g -Wall -Wextra -Wno-unused-parameter
CFLAGS  += -I$(CURDIR)/../../src
LDFLAGS ?=

SRC_DIR := ../../src

SRCS := \
  main.c \
  BaPlatHost.c \
  $(SRC_DIR)/BaUtil.c \
  $(SRC_DIR)/BaConfig.c \
  $(SRC_DIR)/BaImage.c \
  $(SRC_DIR)/BaAnim.c \
  $(SRC_DIR)/BaFallback.c

HDRS := \
  $(SRC_DIR)/Ba.h \
  $(SRC_DIR)/BaPlat.h

TARGET := hosttest

.PHONY: all clean run fixtures

all: $(TARGET)

$(TARGET): $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) $(SRCS) -o $@ $(LDFLAGS)

fixtures:
	python3 ../selftest.py || python ../selftest.py

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET)
	rm -rf *.dSYM
