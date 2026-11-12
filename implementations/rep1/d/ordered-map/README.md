# ordered-map

A balanced ordered map from 64-bit integer keys to string values, written in D
with no dependencies beyond Phobos. The map is an **AVL tree augmented with
subtree sizes**, so every operation is O(log n):

- insert / update, delete, lookup
- order statistics: `rank` (keys strictly below a key) and `select` (k-th smallest)
- neighbour queries: `floor`, `ceil`, successor, predecessor (overflow-safe at
  `long.min` / `long.max`)
- inclusive range listing in O(log n + r)

The project has two parts: a reusable library (`source/orderedmap/`) and a thin
command-line tool (`cli/app.d`) that reads a command script on stdin.

## Layout

| Path | Purpose |
|------|---------|
| `source/orderedmap/tree.d` | `OrderedMap!(K, V)`, the AVL tree (index-based node arena with a free list) |
| `source/orderedmap/commands.d` | `Interpreter`: parses the text protocol and writes replies |
| `source/orderedmap/numbers.d` | allocation-free `long` parsing and formatting |
| `source/orderedmap/package.d` | `import orderedmap;` re-exports everything |
| `cli/app.d` | the command-line tool |

## Building

Requires LDC and dub.

```sh
dub build -b release --compiler=ldc2     # produces bin/ordered-map
./build.sh                                # same, from any directory
```

## Testing

```sh
dub test --compiler=ldc2
```

Tests are D `unittest` blocks next to the code: the AVL invariants are checked
after sorted insertion / descending deletion, a randomised run is compared with
a sorted-array model, and the protocol is checked against the worked examples
and edge cases (extreme keys, CRLF, opaque values, malformed input).

## Command-line usage

```sh
./run.sh < commands.txt
```

Input: a first line `Q`, then `Q` command lines (single-space separated). One
reply line per command is written to stdout. Keys are 64-bit signed decimal
integers; values are 1–32 printable ASCII characters without spaces.

| command | reply |
|---------|-------|
| `insert <key> <value>` | `ok` (new key) or `updated` |
| `delete <key>` | `ok` or `missing` |
| `get <key>` | the value, or `missing` |
| `size` | number of keys |
| `min` / `max` | the smallest / largest key, or `empty` |
| `floor <key>` / `ceil <key>` | largest key ≤ / smallest key ≥ `key`, or `missing` |
| `succ <key>` / `pred <key>` | smallest key > / largest key < `key`, or `missing` |
| `rank <key>` | number of keys strictly less than `key` |
| `select <k>` | the k-th smallest key (0-based), or `missing` |
| `range <lo> <hi>` | keys in `[lo, hi]` ascending, space-separated, or `empty` |

```console
$ printf '5\ninsert 5 five\ninsert 2 two\ninsert 9 nine\nrange 2 9\nrank 9\n' | ./run.sh
ok
ok
ok
2 5 9
2
```

On malformed input the tool prints a message to stderr, delivers the replies
produced so far and exits with status 1.

## Library example

Add the package as a dub dependency (using the `library` configuration), then:

```d
import orderedmap;
import std.stdio;

void main()
{
    OrderedMap!(long, string) m;
    m.insert(10, "ten");
    m.insert(20, "twenty");
    m.insert(30, "thirty");

    writeln(m.floor(25).get);        // 20
    writeln(m.successor(30).isNull); // true
    writeln(m.rank(21));             // 2
    writeln(m.select(0).get);        // 10

    m.forEachInRange(15, 35, (long k, string v) { writeln(k, " => ", v); });
    // 20 => twenty
    // 30 => thirty
}
```

`OrderedMap` is generic over any key type supporting `<`. It is a non-copyable
struct (use `dup` for a copy). `validate()` checks the BST, balance and size
invariants and is handy in tests.
