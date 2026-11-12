#!/bin/sh
# Build the webhooks CLI and copy the executable to bin/webhooks.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
cd "$dir"
cabal build exe:webhooks
mkdir -p bin
cp "$(cabal list-bin exe:webhooks)" bin/webhooks
