#!/usr/bin/env python3
"""从 macOS/Windows 构建自包含的 Windows x64 安装包，不打包用户密钥或缓存。"""
import argparse
import hashlib
import os
import re
from pathlib import Path
import shutil
import struct
import subprocess
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
LITE = HERE.parent
REPO = LITE.parent
BUILD = LITE / '.build'
VERSION = '0.2.2'

def amd64(path):
    with path.open('rb') as stream:
        assert stream.read(2) == b'MZ', path.name
        stream.seek(0x3c); offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(offset)
        assert stream.read(4) == b'PE\0\0', path.name
        assert struct.unpack('<H', stream.read(2))[0] == 0x8664, f'{path.name} 不是 x64'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--no-publish', action='store_true')
    parser.add_argument('--output-dir', type=Path, default=LITE / 'dist')
    args = parser.parse_args()
    publish = BUILD / 'windows-publish'
    if not args.no_publish:
        dotnet = os.environ.get('TOKENTRACKER_DOTNET') or shutil.which('dotnet') or str(BUILD / 'dotnet/dotnet')
        env = dict(os.environ, DOTNET_CLI_HOME=str(BUILD / 'dotnet-home'), NUGET_PACKAGES=str(BUILD / 'nuget'),
                   DOTNET_NOLOGO='1', DOTNET_CLI_TELEMETRY_OPTOUT='1')
        subprocess.run([dotnet, 'publish', str(HERE / 'TokenTrackerLite.Windows.csproj'), '-c', 'Release', '-r', 'win-x64',
                        '--self-contained', 'true', '-p:PublishSingleFile=false', '-o', str(publish)], env=env, check=True)
    amd64(publish / 'TokenTrackerLite.exe')
    amd64(publish / 'coreclr.dll')
    resources = publish / 'Resources'
    worker = resources / 'TokenTrackerLite'
    worker.mkdir(parents=True, exist_ok=True)
    node_version = '22.22.2'
    filename = f'node-v{node_version}-win-x64.zip'
    base = f'https://nodejs.org/dist/v{node_version}'
    archive = BUILD / filename
    with urllib.request.urlopen(base + '/SHASUMS256.txt', timeout=30) as response:
        checksums = dict(line.split()[::-1] for line in response.read().decode().splitlines())
    expected = checksums[filename]
    if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        print('正在下载官方 Windows x64 Node.js 运行时…', flush=True)
        with urllib.request.urlopen(base + '/' + filename, timeout=30) as response, archive.open('wb') as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected: raise RuntimeError('Node.js 官方 SHA256 校验失败')
    with zipfile.ZipFile(archive) as source:
        prefix = filename.removesuffix('.zip')
        (resources / 'node.exe').write_bytes(source.read(prefix + '/node.exe'))
        (resources / 'NODE_LICENSE').write_bytes(source.read(prefix + '/LICENSE'))
    amd64(resources / 'node.exe')
    for name in ['queue-store.cjs', 'local-collect.cjs', 'antigravity-attribution.cjs', 'antigravity-read-view.cjs', 'lite-pricing.cjs', 'lite-pricing.json']:
        shutil.copy2(LITE / name, worker / name)
    subprocess.run([shutil.which('node') or 'node', str(LITE / 'bundle-runtime.cjs'), str(resources)], check=True)
    shutil.copy2(REPO / 'TokenTrackerWin/assets/trayicon.ico', publish / 'AppIcon.ico')
    private_names = {'snapshot.json', 'topapi-snapshot.json', 'queue.jsonl', 'auth.json', 'credentials.json'}
    if any(file.name in private_names or file.suffix in {'.sqlite', '.sqlite-wal', '.sqlite-shm'} for file in publish.rglob('*')):
        raise RuntimeError('安装内容混入本地用户数据')
    for file in publish.rglob('*'):
        if not file.is_file(): continue
        raw = file.read_bytes()
        if re.search(rb'(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{32,}', raw) or re.search(rb's\x00k\x00-\x00(?:[A-Za-z0-9_-]\x00){32,}', raw):
            raise RuntimeError('发布内容疑似包含 API Key，已阻止打包')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output_dir.resolve() / f'TokenTracker-Lite-Setup-{VERSION}-win-x64.exe'
    subprocess.run([shutil.which('makensis') or 'makensis', '-V2', f'-DAPP_VERSION={VERSION}',
                    f'-DPUBLISH_DIR={publish}', f'-DOUTPUT_FILE={output}', str(HERE / 'installer.nsi')], check=True)
    print(f'Windows x64 安装包构建完成：{output}', flush=True)
    print(f'大小：{output.stat().st_size / 1048576:.1f} MB；SHA256：{hashlib.sha256(output.read_bytes()).hexdigest()}', flush=True)

if __name__ == '__main__': main()
