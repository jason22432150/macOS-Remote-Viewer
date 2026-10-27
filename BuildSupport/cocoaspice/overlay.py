#!/usr/bin/env python3
"""對鎖定的 CocoaSpice checkout 套用 Homebrew 相容 overlay。"""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = Path(__file__).resolve().parent
CHECKOUT = ROOT / "ThirdParty" / "CocoaSpice"


def overlay_gst_ios_init(checkout: Path) -> None:
    source = OVERLAY / "gst_ios_init.m"
    target = checkout / "Sources" / "CocoaSpice" / "gst_ios_init.m"
    shutil.copyfile(source, target)


def overlay_csmain(checkout: Path) -> None:
    path = checkout / "Sources" / "CocoaSpice" / "CSMain.m"
    text = path.read_text()
    replacements = [
        (
            "    if ((_main_context = g_main_context_new()) == NULL) {",
            "    // Homebrew spice-gtk 沒有 spice_util_set_main_context，改跑 default context。\n"
            "    if ((_main_context = g_main_context_ref(g_main_context_default())) == NULL) {",
        ),
        (
            "            spice_util_set_main_context(_main_context);\n",
            "            // spice_util_set_main_context 僅存在於 UTM spice-gtk fork。\n",
        ),
        (
            "            spice_util_set_main_context(NULL);\n",
            "",
        ),
    ]
    for old, new in replacements:
        if old not in text:
            raise SystemExit(f"找不到 CSMain.m 預期片段:\n{old}")
        text = text.replace(old, new, 1)
    path.write_text(text)


def pkgconfig_tokens(*args: str) -> list[str]:
    output = subprocess.check_output(["pkg-config", *args], text=True)
    return [token for token in output.split() if token]


def swift_string_list(values: list[str]) -> str:
    inner = ", ".join(f'"{item}"' for item in values)
    return f"[{inner}]"


def overlay_package_swift(checkout: Path) -> None:
    path = checkout / "Package.swift"
    text = path.read_text()
    marker = '.headerSearchPath("ExternalHeaders/spice-client-glib-2.0")]),'
    if marker not in text:
        raise SystemExit("找不到 Package.swift 的 CocoaSpice cSettings 結尾")

    cflags = pkgconfig_tokens("--cflags", "spice-client-glib-2.0", "glib-2.0", "gstreamer-1.0")
    libs = pkgconfig_tokens("--libs", "spice-client-glib-2.0", "glib-2.0", "gstreamer-1.0")
    replacement = (
        '.headerSearchPath("ExternalHeaders/spice-client-glib-2.0"),\n'
        f"                .unsafeFlags({swift_string_list(cflags)})],\n"
        "            linkerSettings: [\n"
        f"                .unsafeFlags({swift_string_list(libs)})]),"
    )
    text = text.replace(marker, replacement)
    path.write_text(text)


def main() -> None:
    checkout = Path(sys.argv[1]) if len(sys.argv) > 1 else CHECKOUT
    if not (checkout / "Package.swift").exists():
        raise SystemExit(f"CocoaSpice checkout 不存在：{checkout}")
    overlay_gst_ios_init(checkout)
    overlay_csmain(checkout)
    overlay_package_swift(checkout)
    print(f"已套用 Homebrew overlay：{checkout}")


if __name__ == "__main__":
    main()
