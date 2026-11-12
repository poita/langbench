#!/bin/sh
# Build the qrcode library and command-line tool.
set -e
cd "$(dirname "$0")"
cabal build -v1 exe:qrcode
