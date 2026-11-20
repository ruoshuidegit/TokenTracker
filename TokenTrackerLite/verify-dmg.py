#!/usr/bin/env python3
"""挂载安装包，校验拖放布局、实际应用签名及离线运行，不启动 GUI。"""

import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

from ds_store import DSStore


ROOT = Path(__file__).resolve().parent


def verify(image):
    mount = Path(tempfile.mkdtemp(prefix="verify-dmg-", dir=ROOT / ".build"))
    attached = False
    try:
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image)],
                       check=True, capture_output=True, text=True)
        attached = True
        app = mount / "TokenTracker Lite.app"
        if not app.is_dir() or not (mount / "Applications").is_symlink():
            raise RuntimeError("安装包缺少应用或 Applications 快捷方式")
        if os.readlink(mount / "Applications") != "/Applications":
            raise RuntimeError("Applications 快捷方式目标错误")
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            assert store[app.name]["Iloc"] == (170, 180)
            assert store["Applications"]["Iloc"] == (490, 180)
            assert store["."]["icvp"]["iconSize"] == 128
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        source = ROOT / "dist/TokenTracker Lite.app"
        for original in source.rglob("*"):
            if original.is_file():
                relative = original.relative_to(source)
                if hashlib.sha256(original.read_bytes()).digest() != hashlib.sha256((app / relative).read_bytes()).digest():
                    raise RuntimeError(f"安装包应用文件不一致：{relative}")
        subprocess.run(["python3", str(ROOT / "verify-bundle.py"), str(app)], check=True)
        version = plistlib.load((app / "Contents/Info.plist").open("rb"))["CFBundleShortVersionString"]
        print(f"安装包挂载验证通过：版本 {version}，布局、应用签名、文件与运行验证均通过")
    finally:
        if attached:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True, capture_output=True, text=True)
        if mount.exists():
            shutil.rmtree(mount)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("用法：verify-dmg.py <安装包.dmg>")
    verify(Path(sys.argv[1]).resolve())
