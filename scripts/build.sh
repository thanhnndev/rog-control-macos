#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) 2026 thanhnndev and contributors
# Builds the kexts of this repo on macOS without an Xcode project. Needs the Xcode command line tools.
# Kernel headers/libs come from acidanthera/MacKernelSDK (cloned into build/ on first use, or set MACKERNELSDK).
#
#   scripts/build.sh            build AsusWmi and AmdCppc into build/*.kext
#   scripts/build.sh AsusWmi    build only the named kext(s)
set -euo pipefail
cd "$(dirname "$0")/.."

SDK_DIR="${MACKERNELSDK:-build/MacKernelSDK}"
if [ ! -d "$SDK_DIR" ]; then
  mkdir -p build
  git clone --depth 1 https://github.com/acidanthera/MacKernelSDK "$SDK_DIR"
fi

# -nostdlibinc: only MacKernelSDK and clang's own headers
COMMON="-arch x86_64 -mmacosx-version-min=12.0 -O2 -g -mkernel -fno-builtin -fno-stack-protector -nostdlib -nostdlibinc -ffreestanding -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT -I$SDK_DIR/Headers"
CXXFLAGS="-std=c++17 -fapple-kext -fno-exceptions -fno-rtti"     # -fapple-kext is C++ only
# libkmodc++/libcc_kext come from the installed SDK (MacKernelSDK has only libkmod) and are built for that SDK's macOS.
# Linking with a lower deployment target makes ld warn "built for newer macOS version"; link with the library's own
# minimum instead (the kernel does not check a kext's minos). Compilation stays at 12.0.
LINK_MIN=$(otool -l "$(xcrun --show-sdk-path)/usr/lib/libkmodc++.a" 2>/dev/null | awk '/minos/ {print $2; exit}')
LINK_MIN=${LINK_MIN:-12.0}
OBJ=build/obj
mkdir -p "$OBJ"

# build_kext <name> <source dir> <source files...>
# Bundle layout: build/<name>.kext/Contents/{Info.plist,MacOS/<name>}
build_kext() {
  local name="$1" dir="$2"; shift 2
  local out="build/$name.kext" objs=()
  rm -rf "$out"; mkdir -p "$out/Contents/MacOS"
  cp "$dir/Info.plist" "$out/Contents/Info.plist"
  for src in "$@"; do
    local o="$OBJ/${name}_$(basename "${src%.*}").o"
    case "$src" in
      *.cpp) clang++ $COMMON $CXXFLAGS -I"$dir" -c "$dir/$src" -o "$o" ;;
      *.c)   clang   $COMMON -I"$dir" -c "$dir/$src" -o "$o" ;;
    esac
    objs+=("$o")
  done
  clang++ -arch x86_64 -mmacosx-version-min="$LINK_MIN" -nostdlib -Xlinker -kext -Xlinker -no_data_const \
    -L"$SDK_DIR/Library/x86_64" -lkmodc++ -lkmod -lcc_kext "${objs[@]}" -o "$out/Contents/MacOS/$name"
  echo "built $out"
  file "$out/Contents/MacOS/$name"
  echo "--- undefined symbols ($name)"
  nm -um "$out/Contents/MacOS/$name" || true
}

want() { local n="$1"; shift; [ $# -eq 0 ] && return 0; for a in "$@"; do [ "$a" = "$n" ] && return 0; done; return 1; }
TARGETS=("$@")

want AsusWmi "${TARGETS[@]+"${TARGETS[@]}"}" && build_kext AsusWmi kexts/AsusWmi kmod_info.c AsusWmi.cpp
want AmdCppc "${TARGETS[@]+"${TARGETS[@]}"}" && build_kext AmdCppc kexts/AmdCppc kmod_info.c AmdCppc.cpp
want StrixDgpuGate "${TARGETS[@]+"${TARGETS[@]}"}" && build_kext StrixDgpuGate kexts/StrixDgpuGate kmod_info.c StrixDgpuGate.cpp
exit 0
