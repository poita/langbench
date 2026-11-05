# ordered-map — Balanced ordered map

Implement an ordered map from 64-bit signed integer keys to short string
values, supporting insertion, deletion, lookup, order statistics (rank and
select), neighbour queries (floor, ceil, successor, predecessor) and inclusive
range listing. Process a sequence of commands read from stdin and print one
line of output per command.

The workloads include 200 000-command sequences with adversarial patterns
(keys inserted in sorted order, deleted in descending order, rank/select-heavy
mixes). A structure whose per-operation cost is O(log n) — a balanced BST
(AVL, red-black, treap, ...) or a skip list, augmented with subtree sizes for
rank/select — is expected. A plain unbalanced BST degenerates to O(n) per
operation on the sorted-insertion tests and will time out.

Write the balanced tree yourself: don't use an ordered map, sorted set or
balanced tree from a library, the standard library or the language.

## Input

Standard input is UTF-8 (in fact pure ASCII) text.

- Line 1: an integer `Q` (0 ≤ Q ≤ 200000), the number of commands.
- Lines 2 .. Q+1: one command per line. Nothing follows line Q+1.

Tokens on a command line are separated by exactly one ASCII space. There are no
leading or trailing spaces and no blank lines. Lines are terminated by `\n`;
the final line may or may not end with a newline. Every line is well formed;
malformed input never occurs.

`<key>`, `<lo>`, `<hi>` are 64-bit signed integers written in decimal: an
optional leading `-` followed by one or more digits, no leading zeros (except
the number `0` itself), no `+` sign. The range is
−9223372036854775808 ≤ key ≤ 9223372036854775807 inclusive; **both extremes do
occur in tests**, so neighbour queries must not overflow (e.g. `succ
9223372036854775807` must not compute key+1).

`<value>` is a non-empty string of 1 to 32 printable ASCII characters in the
range `!` (0x21) to `~` (0x7E) — i.e. never a space and never a control
character. Every character in that range occurs in tests, including `"`, `'`,
`` ` ``, `\`, `<`, `>`, `|`, `{`, `}` and `#`. Values are opaque: they are
stored and printed back verbatim and never interpreted, escaped or quoted. A
value may equal a word that also appears as an output keyword (such as
`missing`, `ok`, `empty`, `updated`); that has no special meaning.

`<k>` in `select` is a non-negative decimal integer, 0 ≤ k ≤ 1000000000.

## Commands and their output

Exactly one output line per command, in command order, each terminated by
`\n`, with no leading or trailing spaces. When `Q` is 0 the output is empty
(zero bytes). Output is ASCII. When a key is printed, it is printed in
canonical decimal (optional leading `-`, no leading zeros, `0` for zero).

| command                   | output                                                                 |
|---------------------------|------------------------------------------------------------------------|
| `insert <key> <value>`    | `ok` if `key` was not present (it is now, with `value`); `updated` if it was present (its value is replaced by `value`). |
| `delete <key>`            | `ok` if `key` was present (it is removed); `missing` otherwise.        |
| `get <key>`               | the value stored under `key`, or `missing`.                            |
| `size`                    | the number of keys currently in the map (0 or more).                   |
| `min`                     | the smallest key, or `empty` if the map is empty.                      |
| `max`                     | the largest key, or `empty` if the map is empty.                       |
| `floor <key>`             | the largest key ≤ `key`, or `missing` if there is none.                |
| `ceil <key>`              | the smallest key ≥ `key`, or `missing` if there is none.               |
| `succ <key>`              | the smallest key > `key` (strictly), or `missing` if there is none.    |
| `pred <key>`              | the largest key < `key` (strictly), or `missing` if there is none.     |
| `rank <key>`              | the number of keys strictly less than `key` (0 or more; `key` need not be present). |
| `select <k>`              | the k-th smallest key, 0-based (`select 0` is the minimum), or `missing` if k ≥ size. |
| `range <lo> <hi>`         | all keys `x` with lo ≤ x ≤ hi in ascending order, separated by single spaces on one line, or `empty` if there are none. `lo > hi` may occur and yields `empty`. |

Notes:

- `floor`, `ceil`, `succ`, `pred`, `rank`, `range` are pure queries: the
  argument key need not be present, and the map is not modified.
- `floor k` / `ceil k` return `k` itself when `k` is present; `succ` / `pred`
  never return `k` itself.
- `rank` on an empty map is `0`; `select` on an empty map is `missing`;
  `range` on an empty map is `empty`.
- The empty-map answer for `min`/`max` is the word `empty`; the not-found
  answer for everything else is the word `missing`. Do not confuse the two.

## Worked examples

### Example 1

Input:

    12
    size
    min
    insert 5 five
    insert 5 FIVE
    get 5
    insert 2 two
    insert 9 nine
    min
    max
    range 2 9
    delete 5
    range 3 8

Output:

    0
    empty
    ok
    updated
    FIVE
    ok
    ok
    2
    9
    2 5 9
    ok
    empty

### Example 2

Input:

    14
    insert 10 a
    insert 20 b
    insert 30 c
    floor 25
    ceil 25
    floor 10
    ceil 10
    succ 10
    pred 10
    succ 30
    rank 20
    rank 21
    select 2
    select 3

Output:

    ok
    ok
    ok
    20
    30
    10
    10
    20
    missing
    missing
    1
    2
    30
    missing

### Example 3 (extreme keys)

Input:

    9
    insert -9223372036854775808 lo
    insert 9223372036854775807 hi
    insert 0 zero
    succ 9223372036854775807
    pred -9223372036854775808
    floor -9223372036854775807
    ceil 1
    range -9223372036854775808 9223372036854775807
    delete 0

Output:

    ok
    ok
    ok
    missing
    missing
    -9223372036854775808
    9223372036854775807
    -9223372036854775808 0 9223372036854775807
    ok

## Performance expectations

- Up to Q = 200 000 commands per test; the map holds up to 200 000 keys at
  once.
- A single `range` may cover the whole map, so one output line can hold up to
  200 000 keys (a few megabytes); do not assume a bounded line length. The
  total number of keys printed by all `range` commands in one test is at most
  2 000 000, so an O(log n + output) range walk is sufficient.
- Largest input files are about 5 MB and the largest expected outputs about
  4 MB. Read stdin in bulk (or with buffered reads) and buffer stdout;
  per-line unbuffered I/O is likely to dominate the run time.
- A correct O(log n) implementation in a compiled language finishes every test
  in well under 1 second. Suggested timeout: 10 seconds per test.
