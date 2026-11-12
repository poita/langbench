#!/usr/bin/env bash
# Usage: run.sh <input directory> <output directory>
# Font and hyphenation data are read from ./data relative to the current
# directory (override with TYPESET_DATA).
exec "$(cd "$(dirname "$0")" && pwd)/build/typeset" "$@"
