# ordered-map

An ordered map from 64-bit signed integer keys to short string values, written
in D. It is a size-augmented AVL tree stored in a flat index-addressed node
pool, so insert, delete, lookup, `floor`/`ceil`/`succ`/`pred`, `rank` and
`select` are all O(log n) and an inclusive `range` listing is O(log n + r).
Everything is built from scratch on the D standard library; no library
tree/map/set is used.

The repository has two parts:

- a **library** (`source/orderedmap/`) with the data structure, a fast byte
  buffer, integer parsing/formatting and a command interpreter;
- a thin **CLI** (`app/main.d`) that reads a command script on stdin and writes
  one answer line per command to stdout.

## Layout

| path                          | purpose                                                   |
|-------------------------------|-----------------------------------------------------------|
| `source/orderedmap/tree.d`    | `OrderedMap`: the AVL tree and all queries                |
| `source/orderedmap/outbuf.d`  | `OutBuffer`: append-only buffer with an inlined fast path |
| `source/orderedmap/parse.d`   | `parseLong`, `parseULong`, `formatLong` (no allocation)   |
| `source/orderedmap/commands.d`| `runScript`: the command-language interpreter             |
| `source/orderedmap/package.d` | `import orderedmap;` re-exports everything                |
| `app/main.d`                  | the command-line tool                                     |
| `tests/`                      | unit tests (separate from the library sources)            |

## Building

Requires LDC and dub.

```sh
./build.sh                      # = dub build -b release --compiler=ldc2 --config=cli
dub test --compiler=ldc2        # unit tests
```

`build.sh` produces the `ordered-map` executable in the project root; `run.sh`
runs it from any directory.

## Command-line usage

```sh
./run.sh < commands.txt
```

Input: the first line is `Q`, followed by `Q` command lines (tokens separated
by single spaces). Output: exactly one line per command.

| command                | output                                                             |
|------------------------|--------------------------------------------------------------------|
| `insert <key> <value>` | `ok` if new, `updated` if the key existed (value replaced)         |
| `delete <key>`         | `ok` if removed, else `missing`                                    |
| `get <key>`            | the value, or `missing`                                            |
| `size`                 | number of keys                                                     |
| `min` / `max`          | smallest / largest key, or `empty`                                 |
| `floor` / `ceil <key>` | largest key ≤ / smallest key ≥ `key`, or `missing`                 |
| `pred` / `succ <key>`  | largest key < / smallest key > `key`, or `missing`                 |
| `rank <key>`           | number of keys strictly less than `key`                            |
| `select <k>`           | the k-th smallest key (0-based), or `missing`                      |
| `range <lo> <hi>`      | keys in `[lo, hi]` ascending, space separated, or `empty`          |

Example:

```console
$ printf '5\ninsert 5 five\ninsert 2 two\ninsert 9 nine\nrange 2 9\nrank 9\n' | ./run.sh
ok
ok
ok
2 5 9
2
```

Keys cover the full signed 64-bit range; neighbour queries compare rather than
computing `key ± 1`, so `succ 9223372036854775807` is simply `missing`.

## Library example

```d
import orderedmap;

void main()
{
    OrderedMap m;
    m.insert(20, "b");
    m.insert(10, "a");
    m.insert(30, "c");

    long k;
    assert(m.floor(25, k) && k == 20);
    assert(m.succ(30, k) is false);          // no overflow, no key
    assert(m.rank(21) == 2);                 // keys strictly below 21
    assert(m.select(2, k) && k == 30);
    assert(m.keysInRange(10, 20) == [10L, 20]);

    const(char)[] v;
    assert(m.get(10, v) && v == "a");
    m.remove(20);
}
```

Values are stored as slices, not copied: the memory they refer to must outlive
the map. `OrderedMap.range` takes any sink with a `put(long)` method, which
lets callers stream keys without collecting them.

## Notes

- Deleted node slots are recycled through a free list; `OrderedMap(capacity)`
  or `reserve` avoids pool reallocation.
- The CLI reads stdin in bulk, parses with a byte cursor and writes all output
  in a single call. A trailing `\r` on lines and a missing final newline are
  tolerated.
