#!/bin/bash

set -eu

ROOT_DIR=$(cd $(dirname "$0")/..; pwd)

. $ROOT_DIR/env.sh

pushd $ROOT_DIR/libmpv/mpv

if [ "$1" == "build" ]; then
	echo -e "\nBuilding mpv..."
	"$ROOT_DIR/patch-dex2oat.sh" "$ROOT_DIR/libmpv/mpv"
elif [ "$1" == "clean" ]; then
	rm -rf .build
	exit 0
else
	exit 1
fi

mkdir -p .build
cd .build

meson setup .. \
  --cross-file $ROOT_DIR/libmpv/arm64-crossfile.ini \
  --prefix=$DEST/mpv \
  --default-library shared \
  --strip \
  -Dopensles=disabled \
  -Dohos=enabled \
  -Degl-ohos=enabled \
  -Dvulkan=enabled \
  -Dshaderc=enabled \
  -Dlua=enabled \
  -Dgpl=false \
  -Dbuild-date=false \
  -Dcplayer=false \
  -Dmanpage-build=disabled
ninja -j$CORES
ninja install

cd $DEST/mpv/lib
# libmpv.so 是指向 libmpv.so.2 的相对符号链接；直接 mv 会造成断链，zip 打包失败。
# 用 cp -L 解引用为真实文件内容，保证产物可独立下载。
cp -L libmpv.so ../../libmpv.so

popd