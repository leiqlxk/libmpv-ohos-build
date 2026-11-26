#!/bin/bash
# patch-dex2oat.sh — 修复 dex2oat/mpv (d974ee3) 的 -Dohos=enabled 构建
#
# 问题：meson.build 与 vo.c 引用了仓库中从不存在的 3 个源文件
#   video/out/vo_ohcodec.c
#   video/out/ohos_osd.c
#   video/out/vo_ohcodec_osd.c
# 导致 meson setup 找不到源文件、链接期找不到 video_out_ohcodec* 符号。
#
# 策略：舍弃 vo=ohcodec 与 OSD overlay（我们用 vo=gpu，不需要它们）；
#      保留 hwdec_ohcodec.c / ohos_common.c / ao_ohaudio.c，不碰硬解。
# 幂等：重复执行不会二次改动，校验失败会明确报错退出。

set -eu

# mpv 源码目录：命令行参数 > MPV_DIR 环境变量 > 当前目录 > 仓库默认位置
MPV_DIR="${1:-${MPV_DIR:-}}"
if [ -z "$MPV_DIR" ]; then
  if [ -f meson.build ] && [ -d video/out ]; then
    MPV_DIR="$(pwd)"
  else
    MPV_DIR="$(cd "$(dirname "$0")"; pwd)/libmpv/mpv"
  fi
fi

if [ ! -f "$MPV_DIR/meson.build" ] || [ ! -f "$MPV_DIR/video/out/vo.c" ]; then
  echo "patch-dex2oat.sh: 找不到 mpv 源码: $MPV_DIR" >&2
  exit 1
fi

python3 - "$MPV_DIR" <<'PY'
import os
import sys

mpv_dir = sys.argv[1]


def patch(path, edits):
    """精确字符串替换；保留文件原有换行风格；已打过补丁则跳过。"""
    with open(path, 'r', encoding='utf-8', newline='') as f:
        text = f.read()
    nl = '\r\n' if '\r\n' in text else '\n'
    changed = False
    for old, new in edits:
        old_n = old.replace('\n', nl)
        new_n = new.replace('\n', nl)
        if old_n in text:
            text = text.replace(old_n, new_n, 1)
            changed = True
    if changed:
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(text)
    return changed


def read(path):
    with open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


# ---------------- meson.build ----------------
meson = os.path.join(mpv_dir, 'meson.build')
m_changed = patch(meson, [
    # 1) 只删不存在的 vo_ohcodec.c；保留同组的硬解与公共源
    (
        "                     'video/out/hwdec/hwdec_ohcodec.c',\n"
        "                     'video/out/vo_ohcodec.c')\n",
        "                     'video/out/hwdec/hwdec_ohcodec.c')\n",
    ),
    # 2) 整段删除 GLESv3 / ohos-osd-overlay 分支（两个源文件都不存在），
    #    连带去掉 config.h 里会自动生成的 HAVE_OHOS_OSD_OVERLAY 宏
    (
        "    # OSD overlay support for vo_ohcodec: EGL + OpenGL ES 3.0 renderer\n"
        "    # Uses a second transparent NativeWindow for subtitle/OSD rendering\n"
        "    glesv3_ohos = cc.find_library('GLESv3', required: false)\n"
        "    features += {'ohos-osd-overlay': glesv3_ohos.found()}\n"
        "    if glesv3_ohos.found()\n"
        "        dependencies += glesv3_ohos\n"
        "        sources += files('video/out/ohos_osd.c',\n"
        "                         'video/out/vo_ohcodec_osd.c')\n"
        "    endif\n",
        "",
    ),
])

# ---------------- options/options.h ----------------
# options.c:252 注册了 "ohos-surface-size" -> OPT_SIZE_BOX(ohos_surface_size)，
# 但 struct mp_vo_opts 缺少该成员（同 android_surface_size / d3d11_composition_size）。
# 补上它，否则编译报 no member named 'ohos_surface_size' in 'struct mp_vo_opts'。
opt_h = os.path.join(mpv_dir, 'options', 'options.h')
o_changed = patch(opt_h, [
    (
        "    struct m_geometry android_surface_size;\n",
        "    struct m_geometry android_surface_size;\n"
        "\n"
        "    struct m_geometry ohos_surface_size;\n",
    ),
])

# ---------------- video/out/vo.c ----------------
vo = os.path.join(mpv_dir, 'video', 'out', 'vo.c')
v_changed = patch(vo, [
    # 3) 删除两个 extern 声明（驱动已不在构建中）
    (
        "extern const struct vo_driver video_out_ohcodec;\n"
        "extern const struct vo_driver video_out_ohcodec_osd;\n",
        "",
    ),
    # 4) 删除整个 HAVE_OHOS 驱动列表块（含 HAVE_OHOS_OSD_OVERLAY 条件）
    (
        "#if HAVE_OHOS\n"
        "#if HAVE_OHOS_OSD_OVERLAY\n"
        "    &video_out_ohcodec_osd,\n"
        "#endif\n"
        "    &video_out_ohcodec,\n"
        "#endif\n",
        "",
    ),
])

# ---------------- 校验（同时保证幂等） ----------------
m = read(meson)
for gone in ('video/out/vo_ohcodec.c', 'video/out/ohos_osd.c',
             'video/out/vo_ohcodec_osd.c', 'ohos-osd-overlay', 'glesv3_ohos'):
    if gone in m:
        sys.exit('patch-dex2oat.sh: meson.build 仍引用 %s' % gone)
for kept in ('video/out/hwdec/hwdec_ohcodec.c', 'video/out/ohos_common.c',
             'audio/out/ao_ohaudio.c', 'video/out/opengl/context_ohos.c'):
    if kept not in m:
        sys.exit('patch-dex2oat.sh: meson.build 缺少应保留的 %s' % kept)

v = read(vo)
for gone in ('video_out_ohcodec', 'HAVE_OHOS_OSD_OVERLAY'):
    if gone in v:
        sys.exit('patch-dex2oat.sh: vo.c 仍引用 %s' % gone)
if '&video_out_gpu,' not in v:
    sys.exit('patch-dex2oat.sh: vo.c 驱动列表异常（缺 video_out_gpu）')

oh = read(opt_h)
if 'struct m_geometry ohos_surface_size;' not in oh:
    sys.exit('patch-dex2oat.sh: options.h 缺少 ohos_surface_size 成员')

print('patch-dex2oat.sh: meson.build=%s, options.h=%s, vo.c=%s' %
      ('patched' if m_changed else 'ok/already',
       'patched' if o_changed else 'ok/already',
       'patched' if v_changed else 'ok/already'))
PY
