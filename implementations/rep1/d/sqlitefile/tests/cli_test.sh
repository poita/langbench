#!/bin/sh
# End-to-end test of the command-line tool: runs it on the fixtures in
# tests/data and compares with the expected output (mini) and, when the
# sqlite3 shell is available, with sqlite3 itself (big).
# Usage: tests/cli_test.sh   (after `dub build`)
set -e
here=$(cd "$(dirname "$0")" && pwd)
exe="$here/../sqlitefile"
work=$(mktemp -d "${TMPDIR:-/tmp}/sqlitefile-cli.XXXXXX")
trap 'rm -rf "$work"' EXIT

# 1. SPEC worked example
mkdir "$work/in1" "$work/out1"
cp "$here/data/mini.sqlite" "$here/data/mini.queries.txt" "$work/in1/"
mv "$work/in1/mini.queries.txt" "$work/in1/queries.txt"
"$exe" "$work/in1" "$work/out1"
diff -r "$work/out1" "$here/data/mini.expected"

# 2. compare with the sqlite3 shell on the multi-level / overflow fixture
if command -v sqlite3 >/dev/null 2>&1; then
    mkdir "$work/in2" "$work/out2"
    cp "$here/data/big.sqlite" "$work/in2/"
    printf '%s\n' 'SELECT * FROM t' 'SELECT id,label FROM t WHERE grp >= 5 ORDER BY label DESC LIMIT 40' \
        'SELECT id,score FROM t WHERE score > 100.5 AND grp != 2 ORDER BY score' \
        > "$work/in2/queries.txt"
    "$exe" "$work/in2" "$work/out2"
    db="$here/data/big.sqlite"
    sqlite3 -nullvalue NULL "$db" \
        "SELECT id,grp,label,hex(payload),score FROM t ORDER BY id" \
        | tr '|' '\t' > "$work/want1.txt"
    diff "$work/want1.txt" "$work/out2/001.txt"
    sqlite3 -nullvalue NULL "$db" \
        "SELECT id,label FROM t WHERE grp >= 5 ORDER BY label DESC, id LIMIT 40" \
        | tr '|' '\t' > "$work/want2.txt"
    diff "$work/want2.txt" "$work/out2/002.txt"
    sqlite3 -nullvalue NULL "$db" \
        "SELECT id,score FROM t WHERE score > 100.5 AND grp != 2 ORDER BY score, id" \
        | tr '|' '\t' > "$work/want3.txt"
    diff "$work/want3.txt" "$work/out2/003.txt"
fi
echo "cli tests passed"
