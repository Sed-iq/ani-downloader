"""Start the frozen app headless; fail if it exits early (missing module, library or plugin).

    python packaging/smoke.py build/pyi-dist/kotodl/kotodl
"""
import os
import subprocess
import sys

WAIT = 15

proc = subprocess.Popen([sys.argv[1]], env=dict(os.environ, QT_QPA_PLATFORM="offscreen"))
try:
    code = proc.wait(timeout=WAIT)
except subprocess.TimeoutExpired:
    proc.kill()
    print(f"ok: still running after {WAIT}s")
else:
    sys.exit(f"app exited early with code {code}")
