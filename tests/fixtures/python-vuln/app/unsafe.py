"""Deliberately unsafe, so the bandit step can be shown to fail.

`shell=True` with a caller-supplied string is B602 at high severity. Nothing
imports this module; it exists to be scanned.
"""

from __future__ import annotations

import subprocess


def run(command: str) -> int:
    return subprocess.call(command, shell=True)
