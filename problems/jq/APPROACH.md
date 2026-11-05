# jq — required implementation approach

SPEC.md defines what the program computes. This note defines how it computes
it. Where this note and SPEC.md seem to disagree, SPEC.md wins.

## Overall approach

Read all of stdin into memory, split off the first line, and parse the filter
once into an AST with a hand-written recursive-descent parser. Parse the
document once into an immutable value tree with a single-pass recursive-descent
JSON parser. Evaluate with a **tree-walking interpreter in push style**:
`eval(node, input, env, sink)` calls `sink(value)` once per output, in stream
order, and nested generators are nested loops of callbacks. Values are
immutable and shared by reference; every operation that "changes" a value
builds a new top-level container that shares its unchanged children. Each
top-level result is serialised into a reusable buffer and written through one
buffered output stream.

## Required choices

1. **Value representation.** A compact tagged value: null, booleans and numbers
   (IEEE doubles) are stored inline with no heap allocation; strings, arrays and
   objects are references to immutable heap data (reference-counted or
   garbage-collected). Copying, binding, indexing or iterating a value copies
   the reference only, never the contents. Numbers are plain doubles throughout,
   held in the value itself, not boxed into a generic dynamic/any container
   that heap-allocates each number.
2. **Objects.** An insertion-ordered vector of (key, value) entries. Lookup
   scans linearly while the object is small and uses a hash index (key →
   position) once it has more than about 8–16 keys. Keys are shared string
   references; JSON parsing interns object keys (one shared string per distinct
   key text), since the document repeats the same keys in every record.
3. **Sorted key order is computed at most once per object.** Object comparison
   and `keys` need keys in code-point (= UTF-8 byte) order; compute that order
   (as a permutation of entry positions, so values are fetched without a
   lookup) lazily on first use and memoise it on the object. Comparison itself
   allocates nothing.
4. **Streams by callbacks, not iterator objects.** Generators are expressed as
   callbacks invoked per output. Callbacks are non-escaping: where the language
   allows it they live on the stack, so evaluating a node does not heap-allocate.
   `f op g` evaluates `g` as the outer loop; `[f]` and `map` append into one
   growing array; `select` re-emits the input reference.
5. **Errors.** A raised error travels to the nearest enclosing `try` either as
   a returned status or as an exception; both are allowed. Path operations
   marked `?` (`.a?`, `.[k]?`, `.[]?`, `.[a:b]?`) check the failure condition
   directly and skip the combination without raising. The `try` form
   distinguishes errors raised inside its term from errors raised downstream
   in the sink (tag/wrap them as they cross the boundary) and only swallows
   the former. Errors are never used for ordinary control flow such as
   `empty`, missing keys or out-of-range indices.
6. **Variables.** A persistent environment: one small node per binding, linked
   to the enclosing environment (or an equivalent slot stack resolved at parse
   time). Binding is O(1) and stores the value reference; `reduce` creates one
   binding per source element.
7. **Object construction `{...}`.** Keep one scratch array with a (key, value)
   slot per entry for the whole construction. The nested loops (first entry
   outermost, key stream outside value stream) overwrite slot *i*; each
   complete combination materialises one new object from the slots in O(k):
   when every key is a distinct literal (known at parse time) the slots are
   copied straight in; otherwise each slot is inserted with the ordinary set
   operation, so a repeated key keeps its first position and the last value.
   Partial objects are never copied per entry.
8. **Object `+` and `*`.** `a + b` copies `a`'s entry vector once (O(|a|)) and
   sets each key of `b` (O(|b|) expected with the index); `*` does the same,
   recursing only into keys whose values are objects on both sides. Arrays
   `+` concatenate into one exact-size allocation. Shared values are never
   mutated in place; a container may be mutated only while it is still a
   private builder created by the current operation. In particular, `reduce`
   and `+`/`*` never update an accumulator in place on the grounds that it
   happens to be uniquely referenced (no reference-count or ownership checks):
   every step builds a new value as above.
9. **`add`.** Fold into one private builder: numbers sum directly, strings and
   arrays append into a growing buffer, objects set keys into one growing
   object. `null` elements are skipped and any other type mismatch raises the
   same error as `+`. The whole fold is linear in the total size of the
   elements.
10. **Sorting.** `sort`, `sort_by`, `group_by` and `unique` use an
    O(n log n) comparison sort that is stable: the standard library's stable
    sort when it is merge-based (about n·log2 n comparisons), otherwise the
    standard unstable sort with the original index as tie-break. Never an
    in-place rotation/insertion-based stable sort, which does several times
    more comparisons and moves. What is sorted is small: element references,
    an index permutation, or (key reference, index) pairs. `sort_by`/`group_by` evaluate
    the key `[f]` exactly once per element (decorate–sort–undecorate), then
    sort indices or (key, index) pairs. `group_by` splits the sorted order in
    one linear pass comparing adjacent keys; `unique` sorts then drops
    adjacent equals, keeping the first of each run. `min`/`max` are one linear
    scan with no sort: `min` replaces its candidate only on strictly less,
    `max` on greater-or-equal, which gives the SPEC's tie rule.
11. **Comparison and equality.** One recursive three-way comparator
    implementing the total order; `==`, `!=`, `<` etc. call it directly. Strings
    compare by bytes. Arrays compare element-wise without copying.
12. **Strings.** UTF-8 byte strings. `length` and slicing count code points by
    scanning; `+` allocates the exact result size once; `/` splits with a
    single left-to-right substring search (O(n)); repetition is O(n·len).
13. **Indexing and slicing.** Field access is a lookup on the object; array
    index is O(1); array slicing copies the selected range into a new array. `tostring` uses the output serialiser; `tonumber`
    parses with a direct number parser.
14. **Output.** Serialise each result into a reusable byte buffer: integral
    doubles with magnitude below 2^53 via an integer conversion fast path,
    other numbers via `%.15g`-style formatting with trailing zeros stripped;
    strings escaped in one pass that copies unescaped runs. Write through a
    single buffered stream (or one write of the accumulated output) and flush
    once at exit, after printing `error` if evaluation failed.

Complexity targets, with N the document size, n the length of an array being
processed and k the number of keys of an object: parsing and printing are
O(N); field access is O(1) expected; object construction is O(k) per output;
sorting is O(n log n) comparisons with key evaluation O(n); `add` is linear in
the total element size; a nested generator costs O(1) overhead per inner
evaluation beyond the work of the expressions themselves.

## Left to the implementer

Exact container and hash-map types; the hash-index threshold and whether the
index is built with the object or on its first lookup; how the AST is
represented (classes, enum/variant, or node structs with a switch); whether
variables are looked up by name or resolved to slots; whether errors use
exceptions or status returns; the number-to-text routine as long as it produces the SPEC's output;
module structure, naming, and micro-optimisations such as caching the type
rank, small-string handling, or specialised fast paths for common node shapes
(for example `.a.b` chains or literal keys).

## Pitfalls

- Heap-allocating every value, including numbers and booleans, behind a shared
  pointer or by storing them in a generic dynamic container that boxes them.
  Scalars stay inline.
- A fat value struct that carries a field for every type (double, string, array
  and object reference side by side) and is copied by value everywhere.
- Closures or delegates that the runtime places on the heap for every node
  evaluation because they capture locals and are not declared non-escaping.
- Copying the partially built object once per entry during `{...}`, which is
  O(k²) per constructed object.
- Re-sorting, or allocating, each object's key list inside every comparison;
  with object-valued sort keys this multiplies the cost of `sort`, `unique`,
  `min` and `max` several-fold.
- Sorting with an in-place (rotation/insertion-based) stable sort, or moving
  large element records instead of indices or references.
- Evaluating the `sort_by`/`group_by` key inside the comparator, which costs
  O(n log n) filter evaluations instead of O(n).
- Backing objects with a hash map plus a key list and cloning both for every
  `+`, `*` or construction; copying a small entry vector is far cheaper.
- Deep-copying a value when binding it to a variable (`. as $all`), when
  indexing, or when emitting it from `.[]`; with a per-record lookup into
  `$all` this turns linear work quadratic.
- Copying object key strings instead of sharing them, both in the JSON parser
  and when building or merging objects.
- Raising and catching an exception to implement `.a?` or other path `?`
  checks that fail frequently.
- Building `add` over strings or arrays by repeated pairwise concatenation,
  which is quadratic in the number of elements.
- Unbuffered or per-line flushed output, or formatting every number through a
  general-purpose float printer when it is an integer.
