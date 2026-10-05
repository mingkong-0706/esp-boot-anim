#!/usr/bin/env bash
# ===================================================================
#  build-edk2.sh -- 在 Linux / WSL / MSYS2 下用 EDK2 构建 bootanim.efi
#
#  用法: ./build-edk2.sh [EDK2路径] [工具链] [构建类型] [架构]
#        ./build-edk2.sh ~/edk2                    # 工具链自动探测
#        ./build-edk2.sh ~/edk2 GCC RELEASE X64
#
#  产物: dist/bootanim.efi
# ===================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"

EDK2_DIR="${1:-${EDK2_DIR:-}}"
TOOLCHAIN="${2:-${EDK2_TOOLCHAIN:-}}"
TARGET_KIND="${3:-${EDK2_TARGET:-RELEASE}}"
ARCH="${4:-${EDK2_ARCH:-X64}}"

if [ -z "$EDK2_DIR" ]; then
  echo "[错误] 没有指定 EDK2 路径。用法: ./build-edk2.sh ~/edk2"
  exit 2
fi
if [ ! -f "$EDK2_DIR/edksetup.sh" ]; then
  echo "[错误] $EDK2_DIR 里没有 edksetup.sh"
  exit 2
fi

# ------------------------------------------------------------------
# 从 Conf/tools_def.txt 里列出所有已定义的工具链名字。
# 行长得像:   *_GCC5_*_*_CC_PATH = ...
# （[BuildOptions] 段里的 GCC: / MSFT: 是"工具链族"，这里要排除掉）
# ------------------------------------------------------------------
list_toolchains() {
  local conf="$1/Conf/tools_def.txt"
  [ -f "$conf" ] || conf="$1/BaseTools/Conf/tools_def.template"
  [ -f "$conf" ] || return 1
  grep -oE '\*_[A-Za-z0-9]+_\*_\*_[A-Z_]+' "$conf" 2>/dev/null \
    | sed 's/^\*_//; s/_\*_\*_.*$//' | sort -u
}

detect_toolchain() {
  local avail="$1"
  local c
  for c in GCC GCC5 CLANGDWARF CLANGPDB CLANG38 CLANG35 GCC49 GCC48 VS2022 VS2019; do
    if printf '%s\n' "$avail" | grep -qx "$c"; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

echo "=========================================================="
echo " 项目目录 : $PROJ"
echo " EDK2     : $EDK2_DIR"
echo " 构建类型 : $TARGET_KIND"
echo " 架构     : $ARCH"
echo "=========================================================="

# ---------- 1. 复制源码和工程文件 ----------
PKG="$EDK2_DIR/BootAnimPkg"
mkdir -p "$PKG/src" "$PKG/Include"
cp -f "$PROJ"/src/*.c "$PROJ"/src/*.h "$PKG/src/"
cp -f "$PROJ/build/edk2/BootAnim.inf"    "$PKG/BootAnim.inf"
cp -f "$PROJ/build/edk2/BootAnimPkg.dec" "$PKG/BootAnimPkg.dec"
cp -f "$PROJ/build/edk2/BootAnimPkg.dsc" "$PKG/BootAnimPkg.dsc"

# 用 MdePkg.dsc 里的官方 [LibraryClasses] 段刷新 DSC。
# 这样不管 EDK2 版本怎么加新库依赖（比如 BaseLib 后来依赖了
# RegisterFilterLib），都不会再出现 "library class ... is not found"。
PYBIN=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then PYBIN="$cand"; break; fi
done
if [ -n "$PYBIN" ] && [ -f "$HERE/make_dsc.py" ]; then
  if ! "$PYBIN" "$HERE/make_dsc.py" "$EDK2_DIR" "$PKG/BootAnimPkg.dsc"; then
    echo "[注意] make_dsc.py 失败，继续使用 DSC 里自带的精简 LibraryClasses 列表"
  fi
else
  echo "[注意] 找不到 python 或 make_dsc.py，跳过 DSC 库映射刷新"
fi

echo "[1/4] 源码已复制到 $PKG"

# ---------- 2. 初始化 EDK2 环境 ----------
cd "$EDK2_DIR"
# edksetup.sh 里会引用一些可能未定义的变量，临时关掉 -u / -e 再 source
set +e +u
# shellcheck disable=SC1091
source ./edksetup.sh
RC=$?
set -e -u
if [ "$RC" -ne 0 ]; then
  echo "[错误] source edksetup.sh 失败（返回 $RC）"
  echo "       先确认: cd $EDK2_DIR && make -C BaseTools"
  exit 3
fi
echo "[2/4] EDK2 环境就绪"

# ---------- 3. 选工具链 ----------
AVAIL="$(list_toolchains "$EDK2_DIR" || true)"
if [ -z "$AVAIL" ]; then
  echo "[错误] 读不到 $EDK2_DIR/Conf/tools_def.txt"
  echo "       先执行: cd $EDK2_DIR && make -C BaseTools && source edksetup.sh"
  exit 4
fi

if [ -z "$TOOLCHAIN" ]; then
  if ! TOOLCHAIN="$(detect_toolchain "$AVAIL")"; then
    echo "[错误] 自动探测工具链失败。你这份 EDK2 可用的工具链有："
    printf '        %s\n' $AVAIL
    echo "       请手动指定，例如: ./build-edk2.sh $EDK2_DIR <名字> $TARGET_KIND $ARCH"
    exit 4
  fi
  echo "       （自动探测到工具链: $TOOLCHAIN）"
else
  if ! printf '%s\n' "$AVAIL" | grep -qx "$TOOLCHAIN"; then
    echo "[错误] 你这份 EDK2 里没有工具链 '$TOOLCHAIN'。可用的有："
    printf '        %s\n' $AVAIL
    exit 4
  fi
fi
echo " 工具链   : $TOOLCHAIN"

# ---------- 4. 构建 ----------
build -p BootAnimPkg/BootAnimPkg.dsc -a "$ARCH" -t "$TOOLCHAIN" -b "$TARGET_KIND" \
      -n "$(nproc 2>/dev/null || echo 4)"
echo "[3/4] 构建完成"

EFI="$EDK2_DIR/Build/BootAnimPkg/${TARGET_KIND}_${TOOLCHAIN}/${ARCH}/BootAnim.efi"
if [ ! -f "$EFI" ]; then
  echo "[错误] 找不到产物: $EFI"
  echo "       请看上面 build 的输出，或到 $EDK2_DIR/Build/BootAnimPkg/ 下面找"
  exit 5
fi
mkdir -p "$PROJ/dist"
cp -f "$EFI" "$PROJ/dist/bootanim.efi"
SIZE=$(stat -c%s "$PROJ/dist/bootanim.efi" 2>/dev/null || stat -f%z "$PROJ/dist/bootanim.efi")
echo "[4/4] 产物: $PROJ/dist/bootanim.efi ($SIZE 字节)"
