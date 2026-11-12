# ordered-map

A balanced ordered map from 64-bit signed integer keys to short string values,
written from scratch in pure Python (standard library only). It is an AVL tree
augmented with subtree sizes, so insert, delete, lookup, neighbour queries
(`floor`, `ceil`, `succ`, `pred`) and order statistics (`rank`, `select`) are all
O(log n), and an inclusive `range` listing is O(log n + r).

The project has two layers:

- `ordered_map` – the library (`node.py`: AVL node and rotations;
  `ordered_map.py`: the `OrderedMap` class; `commands.py`: command
  interpreter; `cli.py`: stdin/stdout driver).
- a thin command-line tool, `python3 -m ordered_map`.

## Build

There is nothing to compile. `./build.sh` byte-compiles the sources as a check.
Requires Python 3.14. To run tests: `pip install pytest` and `python3 -m pytest`
from this directory (`pyproject.toml` puts `src` on the path).

## CLI

`./run.sh` reads commands on stdin and writes one line per command to stdout.
The first line is the command count `Q`, followed by `Q` commands:

| command                | output |
|------------------------|--------|
| `insert <key> <value>` | `ok` (new key) or `updated` |
| `delete <key>`         | `ok` or `missing` |
| `get <key>`            | the value, or `missing` |
| `size`                 | number of keys |
| `min` / `max`          | smallest / largest key, or `empty` |
| `floor` / `ceil <key>` | largest key ≤ / smallest key ≥ `key`, or `missing` |
| `succ` / `pred <key>`  | smallest key > / largest key < `key`, or `missing` |
| `rank <key>`           | number of keys strictly less than `key` |
| `select <k>`           | k-th smallest key (0-based), or `missing` |
| `range <lo> <hi>`      | keys in `[lo, hi]` ascending, space separated, or `empty` |

```
$ printf '4\ninsert 5 five\ninsert 2 two\nrange 1 9\nrank 5\n' | ./run.sh
ok
ok
2 5
1
```

Values are 1–32 printable ASCII characters without spaces and are stored
verbatim. See `problems/ordered-map/SPEC.md` for the full format.

## Library example

```python
from ordered_map import OrderedMap

m = OrderedMap()
m.insert(10, "a")            # True  (new key)
m.insert(10, "A")            # False (value replaced)
m.insert(20, "b")
m.insert(30, "c")

m.get(10)                    # 'A'
m.floor(25), m.ceil(25)      # (20, 30)
m.successor(30)              # None
m.rank(21)                   # 2
m.select(2)                  # 30
list(m.range(10, 20))        # [10, 20]
m.delete(20)                 # True
len(m)                       # 2
```

Missing results are reported as `None`. `OrderedMap` also supports
`m[key]`, `m[key] = value`, `del m[key]`, `key in m`, `len(m)`, iteration over
keys in order, and `items()`.
