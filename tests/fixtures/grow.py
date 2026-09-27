#!/usr/bin/env python3
"""Test-only producer whose child keeps writing until the process group stops."""
from pathlib import Path
import subprocess
import sys
import time


if sys.argv[1] == "child":
    target = Path(sys.argv[2])
    heartbeat = Path(sys.argv[3])
    with (target / "growing.bin").open("wb") as output:
        counter = 0
        while True:
            output.write(b"x" * 4096)
            output.flush()
            counter += 1
            heartbeat.write_text(str(counter), encoding="ascii")
            time.sleep(0.01)
else:
    subprocess.run([sys.executable, __file__, "child", sys.argv[3], sys.argv[2]], check=True)
