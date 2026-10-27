#!/bin/sh
# 目的：依目前 Homebrew／pkg-config 產出原型用的 header 與 linker 路徑。
# 影響：只寫入 BuildSupport/Generated.xcconfig，不修改系統設定。
# 預期：檔案含 HEADER_SEARCH_PATHS 與 OTHER_LDFLAGS；發布版不得直接依賴此 Homebrew 路徑。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/BuildSupport/Generated.xcconfig"

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "找不到 pkg-config。請先安裝 Homebrew pkg-config。" >&2
  exit 1
fi

for module in spice-client-glib-2.0 glib-2.0 gstreamer-1.0; do
  if ! pkg-config --exists "$module"; then
    echo "找不到 pkg-config 模組：$module" >&2
    exit 1
  fi
done

cflags="$(pkg-config --cflags spice-client-glib-2.0 glib-2.0 gstreamer-1.0)"
libs="$(pkg-config --libs spice-client-glib-2.0 glib-2.0 gstreamer-1.0)"
# Homebrew bottle 以目前 SDK 建置；若仍寫 14.0，ld 會對每個 dylib 發出 version 警告。
sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || printf '%s' '14.0')"

header_paths=""
for token in $cflags; do
  case "$token" in
    -I*)
      path="${token#-I}"
      header_paths="$header_paths $path"
      ;;
  esac
done

# CocoaSpice SPM 已帶入 pkg-config 的 -Wl,-rpath；App 再寫一次會 duplicate rpath。
filtered_libs=""
for token in $libs; do
  case "$token" in
    -Wl,-rpath,*) ;;
    *) filtered_libs="$filtered_libs $token" ;;
  esac
done

{
  echo "// 由 BuildSupport/generate-xcconfig.sh 產生。不要手動編輯。"
  echo "// 這是階段 A 原型設定：連結 Homebrew 的 spice-gtk／GLib／GStreamer。"
  echo "// 階段 E 必須改為 App bundle 內嵌 dylib，且不得留下 Homebrew rpath。"
  echo "HEADER_SEARCH_PATHS = \$(inherited)$header_paths"
  echo "OTHER_LDFLAGS = \$(inherited)$filtered_libs -headerpad_max_install_names"
  echo "LIBRARY_SEARCH_PATHS = \$(inherited) /opt/homebrew/lib"
  echo "LD_RUNPATH_SEARCH_PATHS = \$(inherited) @executable_path/../Frameworks /opt/homebrew/lib"
  echo "MACOSX_DEPLOYMENT_TARGET = $sdk_version"
  echo "SWIFT_OBJC_BRIDGING_HEADER = MacRemoteViewer/Engine/MacRemoteViewer-Bridging-Header.h"
  echo "SWIFT_STRICT_CONCURRENCY = complete"
} > "$OUT"

echo "已寫入 $OUT"
