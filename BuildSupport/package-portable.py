#!/usr/bin/env python3
"""把 Release App 做成可攜 DMG：內嵌 Homebrew dylib、ad-hoc 簽署。

不上架、不公證。對方從 GitHub 下載會被標隔離屬性，需「仍要打開」。
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "MacRemoteViewer.xcodeproj"
SCHEME = "MacRemoteViewer"
APP_NAME = "Mac Remote Viewer.app"
RPATH_FRAMEWORKS = "@executable_path/../Frameworks"
RPATH_LOADER = "@loader_path"
RPATH_RESOURCE_FRAMEWORKS = "@loader_path/../../Frameworks"
HOST_PREFIXES = ("/opt/homebrew", "/usr/local", "/Users/")
SYSTEM_PREFIXES = ("/usr/lib", "/usr/lib/swift", "/System/", "/Library/Apple/")

# spice-gtk 執行期會 dlopen 的 GStreamer plugin（音訊關閉仍可能走 jpeg／vp8／h264）。
GST_PLUGIN_STEMS = (
    "libgstcoreelements",
    "libgstapp",
    "libgstplayback",
    "libgsttypefindfunctions",
    "libgstaudioconvert",
    "libgstaudioresample",
    "libgstaudioparsers",
    "libgstvolume",
    "libgstautodetect",
    "libgstosxaudio",
    "libgstvideoconvertscale",
    "libgstvideofilter",
    "libgstjpeg",
    "libgstjpegformat",
    "libgstvpx",
    "libgstlibav",
    "libgstapplemedia",
    "libgstvideoparsersbad",
)


class BundleError(RuntimeError):
    """打包失敗。"""


def run(args: list[str], *, cwd: Path | None = None) -> None:
    """執行命令；失敗時拋出詳細錯誤。"""
    completed = subprocess.run(args, cwd=cwd, check=False)
    if completed.returncode != 0:
        raise BundleError(f"命令失敗 ({completed.returncode})：{' '.join(args)}")


def capture(args: list[str]) -> str:
    """執行命令並回傳 stdout。"""
    completed = subprocess.run(args, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        raise BundleError(
            f"命令失敗 ({completed.returncode})：{' '.join(args)}\n{completed.stderr}"
        )
    return completed.stdout


def is_system_library(path: str) -> bool:
    """系統／Apple 提供的函式庫不打包。"""
    return path.startswith(SYSTEM_PREFIXES) or path.startswith("/usr/lib/")


def is_host_library(path: str) -> bool:
    """本機 Homebrew／DerivedData 路徑，發布時必須改寫。"""
    if is_system_library(path):
        return False
    if path.startswith("@") or path.startswith("/"):
        return path.startswith(HOST_PREFIXES) or "/Cellar/" in path
    return False


def is_mach_o(path: Path) -> bool:
    """判斷是否為 Mach-O 可執行檔或 dylib。"""
    if not path.is_file():
        return False
    description = capture(["file", "-b", str(path)])
    return "Mach-O" in description


def parse_macho(path: Path) -> tuple[str | None, list[str], list[str]]:
    """解析 LC_ID_DYLIB、load dylib 與 rpath。"""
    output = capture(["otool", "-l", str(path)])
    ident: str | None = None
    dylibs: list[str] = []
    rpaths: list[str] = []
    lines = output.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        if line in {"cmd LC_ID_DYLIB", "cmd LC_LOAD_DYLIB", "cmd LC_LOAD_WEAK_DYLIB", "cmd LC_REEXPORT_DYLIB"}:
            cmd = line.split()[-1]
            for ahead in lines[index + 1 : index + 8]:
                match = re.search(r"name\s+(\S+)", ahead)
                if match:
                    name = match.group(1)
                    if cmd == "LC_ID_DYLIB":
                        ident = name
                    else:
                        dylibs.append(name)
                    break
        elif line == "cmd LC_RPATH":
            for ahead in lines[index + 1 : index + 8]:
                match = re.search(r"path\s+(\S+)", ahead)
                if match:
                    rpaths.append(match.group(1))
                    break
        index += 1
    return ident, dylibs, rpaths


def expand_load_path(dep: str, *, loader: Path, executable: Path, rpaths: list[str]) -> Path | None:
    """把 load command 展開成本機真實路徑。"""
    executable_dir = executable.parent
    loader_dir = loader.parent
    replaced = (
        dep.replace("@executable_path", str(executable_dir))
        .replace("@loader_path", str(loader_dir))
    )
    if replaced.startswith("@rpath/"):
        rest = replaced[len("@rpath/") :]
        for rpath in rpaths:
            prefix = (
                rpath.replace("@executable_path", str(executable_dir))
                .replace("@loader_path", str(loader_dir))
            )
            if prefix.startswith("@rpath"):
                continue
            candidate = Path(prefix) / rest
            if candidate.exists():
                return candidate.resolve()
        return None
    candidate = Path(replaced)
    if candidate.exists():
        return candidate.resolve()
    return None


def chmod_writable(path: Path) -> None:
    """Homebrew bottle 常為 555，改寫 install name 前必須可寫。"""
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IWUSR)


def copy_binary(source: Path, destination: Path) -> None:
    """複製 Mach-O 並解除唯讀。"""
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    chmod_writable(destination)
    try:
        run(["codesign", "--remove-signature", str(destination)])
    except BundleError:
        # 未簽署的二進位會失敗，可忽略。
        pass


def dest_name_for(install_name: str, source: Path) -> str:
    """Frameworks 內使用 install name 的檔名，讓 @rpath 對得上。"""
    base = Path(install_name).name
    return base if base else source.name


def is_inside(path: Path, root: Path) -> bool:
    """path 是否位於 root 之內（含已複製進 App 的檔案）。"""
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def collect_host_libraries(seed: Path, *, executable: Path, app_root: Path) -> dict[str, Path]:
    """遞迴收集所有本機依賴，key 為發布時的檔名。"""
    queued: list[Path] = [seed]
    seen_files: set[Path] = set()
    bundled: dict[str, Path] = {}

    while queued:
        current = queued.pop()
        if current in seen_files or not current.exists():
            continue
        seen_files.add(current)
        if not is_mach_o(current):
            continue
        ident, dylibs, rpaths = parse_macho(current)
        for dep in dylibs:
            resolved = expand_load_path(
                dep, loader=current, executable=executable, rpaths=rpaths
            )
            if resolved is None:
                if is_host_library(dep):
                    raise BundleError(f"找不到本機依賴：{dep}（來自 {current}）")
                continue
            if is_inside(resolved, app_root):
                continue
            if is_system_library(str(resolved)) or is_system_library(dep):
                continue
            if not (is_host_library(dep) or is_host_library(str(resolved))):
                continue
            name = dest_name_for(dep, resolved)
            if name not in bundled:
                bundled[name] = resolved
                queued.append(resolved)
        if ident and is_host_library(ident) and not is_inside(current, app_root):
            name = dest_name_for(ident, current)
            bundled.setdefault(name, current)

    return bundled


def find_gst_plugin_dir() -> Path:
    """定位 Homebrew GStreamer plugin 目錄。"""
    for candidate in (Path("/opt/homebrew/lib/gstreamer-1.0"), Path("/usr/local/lib/gstreamer-1.0")):
        if candidate.exists():
            return Path(os.path.realpath(candidate))
    raise BundleError("找不到 GStreamer plugin 目錄。請先安裝 Homebrew gstreamer。")


def find_gst_scanner() -> Path | None:
    """定位 gst-plugin-scanner。"""
    for candidate in (
        Path("/opt/homebrew/opt/gstreamer/libexec/gstreamer-1.0/gst-plugin-scanner"),
        Path("/usr/local/opt/gstreamer/libexec/gstreamer-1.0/gst-plugin-scanner"),
    ):
        if candidate.exists():
            return candidate.resolve()
    return None


def find_openssl_modules() -> Path | None:
    """定位 OpenSSL provider modules。"""
    for candidate in (
        Path("/opt/homebrew/opt/openssl@4/lib/ossl-modules"),
        Path("/opt/homebrew/opt/openssl@3/lib/ossl-modules"),
        Path("/usr/local/opt/openssl@3/lib/ossl-modules"),
    ):
        if candidate.is_dir():
            return candidate
    return None


def ensure_rpath(binary: Path, rpath: str) -> None:
    """若尚未有指定 rpath 則加入。"""
    _, _, rpaths = parse_macho(binary)
    if rpath in rpaths:
        return
    run(["install_name_tool", "-add_rpath", rpath, str(binary)])


def delete_host_rpaths(binary: Path) -> None:
    """刪除 Homebrew／使用者目錄 rpath。"""
    _, _, rpaths = parse_macho(binary)
    for rpath in rpaths:
        expanded_is_host = is_host_library(rpath) or rpath.startswith(HOST_PREFIXES)
        if expanded_is_host:
            run(["install_name_tool", "-delete_rpath", rpath, str(binary)])


def rewrite_load_commands(binary: Path, *, id_path: str | None, extra_rpath: str) -> None:
    """把本機路徑改成 @rpath，並設定可攜 rpath。"""
    ident, dylibs, _rpaths = parse_macho(binary)
    if id_path and ident and ident != id_path:
        run(["install_name_tool", "-id", id_path, str(binary)])
    for dep in dylibs:
        if is_host_library(dep):
            new_dep = f"@rpath/{Path(dep).name}"
            if dep != new_dep:
                run(["install_name_tool", "-change", dep, new_dep, str(binary)])
    delete_host_rpaths(binary)
    ensure_rpath(binary, extra_rpath)


def iter_macho_files(app: Path) -> list[Path]:
    """App bundle 內所有 Mach-O。"""
    files: list[Path] = []
    for path in app.rglob("*"):
        if path.is_file() and is_mach_o(path):
            files.append(path)
    return files


def adhoc_sign(
    path: Path,
    *,
    entitlements: Path | None = None,
    identifier: str | None = None,
) -> None:
    """ad-hoc 簽署；無 Developer ID、不做 timestamp。

    App bundle 要帶 identifier，否則 designated requirement 會是空的，
    Launch Services／Spotlight Apps 有時不會把這份 bundle 當正式 App。
    """
    args = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
    if identifier is not None:
        args.extend(["--identifier", identifier])
    if entitlements is not None:
        args.extend(["--entitlements", str(entitlements)])
    args.append(str(path))
    run(args)


def verify_no_host_paths(app: Path) -> None:
    """確認發布包不再引用 Homebrew 或使用者路徑。"""
    leftovers: list[str] = []
    for binary in iter_macho_files(app):
        ident, dylibs, rpaths = parse_macho(binary)
        for item in [ident, *dylibs, *rpaths]:
            if item and is_host_library(item):
                leftovers.append(f"{binary.relative_to(app)} → {item}")
    if leftovers:
        joined = "\n".join(leftovers)
        raise BundleError(f"仍有本機路徑，不可發布：\n{joined}")


def app_version(app: Path) -> str:
    """讀取 CFBundleShortVersionString。"""
    plist = app / "Contents" / "Info.plist"
    return capture(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", str(plist)]).strip()


def write_open_instructions(path: Path, *, version: str, minimum_os: str) -> None:
    """給下載者看的隔離屬性說明。"""
    path.write_text(
        f"""Mac Remote Viewer {version}

這份 DMG 沒有 Apple Developer ID，也沒有公證。
從 GitHub 下載後，macOS 會標上隔離屬性，第一次開啟會被擋。

安裝：

1. 打開 DMG
2. 把「Mac Remote Viewer」拖到同一個視窗裡的 Applications 資料夾
3. 退出磁碟映像

macOS 27 沒有 Launchpad。請用下面方式找到它：

- Finder → 應用程式 → 英文名稱「Mac Remote Viewer」
- Spotlight（Command-空白鍵）搜尋 Mac Remote Viewer
- Spotlight 的 Apps 網格：英文名稱，排在 Lunport 與 Maccy 之間
  若剛裝完還沒出現，先從 Finder 打開一次，或關掉 Spotlight 再開

第一次開啟請用其中一種方式：

1. 按住 Control 鍵點 App → 打開 → 打開
2. 系統設定 → 隱私權與安全性 → 仍要打開
3. 終端機（進階）：
   xattr -cr "/Applications/Mac Remote Viewer.app"

系統需求：
- Apple Silicon（arm64）
- macOS {minimum_os} 或更新版本
- 不需要安裝 Homebrew 或 Xcode

請不要長期從 DMG 裡面直接執行；拖到「應用程式」後再打開。

雙擊 .vv：
第一次從「應用程式」打開 App 一次後，Finder 才會把 .vv 關聯過來。
若仍開錯程式，在檔案「顯示簡介 → 打開方式」指定 Mac Remote Viewer，再按「全部更改」。
""",
        encoding="utf-8",
    )


def build_app(build_dir: Path) -> Path:
    """以 ad-hoc、允許改寫 install name 的方式建置 Release。"""
    build_dir.mkdir(parents=True, exist_ok=True)
    developer = Path("/Applications/Xcode.app/Contents/Developer")
    env = os.environ.copy()
    if developer.exists():
        env["DEVELOPER_DIR"] = str(developer)
    args = [
        "xcodebuild",
        "-project",
        str(PROJECT),
        "-scheme",
        SCHEME,
        "-configuration",
        "Release",
        "-destination",
        "platform=macOS,arch=arm64",
        f"SYMROOT={build_dir / 'sym'}",
        f"OBJROOT={build_dir / 'obj'}",
        "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGN_IDENTITY=-",
        "CODE_SIGN_STYLE=Manual",
        "CODE_SIGNING_REQUIRED=YES",
        "DEVELOPMENT_TEAM=",
        "build",
    ]
    completed = subprocess.run(args, cwd=ROOT, env=env, check=False)
    if completed.returncode != 0:
        raise BundleError("xcodebuild Release 失敗。請確認已執行 generate-xcconfig.sh 與 bootstrap-cocoaspice.sh。")
    app = build_dir / "sym" / "Release" / APP_NAME
    if not app.exists():
        raise BundleError(f"找不到建置產物：{app}")
    return app


def bundle_into(app: Path) -> None:
    """把本機 dylib／plugin 嵌進 App，並改成可攜 rpath。"""
    executable = app / "Contents" / "MacOS" / "Mac Remote Viewer"
    if not executable.exists():
        raise BundleError(f"找不到執行檔：{executable}")

    frameworks = app / "Contents" / "Frameworks"
    plugins = app / "Contents" / "Resources" / "gstreamer-1.0"
    openssl_dest = app / "Contents" / "Resources" / "ossl-modules"
    frameworks.mkdir(parents=True, exist_ok=True)
    plugins.mkdir(parents=True, exist_ok=True)

    seeds: list[Path] = [executable]
    gst_dir = find_gst_plugin_dir()
    for stem in GST_PLUGIN_STEMS:
        source = gst_dir / f"{stem}.dylib"
        if not source.exists():
            print(f"略過缺少的 GStreamer plugin：{stem}", file=sys.stderr)
            continue
        destination = plugins / source.name
        copy_binary(source.resolve(), destination)
        seeds.append(destination)

    scanner = find_gst_scanner()
    if scanner is not None:
        scanner_dest = app / "Contents" / "MacOS" / "gst-plugin-scanner"
        copy_binary(scanner, scanner_dest)
        seeds.append(scanner_dest)

    openssl_modules = find_openssl_modules()
    if openssl_modules is not None:
        openssl_dest.mkdir(parents=True, exist_ok=True)
        for module in openssl_modules.glob("*.dylib"):
            destination = openssl_dest / module.name
            copy_binary(module.resolve(), destination)
            seeds.append(destination)

    bundled: dict[str, Path] = {}
    for seed in seeds:
        bundled.update(collect_host_libraries(seed, executable=executable, app_root=app))

    copied: dict[str, Path] = {}
    for name, source in bundled.items():
        destination = frameworks / name
        if destination.exists() and destination.resolve() == source.resolve():
            copied[name] = destination
            continue
        copy_binary(source, destination)
        copied[name] = destination

    try:
        run(["codesign", "--remove-signature", str(executable)])
    except BundleError:
        pass
    rewrite_load_commands(executable, id_path=None, extra_rpath=RPATH_FRAMEWORKS)
    for name, binary in copied.items():
        rewrite_load_commands(
            binary,
            id_path=f"@rpath/{name}",
            extra_rpath=RPATH_LOADER,
        )
    for plugin in plugins.glob("*.dylib"):
        rewrite_load_commands(
            plugin,
            id_path=f"@loader_path/{plugin.name}",
            extra_rpath=RPATH_RESOURCE_FRAMEWORKS,
        )
    scanner_dest = app / "Contents" / "MacOS" / "gst-plugin-scanner"
    if scanner_dest.exists():
        rewrite_load_commands(
            scanner_dest,
            id_path=None,
            extra_rpath="@loader_path/../Frameworks",
        )
    if openssl_dest.exists():
        for module in openssl_dest.glob("*.dylib"):
            rewrite_load_commands(
                module,
                id_path=f"@loader_path/{module.name}",
                extra_rpath=RPATH_RESOURCE_FRAMEWORKS,
            )


def sign_app(app: Path) -> None:
    """先簽內嵌 Mach-O，最後簽 .app（主執行檔由 bundle 簽署帶上）。"""
    entitlements = ROOT / "MacRemoteViewer" / "App" / "MacRemoteViewer.entitlements"
    main_exe = app / "Contents" / "MacOS" / "Mac Remote Viewer"
    for binary in iter_macho_files(app):
        if binary == main_exe:
            continue
        adhoc_sign(binary)
    adhoc_sign(
        app,
        entitlements=entitlements,
        identifier="com.macremoteviewer.app",
    )


def create_compressed_dmg(*, source: Path, destination: Path, volume_name: str) -> None:
    """建立可拖放安裝的 UDZO／HFS+ DMG。

    不用 diskutil image 的 APFS：那種映像裡的 Applications 捷徑在 Finder
    不會顯示成資料夾，拖放後常以為沒裝進去。hdiutil 在 macOS 27 已標示
    deprecated，但目前仍是唯一能指定 HFS+ 安裝映像的穩定做法。
    """
    if destination.exists():
        destination.unlink()
    run(
        [
            "hdiutil",
            "create",
            "-volname",
            volume_name,
            "-srcfolder",
            str(source),
            "-ov",
            "-format",
            "UDZO",
            "-fs",
            "HFS+",
            str(destination),
        ]
    )


def make_dmg(app: Path, dist_dir: Path) -> Path:
    """產生可拖到「應用程式」的 DMG。"""
    version = app_version(app)
    minimum_os = capture(
        [
            "/usr/libexec/PlistBuddy",
            "-c",
            "Print :LSMinimumSystemVersion",
            str(app / "Contents" / "Info.plist"),
        ]
    ).strip()
    artifact_stem = f"MacRemoteViewer-{version}-arm64"
    stage = dist_dir.resolve() / "stage" / artifact_stem
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    shutil.copytree(app, stage / APP_NAME, symlinks=True)
    applications_link = stage / "Applications"
    if applications_link.exists() or applications_link.is_symlink():
        applications_link.unlink()
    applications_link.symlink_to("/Applications")
    write_open_instructions(stage / "如何開啟.txt", version=version, minimum_os=minimum_os)
    notices = ROOT / "ThirdPartyNotices" / "NOTICE.md"
    if notices.exists():
        shutil.copy2(notices, stage / "NOTICE.md")

    dmg_path = dist_dir.resolve() / f"{artifact_stem}.dmg"
    create_compressed_dmg(
        source=stage,
        destination=dmg_path,
        volume_name="Mac Remote Viewer",
    )
    for leftover in dist_dir.resolve().glob(f"{artifact_stem}.zip*"):
        leftover.unlink()

    digest = hashlib.sha256(dmg_path.read_bytes()).hexdigest()
    dmg_path.with_suffix(".dmg.sha256").write_text(f"{digest}  {dmg_path.name}\n", encoding="utf-8")
    return dmg_path


def selftest_path_rules() -> None:
    """路徑分類的行為檢查。"""
    assert is_system_library("/usr/lib/libz.1.dylib")
    assert is_system_library("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")
    assert is_host_library("/opt/homebrew/lib/libglib-2.0.0.dylib")
    assert is_host_library("/opt/homebrew/Cellar/glib/2.90.1/lib/libglib-2.0.0.dylib")
    assert not is_host_library("@rpath/libglib-2.0.0.dylib")
    assert not is_host_library("/usr/lib/libSystem.B.dylib")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="打包可攜、未公證的 macOS DMG")
    parser.add_argument("--skip-build", action="store_true", help="重用 build/package 裡的 Release App")
    parser.add_argument("--app", type=Path, help="直接處理既有 .app（仍會複製後改寫）")
    return parser.parse_args()


def main() -> int:
    selftest_path_rules()
    args = parse_args()
    dist_dir = ROOT / "dist"
    build_dir = ROOT / "build" / "package"
    dist_dir.mkdir(parents=True, exist_ok=True)

    if args.app:
        source_app = args.app.expanduser().resolve()
        if not source_app.exists():
            raise BundleError(f"找不到 App：{source_app}")
    elif args.skip_build:
        source_app = build_dir / "sym" / "Release" / APP_NAME
        if not source_app.exists():
            raise BundleError("沒有既有 Release App，請先不要加 --skip-build")
    else:
        source_app = build_app(build_dir)

    work_app = dist_dir / "work" / APP_NAME
    if work_app.exists():
        shutil.rmtree(work_app)
    work_app.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source_app, work_app, symlinks=True)

    bundle_into(work_app)
    sign_app(work_app)
    verify_no_host_paths(work_app)
    dmg_path = make_dmg(work_app, dist_dir)
    size_mib = dmg_path.stat().st_size / (1024 * 1024)
    print(f"已寫入 {dmg_path}（{size_mib:.1f} MiB）")
    print(f"SHA-256：{dmg_path.with_suffix('.dmg.sha256').read_text().split()[0]}")
    print("這份 DMG 沒有公證。對方需把 App 拖到「應用程式」，再依「如何開啟.txt」放行隔離屬性。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BundleError as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
