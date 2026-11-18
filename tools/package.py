#!/usr/bin/env python3
"""Checks and packages AuctionSuite locally (no network).

    python tools/package.py              check, then write dist/AuctionSuite-<version>.zip
    python tools/package.py --check-only check only (what the GitHub workflow runs first)

Checks: every addon folder's .toc has the same ## Version, no file starts with a UTF-8 BOM,
every file a .toc lists exists, and every .lua file compiles with `luajit -b` (LuaJIT from
$LUAJIT, PATH, or the usual Windows install). The zip holds only the addon folders, with
forward-slash paths, so it unzips straight into Interface/AddOns.
"""
import os
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONS = ["AuctionSuite", "AuctionSuite_SuffixFinder", "AuctionSuite_Disenchant", "AuctionSuite_VendorDeals"]
WINDOWS_LUAJIT = os.path.expandvars(r"%LOCALAPPDATA%\Programs\LuaJIT\bin\luajit.exe")


def fail(msg):
    print("error: " + msg)
    sys.exit(1)


def find_luajit():
    for candidate in (os.environ.get("LUAJIT"), shutil.which("luajit"), WINDOWS_LUAJIT):
        if candidate and os.path.isfile(candidate):
            return candidate
    return None


def addon_files(folder):
    for base, dirs, files in os.walk(os.path.join(ROOT, folder)):
        dirs.sort()
        for name in sorted(files):
            yield os.path.join(base, name)


def check():
    versions = {}
    for addon in ADDONS:
        toc = os.path.join(ROOT, addon, addon + ".toc")
        if not os.path.isfile(toc):
            fail(f"missing {addon}/{addon}.toc")
        text = open(toc, "rb").read()
        if text.startswith(b"\xef\xbb\xbf"):
            fail(f"{addon}.toc starts with a BOM")
        text = text.decode("utf-8")
        m = re.search(r"^## Version:\s*(\S+)", text, re.M)
        if not m:
            fail(f"{addon}.toc has no ## Version")
        versions[addon] = m.group(1)
        for line in text.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                if not os.path.isfile(os.path.join(ROOT, addon, line.replace("\\", "/"))):
                    fail(f"{addon}.toc lists {line}, which does not exist")
    if len(set(versions.values())) != 1:
        fail("TOC versions differ: " + ", ".join(f"{a} {v}" for a, v in versions.items()))

    luajit = find_luajit()
    if not luajit:
        fail("LuaJIT not found (set LUAJIT or put luajit on PATH)")
    count = 0
    for addon in ADDONS:
        for path in addon_files(addon):
            if open(path, "rb").read(3) == b"\xef\xbb\xbf":
                fail(f"{os.path.relpath(path, ROOT)} starts with a BOM")
            if path.endswith(".lua"):
                r = subprocess.run([luajit, "-b", path, os.devnull], capture_output=True, text=True)
                if r.returncode != 0:
                    fail(f"luajit: {r.stderr.strip() or r.stdout.strip()}")
                count += 1
    version = next(iter(versions.values()))
    print(f"ok: version {version}, {count} Lua files compile, {len(ADDONS)} TOCs agree, no BOMs")
    return version


def package(version):
    dist = os.path.join(ROOT, "dist")
    os.makedirs(dist, exist_ok=True)
    out = os.path.join(dist, f"AuctionSuite-{version}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for addon in ADDONS:
            for path in addon_files(addon):
                z.write(path, os.path.relpath(path, ROOT).replace(os.sep, "/"))
    with zipfile.ZipFile(out) as z:
        n = len(z.namelist())
    print(f"wrote {os.path.relpath(out, ROOT)} ({n} files, {os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    v = check()
    if "--check-only" not in sys.argv:
        package(v)
