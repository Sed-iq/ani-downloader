"""Freeze kotodl with PyInstaller into build/pyi-dist/ (kotodl/ folder, or kotodl.app on macOS).

Shared by build-deb.sh and the CI workflow:  python packaging/freeze.py
Needs the requirements plus pyinstaller (and Pillow on Windows/macOS for the icon).
"""
import sys
from pathlib import Path

import PyInstaller.__main__

ROOT = Path(__file__).resolve().parent.parent
HERE = ROOT / "packaging"
BUILD = ROOT / "build"

args = [
    str(HERE / "entry.py"),
    "--noconfirm", "--clean", "--windowed",
    "--name", "kotodl",
    "--paths", str(ROOT),
    "--distpath", str(BUILD / "pyi-dist"),
    "--workpath", str(BUILD / "pyi-work"),
    "--specpath", str(BUILD),
    "--collect-data", "langcodes",
    "--collect-all", "curl_cffi",
]
if sys.platform in ("win32", "darwin"):
    args += ["--icon", str(HERE / "kotodl.png")]     # PyInstaller converts it to .ico/.icns via Pillow
if sys.platform == "darwin":
    args += ["--osx-bundle-identifier", "io.github.sediq.kotodl"]

PyInstaller.__main__.run(args)
