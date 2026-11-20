#!/usr/bin/env python3
"""获取与原项目相同版本的独立 Node 运行时，避免 Homebrew 动态库依赖。"""

import hashlib
import os
from pathlib import Path
import platform
import sys
import tarfile
import urllib.request


VERSION = "22.22.2"
ARCH = {"arm64": "arm64", "x86_64": "x64"}[platform.machine()]
NAME = f"node-v{VERSION}-darwin-{ARCH}"
CACHE = Path(__file__).resolve().parent / ".build" / NAME
NODE = CACHE / "bin/node"
LICENSE = CACHE / "LICENSE"


def prepare():
    if NODE.is_file() and LICENSE.is_file():
        return NODE
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / "node.tar.gz"
    base = f"https://nodejs.org/dist/v{VERSION}"
    filename = NAME + ".tar.gz"
    print(f"正在获取官方 Node.js {VERSION}（{ARCH}）…", file=sys.stderr)
    with urllib.request.urlopen(base + "/SHASUMS256.txt", timeout=30) as response:
        checksums = dict(line.split()[::-1] for line in response.read().decode().splitlines())
    expected = checksums[filename]
    digest = hashlib.sha256()
    with urllib.request.urlopen(base + "/" + filename, timeout=30) as response, archive.open("wb") as output:
        while chunk := response.read(256 * 1024):
            output.write(chunk)
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise RuntimeError("Node.js 运行时校验失败")
    with tarfile.open(archive, "r:gz") as source:
        for relative in ["bin/node", "LICENSE"]:
            member = source.getmember(NAME + "/" + relative)
            if not member.isfile():
                raise RuntimeError("Node.js 归档格式无效")
            target = CACHE / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as content, target.open("wb") as output:
                while chunk := content.read(256 * 1024):
                    output.write(chunk)
    os.chmod(NODE, 0o755)
    archive.unlink()
    return NODE


if __name__ == "__main__":
    print(prepare())
