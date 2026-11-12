#!/bin/sh
# Builds the Kiln command-line tool (bin/kiln) with dub and LDC.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2
