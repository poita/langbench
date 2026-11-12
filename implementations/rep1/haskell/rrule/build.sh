#!/bin/sh
# Build the rrule command-line tool and place it at bin/rrule.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
cabal build -v0 exe:rrule
mkdir -p bin
cp "$(cabal list-bin -v0 exe:rrule)" bin/rrule
