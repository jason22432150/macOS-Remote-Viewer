#!/bin/sh
# 目的：取得鎖定的 CocoaSpice commit，並套用 Homebrew 相容 overlay。
# 影響：寫入 ThirdParty/CocoaSpice（不進 git）；不修改系統套件。
# 預期：該目錄含 Package.swift，且 gst_ios_init.m / CSMain.m 已 overlay。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ThirdParty/CocoaSpice"
REPO="https://github.com/utmapp/CocoaSpice.git"
REVISION="d8d29fc810047a3ddcebb351cdadc8fe4b4f308d"

mkdir -p "$ROOT/ThirdParty"

if [ ! -d "$DEST/.git" ]; then
  rm -rf "$DEST"
  git clone "$REPO" "$DEST"
fi

git -C "$DEST" fetch --force origin
git -C "$DEST" checkout --force "$REVISION"
git -C "$DEST" reset --hard "$REVISION"
git -C "$DEST" clean -fdx

python3 "$ROOT/BuildSupport/cocoaspice/overlay.py" "$DEST"

echo "CocoaSpice 已就緒：$DEST @$REVISION"
