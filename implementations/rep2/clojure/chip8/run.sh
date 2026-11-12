#!/usr/bin/env bash
# Run the CLI: reads a CHIP-8 job on stdin, writes the final state to stdout.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
exec java -XX:+UseSerialGC \
  -cp "$root/target/classes:$(cat "$root/target/classpath")" chip8.main "$@"
