"""PyInstaller entry point (kotodl/__main__.py uses a relative import, so it can't be frozen directly)."""
import sys

from kotodl.ui import main

sys.exit(main())
