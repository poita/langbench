#!/bin/sh
# Build the spreadsheet CLI and place the binary in bin/spreadsheet.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
cabal build exe:spreadsheet
mkdir -p bin
cp "$(cabal list-bin exe:spreadsheet)" bin/spreadsheet
