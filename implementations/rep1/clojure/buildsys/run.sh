#!/usr/bin/env bash
# Run the Kiln CLI: run.sh <input directory> <output directory>
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec java -cp "$(cat "$ROOT/target/classpath")" buildsys.main "$@"
