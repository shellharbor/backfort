#!/usr/bin/env python3
"""Run Backfort directly from this checkout, independently of the working directory."""

import sys
from pathlib import Path


def main() -> int:
    """Load the checkout's launcher rather than an unrelated installed package."""
    sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
    from backfort.cli import main as launch

    return launch()


if __name__ == "__main__":
    raise SystemExit(main())
