#!/usr/bin/env python3
"""Test-only recovery unit producer."""
import os
from pathlib import Path
import sys

target = Path(sys.argv[1])
if os.environ.get("RELIABILITY_FIXTURE_FAIL") == "1" or "fail" in sys.argv:
    (target / "partial.txt").write_text("partial", encoding="utf-8")
    raise SystemExit(1)
(target / "payload.txt").write_text("captured content", encoding="utf-8")
