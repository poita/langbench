#!/usr/bin/env bash
# Build the langvm command-line tool.  Works from any directory.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
cabal build -v0 exe:langvm
mkdir -p "$here/bin"
cp "$(cabal list-bin -v0 exe:langvm)" "$here/bin/langvm"
