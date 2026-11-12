# ordered-map

A small C++17 library and command-line tool implementing an ordered map from
64-bit signed integer keys to short strings, backed by a hand-written AVL tree
augmented with subtree sizes. Besides insert / delete / lookup it supports
order statistics (`rank`, `select`), neighbour queries (`floor`, `ceil`,
`succ`, `pred`) and inclusive range listing. Only the C++ standard library is
used for the implementation.

| operation                                   | cost            |
|---------------------------------------------|-----------------|
| insert, erase, find, floor/ceil/succ/pred, rank, select, min, max | O(log n) |
| size                                        | O(1)            |
| range (r keys visited)                      | O(log n + r)    |

## Layout

```
include/ordered_map/ordered_map.hpp        public API: OrderedMap
include/ordered_map/command_processor.hpp  text-protocol layer
src/                                       implementations
cli/main.cpp                               thin stdin/stdout tool
tests/                                     GoogleTest unit tests
build.sh, run.sh                           build / run helper scripts
```

## Build

Requires CMake >= 3.20, a C++17 compiler and (for tests) GoogleTest.

```
./build.sh                       # Release build into ./build
# or manually:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
ctest --test-dir build --output-on-failure    # run the unit tests
```

Pass `-DORDERED_MAP_BUILD_TESTS=OFF` to skip the tests (and the GoogleTest
dependency).

## Command-line tool

`./run.sh` (the binary is `build/ordered-map`) reads a script from stdin: a
first line with the command count `Q`, then `Q` command lines, and prints one
output line per command.

| command                | output |
|------------------------|--------|
| `insert <key> <value>` | `ok` if new, `updated` if the key existed (value replaced) |
| `delete <key>`         | `ok` if removed, else `missing` |
| `get <key>`            | the value, or `missing` |
| `size`                 | number of keys |
| `min` / `max`          | smallest / largest key, or `empty` |
| `floor <key>` / `ceil <key>` | largest key <= / smallest key >= `key`, or `missing` |
| `succ <key>` / `pred <key>`  | smallest key > / largest key < `key`, or `missing` |
| `rank <key>`           | number of keys strictly less than `key` |
| `select <k>`           | k-th smallest key (0-based), or `missing` |
| `range <lo> <hi>`      | keys in [lo, hi] ascending, space separated, or `empty` |

Values are 1-32 printable ASCII characters without spaces and are opaque.
The exit status is 0 on success, 1 if the input is malformed (output produced
before the error is still written).

```
$ printf '5\ninsert 5 five\ninsert 2 two\nget 5\nrange 0 9\nrank 5\n' | ./run.sh
ok
ok
five
2 5
1
```

## Library example

```cpp
#include <iostream>
#include "ordered_map/ordered_map.hpp"

int main() {
    ordered_map::OrderedMap m;
    m.insert(10, "ten");
    m.insert(20, "twenty");
    m.insert(30, "thirty");

    if (auto k = m.floor(25)) std::cout << *k << '\n';      // 20
    std::cout << m.rank(30) << '\n';                        // 2
    std::cout << *m.select(0) << '\n';                      // 10
    m.for_each_in_range(10, 20, [](std::int64_t k, const std::string& v) {
        std::cout << k << "=" << v << '\n';                 // 10=ten, 20=twenty
    });
    m.erase(20);
}
```

Link against the `ordered_map::ordered_map` CMake target (e.g. via
`add_subdirectory`). `ordered_map/command_processor.hpp` additionally exposes
`execute_command` and `run_script`, the text protocol used by the CLI.

## Design notes

Nodes live in a `std::vector` arena addressed by 32-bit indices (index 0 is a
shared null node of height 0 and size 0, which simplifies the balancing and
size arithmetic); freed nodes are recycled. Keys are never incremented or
decremented, so `succ INT64_MAX` and friends cannot overflow. `range` is an
iterative in-order walk pruned to `[lo, hi]`.
