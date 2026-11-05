# regex — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input with one bulk read and walk it as line views.
Parse each pattern once into a syntax tree, compute two start-position
filters from the tree (anchored-at-start, first-character set), and compile
the tree into a flat program for a **backtracking virtual machine**
(`char`, `any`, `class`, `bol`, `eol`, `split`, `jmp`, `save`, `mark`,
`check`, `match`, plus one `charloop` instruction for repeated single-character
atoms). Every subject is matched by one iterative interpreter loop that keeps
an explicit choice-point stack and an undo trail for captures; the stack,
trail and capture array are allocated once and reused. Results are appended
to one output buffer that is written once at the end.

Sizes: `P` is the pattern length, `E ≤ 20000` the atom count after expanding
counted quantifiers, `G ≤ 50` the group count, `n ≤ 10000` the subject
length.

## Required choices

1. **Input, O(input).** One bulk read of stdin into a byte buffer. Lines are
   (start, end) views found by scanning for `\n`, consumed strictly by
   position and count. Patterns and subjects are not copied into owned
   strings, trimmed or re-split. Counts are parsed with a digit loop.
2. **Parse once per pattern, O(P).** A recursive-descent parser builds a
   small tree (literal, any, class, bol, eol, seq, alt, group, rep). Classes
   and set escapes are resolved at parse time to a 256-entry membership set
   (bitmap or byte table); matching a class is one table lookup.
3. **Compile to a flat program, O(E).** One array of fixed-size instructions
   (an opcode plus a few integer operands; class sets referenced by index
   into a side table). Compilation follows the standard backtracking-VM
   scheme: seq concatenates; `alt` of `b1..bk` emits `split L1, L2` before
   each branch but the last, so the first target is always the preferred
   path, with `jmp end` after each; a group emits `save 2g`, body, `save 2g+1`.
4. **Repetition compilation.** For `x{min,max}` with a general body: emit
   `min` copies of `x` inline (mandatory iterations always run, even if they
   match empty). For an unbounded max emit `L: split body, exit; [mark r];
   x; [check r → exit]; jmp L`. For a finite max emit `max−min` nested
   optional copies, each `split body, exit; [mark r]; x; [check r → exit]`,
   all with the same `exit` after the last copy. `mark r` stores the current
   position in loop register `r` (trailed), and `check r` jumps to `exit` when
   the position has not moved, which realises the spec's "an empty optional
   iteration ends the repetition". Emit `mark`/`check` only when `x` can match
   without consuming (decided statically); otherwise they are omitted. `x{0}`
   emits nothing.
5. **Single-character loops.** When the repeated atom is a literal, `.`, a
   class or an escape (it consumes exactly one character and contains no
   group; a parenthesised group is never a single-character atom), compile
   the whole quantifier, any `min`/`max`, to one `charloop` instruction: scan
   forward greedily while the character matches, up to `max`; fail if fewer
   than `min` matched; otherwise push **one** choice point recording the
   loop's lowest allowed end and current end, and continue at the longest
   end. Backtracking into it gives back one character (re-pushing the choice
   point while ends remain). This explores exactly the spec's order with one
   stack entry per loop instead of one per character.
6. **Interpreter.** One loop over `pc` with a switch on the opcode; no
   recursion, no closures, no per-step allocation. On `split a, b` push
   `(b, pos, trail length)` and continue at `a`. On failure pop the newest
   choice point, undo the trail down to its recorded length, and resume; an
   empty stack means this start position fails. `save` and `mark` push
   `(slot, old value)` onto the trail before writing. Captures and loop
   registers live in one flat integer array (`-1` = unset). Every implementation
   therefore takes the same steps in the same order as section 3 of SPEC.md.
7. **Start positions.** Compute from the tree whether every match must begin
   with `^` (`^` first in a seq, all branches of an alt anchored, a group with
   an anchored body, a rep with `min ≥ 1` and an anchored body); if so try only
   start 0. Otherwise compute the first-character set and nullability (`^`,
   `$`, `x{0}`, `x*`, `x?` and empty branches are nullable; a seq unions its
   items' sets up to and including the first non-nullable one; `.` makes the
   set "any"). If the pattern is not nullable and its set is not "any", skip
   start positions whose character is not in the set (and the position `n`)
   with a tight scan before entering the VM. No other search acceleration:
   no literal-substring prefilters, required-literal checks, memoisation,
   DFA/NFA simulation or reordering of tried paths.
8. **Per-subject and per-start cost.** The program, filters, stack, trail and
   capture array are built once per pattern (stack and trail may be shared by
   all patterns) and only grow. Per start position, reset the `2G` capture
   slots and set stack and trail lengths to zero; loop registers need no reset.
9. **Output.** Format each result with a hand-written integer-to-digits
   routine appended into one growing output buffer; write it once at the end.

## Left to the implementer

- Container types, struct layout, naming, module structure; whether operands
  are stored as parallel arrays or as instruction records.
- Bitmap versus byte-table class sets; byte-sized or wider opcodes.
- How `charloop` choice points are encoded (a tagged stack entry, or a
  separate opcode the stack entry resumes at), provided one entry per loop.
- Whether the trail stores tagged entries or separate capture/register trails,
  and whether capture start is written at group open or both ends at close,
  provided the reported values follow SPEC.md.
- The integer width of positions and slots, bounds-check elimination,
  dispatch style, and other loop-level micro-optimisations.

## Pitfalls

- Matching by recursive tree walking with continuations: one or more native
  calls per character consumed, recursion depth proportional to the subject
  (needing huge thread stacks), and in languages where closures capture by
  heap allocation, an allocation on every node visit.
- Allocating per subject or per start position: a fresh capture array, stack
  or trail per attempt, or copying the subject line into a new string.
- Keeping the hot matcher state (subject, captures, stack) in thread-local or
  otherwise indirectly addressed globals instead of locals or one context
  object reached through a pointer.
- Pushing one choice point per character for `.*`, `\w+`, `[^,]*` and similar
  single-character loops instead of one `charloop` entry.
- Emitting a `mark`/`check` pair (and its trail entries) for loop bodies that
  can never match empty.
- Trying every start position for patterns anchored with `^`, or entering the
  VM at positions the first-character set rules out.
- Re-parsing or recompiling the pattern per subject; copying capture arrays
  into choice points instead of using the undo trail.
- Formatting each output line through a general-purpose formatter, building
  per-line temporary strings, or writing and flushing per line; reading input
  line by line through an unbuffered stream.
