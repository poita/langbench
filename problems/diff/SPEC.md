# diff — Myers diff and patch

Two related tasks on line-oriented text files, selected by the first input
line:

- **`diff`**: given files A and B, print a *shortest* edit script that turns
  A into B, where an edit script is a sequence of "keep this line of A",
  "delete this line of A" and "insert this line" operations and its cost is
  the number of deletions plus insertions. The minimum cost equals
  `N + M - 2 * LCS(A, B)`, so this is the longest-common-subsequence problem
  on lines. The intended solution is Myers' O((N+M)·D) greedy algorithm
  (E. Myers, "An O(ND) Difference Algorithm and Its Variations", 1986),
  optionally with common-prefix/suffix trimming and line interning.
- **`patch`**: given file A and an edit script in the same format, print the
  resulting file B.

Write the diff yourself: don't use a diff, sequence-matching or edit-distance
routine from a library, the standard library or the language.

## Input

Standard input is UTF-8 text. Every line, including the last, is terminated
by a single `\n` (never `\r\n`). Lines of file content are taken verbatim
between newlines: they may be empty, may begin or end with spaces or tabs,
may contain tabs and non-ASCII characters, and **all of that is significant**
(two lines are equal only if they are byte-for-byte identical). A content
line never contains `\r` or `\n`.

Line 1 is the mode, exactly `diff` or `patch`.

Mode `diff`:

```
diff
N
<line 1 of A>
...
<line N of A>
M
<line 1 of B>
...
<line M of B>
```

`N` and `M` are non-negative decimal integers (`0 <= N, M <= 150000`) written
in ASCII digits with no sign, no leading zeros and nothing else on the line.
When a count is `0` no content lines follow it. Nothing follows the last line
of B (the input ends with its `\n`).

Mode `patch`:

```
patch
N
<line 1 of A>
...
<line N of A>
K
<script line 1>
...
<script line K>
```

`N` and `K` are non-negative decimal integers (`0 <= N <= 5000`,
`0 <= K <= 10000`), written like the counts of mode `diff`. Nothing follows
the last script line. Each script line has the form described under "Edit
script format" and the script is guaranteed to be valid for A (its `' '` and
`'-'` lines, in order, are exactly the lines of A). The script is **not**
necessarily minimal: it may delete a line and re-insert an identical one, or
insert and delete freely.

Content lines are at most 200 Unicode code points (at most 800 bytes of
UTF-8) long. Total input is under 10 MB. Always read content by the declared
counts, never by looking at the text: a content line may itself look like a
count (`5`), be a single tag character (`-`, `+`, or one space), or start
with one (`+1`, `-x`); in a script that makes lines such as `+-x` (insert
the text `-x`) and `  ` (two spaces: keep a line consisting of one space).

## Edit script format

An edit script is a count line followed by that many script lines. Each
script line is one character of tag followed immediately by a line of
content (the content may be empty, so the script line `+` alone inserts an
empty line and ` ` (one space) alone keeps an empty line):

| tag   | meaning                                            |
|-------|----------------------------------------------------|
| ` `   | keep: the next unconsumed line of A, also in B     |
| `-`   | delete: the next unconsumed line of A, not in B    |
| `+`   | insert: this line appears in B at this position    |

A script is **valid for A and B** when reading its ` ` and `-` lines top to
bottom yields exactly A (all N lines, in order, with their text), and reading
its ` ` and `+` lines top to bottom yields exactly B. Its **cost** is the
number of `-` lines plus `+` lines. A script is **minimal** when its cost is
the smallest possible for that A and B. Where a deletion and an insertion are
adjacent, either order is allowed.

## Output

Mode `diff`: print `K` (the number of script lines) on the first line, then
the `K` script lines, each terminated by `\n`. Every count you print (`K`
here, `M` in mode `patch`) is ASCII digits only, with no sign, no leading
zeros (`0` for zero) and no other characters on the line. The script must be
valid for A and B and minimal. Any minimal valid script is accepted; there is
no canonical choice among equally short scripts. For identical files the
output is `N` followed by N keep lines.

Mode `patch`: print `M` (the number of lines of B) on the first line, then
the `M` lines of B, each terminated by `\n`, byte-for-byte as they appear in
A or in the script (trailing spaces included). For an empty B print just
`0`.

Nothing else may be written to stdout. Exit with status 0. Leniencies, all
optional: after the declared lines, extra *empty* lines (nothing between the
newlines; a line of spaces is not empty and is rejected) are ignored, a
missing final `\n` is accepted, `\r\n` line endings are accepted, and
trailing spaces or tabs on the count line are ignored. Content lines are
never trimmed: a keep, insert or patch-output line must carry its text
byte-for-byte, trailing whitespace included.

## Examples

### Example 1 — `diff`, the example from Myers' paper

Input (`abcabba` → `cbabac`):

```
diff
7
a
b
c
a
b
b
a
6
c
b
a
b
a
c
```

One valid output (cost 5, which is the minimum):

```
9
-a
-b
 c
+b
 a
 b
-b
 a
+c
```

Other cost-5 scripts are accepted too, for example
`-a -b  c +b  a -b  b  a +c` (keeps the other `b`) or
`-a -b  c -a  b +a  b  a +c` (keeps `c b b a` instead of `c a b a`). A
script such as deleting all seven lines and inserting all six (cost 13) is
valid but not minimal, so it is rejected.

### Example 2 — `diff` with duplicate lines

Input:

```
diff
6
x
x
x
y
x
x
6
x
y
x
x
x
y
```

One valid output (cost 4):

```
8
 x
-x
-x
 y
 x
 x
+x
+y
```

### Example 3 — `patch`

Input:

```
patch
5
a
b
c
d
e
8
 a
-b
+B
 c
+c2
-d
 e
+f
```

Output (exact):

```
6
a
B
c
c2
e
f
```

### Example 4 — whitespace is significant

Input (`trailing ` has one trailing space, ` both ` has one space on each
side, and the last line of B is a single space):

```
diff
5
  indented
trailing 
trailing
 both 
plain
6
  indented
trailing
trailing 
 both
plain
 
```

One valid output (cost 5; note the keep line `   indented` is the tag space
followed by the two-space-indented text, and `+ ` is the tag followed by a
one-space line):

```
8
   indented
-trailing 
 trailing
- both 
+trailing 
+ both
 plain
+ 
```

## Verification

A verifier (not exact matching) checks the output:

- `diff`: the count line and line count agree; every script line has a valid
  tag; the script reproduces A and B exactly; the cost equals
  `N + M - 2 * LCS(A, B)`, which the verifier recomputes independently.
- `patch`: the output equals the count line plus the result of applying the
  script to A, compared exactly.

## Input sizes

The largest tests are: two 5000-line files differing in a few dozen lines
(D ≈ 72); two 2000-line files with heavy random edits (D ≈ 2300); two
completely disjoint 1500-line files (D = 3000, the worst case for Myers'
algorithm); a 4000-line pair with D ≈ 1200; and a 5000-line patch. Input
files are under 200 KB.
