#!/bin/sh
# Build the inflate library and CLI. Works from any current directory.
set -e
cd "$(dirname "$0")"
cabal build exe:inflate -v0
