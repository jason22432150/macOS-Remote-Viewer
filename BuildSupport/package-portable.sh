#!/bin/sh
# 目的：建置 Release，把 Homebrew dylib 打進 App，產出可攜 DMG。
# 影響：寫入 dist/ 與 build/package/；不修改系統套件，也不簽署 Developer ID。
# 預期：dist/MacRemoteViewer-*-arm64.dmg 與對應 .sha256；對方需手動放行隔離屬性。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

"$ROOT/BuildSupport/generate-xcconfig.sh"
python3 "$ROOT/BuildSupport/package-portable.py" "$@"
