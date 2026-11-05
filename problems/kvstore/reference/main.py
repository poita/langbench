#!/usr/bin/env python3
"""Tessera: the reference implementation of problems/kvstore/SPEC.md.

Usage: main.py <input directory> <output directory>
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.setrecursionlimit(100000)

from texec import run_directory


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: main.py <input dir> <output dir>\n")
        return 2
    run_directory(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
