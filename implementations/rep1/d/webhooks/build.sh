#!/bin/sh
# Build the webhooks command-line tool (bin/webhooks) with dub + LDC.
set -e
cd "$(dirname "$0")"
dub build -b release --compiler=ldc2 --quiet
