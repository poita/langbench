#!/bin/sh
# Build the regex command-line tool (bin/regex-cli) with dub + LDC.
set -e
cd "$(dirname "$0")"
exec dub build -b release --compiler=ldc2 --config=cli --quiet
