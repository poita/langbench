# template — implementation approach

SPEC.md defines what the program does. This note defines how it does it.

## Overall approach

Read all of stdin and split it into the JSON text and the named template
sources. Parse the JSON once into a value tree. Load templates lazily and
cache them by name: each one is lexed in a single linear pass, parsed by
recursive descent into an AST, checked for filter names, and stored. Rendering
is a tree-walking interpreter that runs directly over the cached AST. It uses
a chain of lexical scopes and appends to one output buffer, which is written
to stdout in a single write at the end (or replaced by the error line). There
is no bytecode and no code generation, and nothing is re-lexed or re-parsed
during rendering.

## Required choices

1. **Input.** Read stdin in one read. Find the `--` line and the `=== name`
   headers with one forward scan, and take template bodies as slices (or
   single copies) of the input. Parse the JSON once, in a single pass over
   the byte buffer. Total cost is O(input size).
2. **Template cache.** Lex, parse and filter-check a template at most once,
   when it is first needed, and key the cache by name. A failed load is
   reported when it happens, as the spec requires. An `include` inside a loop
   (thousands of executions) is then a cache lookup plus a render, never a
   reparse.
3. **Lexing.** Do one left-to-right scan of the body. Search for the next `{`
   and check the following character to find each tag opener, then tokenize
   the tag content in place until its closer. Text runs become text nodes that
   are stored once. Whitespace control trims the neighbouring text nodes after
   lexing. Lexing is O(body length) and parsing is O(tokens).
4. **AST shape and dispatch.** Expression and statement nodes are a closed set
   of kinds (a tagged union, an enum with a switch, or one virtual method per
   node class). Evaluation dispatches on the kind with a single branch. Binary
   operators, comparison operators and filter names are resolved to small
   integer or enum codes **at parse time**. An unknown filter name gets an
   "unknown" code and is reported by the filter check after the whole template
   has parsed, never during parsing, because a syntax error anywhere in the
   template takes precedence over a filter error. The constant key of `a.NAME`
   is built as a string value at parse time. Literal values are built once at
   parse time.
5. **Value representation.** A value is a compact tagged union: undefined,
   none, bool, 64-bit int, double, string, list, dict, macro, `range`, `super`
   and a loop record. Strings, lists and dicts are immutable once built and
   are held **by shared reference**, so copying a value (binding, passing,
   returning, putting it in a list) costs O(1) and never copies the contents.
   Strings use the language's native string type, stored as UTF-8 where that
   type is byte-based; code-point operations decode on the fly. Dicts keep
   their keys in insertion order in an array, with a hash index from key to
   position, so a member lookup is one hash probe.
6. **Scopes.** A scope is a frame holding its own bindings plus a parent
   pointer. Name lookup walks the chain. The root scope (the JSON members,
   possibly thousands of them) uses a hash map. Loop-iteration, macro-call and
   block scopes hold only a few names and must be cheap to create: use a small
   array searched linearly, or the language's lightest native map, whichever
   is cheaper to create. Template scopes (one per `include` execution) start
   empty and take no allocation until their first binding. A child scope never
   copies or flattens its parent's bindings, so creating a scope costs O(1)
   and a lookup costs O(chain depth) probes.
7. **`loop`.** Bind `loop` to a small loop record (0-based index and length)
   per iteration. `index`, `index0`, `first`, `last` and `length` are computed
   when accessed by attribute or subscript. Do not build a five-member dict
   per iteration. The guarantees allow this: `loop` is never printed, compared
   or passed to a filter.
8. **Iteration.** `for` over a list iterates the list's own element storage
   without copying it. Only dicts (keys) and strings (characters) materialise
   a sequence view, once per loop.
9. **Output.** Pass one growable output buffer down the interpreter. Text
   nodes, `{{ }}`, `include`, `block` (when it runs at its tag) and the parent
   templates of `extends` all append **directly** to the current buffer. Only
   a macro call and `super()` render into a fresh buffer, because the spec
   says they return a string; this holds even when the call is the whole `{{
   }}` expression (the returned string is then appended). Printing a value
   appends its string form to the buffer. Containers are written element by
   element into the buffer rather than built through nested temporary strings.
10. **Macros.** A macro value holds a reference to its AST node and its
    defining scope. A call creates one scope, binds arguments to parameters by
    position (keyword matching is a linear scan over the parameter list),
    evaluates defaults in that scope, and runs the body into a fresh buffer.
    No other per-call work is done. The returned string is fed to `|int` by
    the recursive idiom, so call overhead and integer parsing are both hot
    paths: over a tree of n nodes with depth d that idiom makes O(n · d)
    calls. Detect a keyword naming an already-bound parameter by checking that
    parameter's slot, not with a per-call set or map.
11. **Inheritance.** Each rendering keeps a map from block name to its chain
    of bodies, which are references to AST nodes. `extends` appends to the
    chains. `super()` holds (block name, index) and renders entry k+1. After
    `extends`, the remaining top-level nodes are skipped except `set` and
    `macro`, and then the parent body runs in the same template scope.
12. **Filters and operators.** Use the integer code from item 4 to dispatch to
    one function per filter or operator. `|int` on a string trims, then parses
    the integer form with a direct character scan (or the standard library's
    integer parser on the trimmed text), and tries the decimal form only if
    that fails. No pattern is compiled per call. `|sort` on strings computes
    each element's lowercased key once, then runs a stable O(k log k) sort on
    the keys. `in` on a dict is a hash probe, on a list a linear `==` scan,
    and on a string a substring search. Indexing a string scans to the i-th
    code point without building a list of all its characters.
13. **Float printing.** Use the standard library's shortest round-trip
    double-to-decimal conversion where one exists, then apply the spec's
    layout rules. Where none exists, format with correctly rounded
    exponent-form conversion. Start at 15 significant digits, since any double
    whose shortest form has 15 or fewer digits round-trips there, and move to
    16 and then 17 only if parsing the result back does not give the same
    double. Strip trailing zeros. That is at most three attempts, using stack
    buffers.
14. **Errors.** Signal any of the five error kinds by unwinding to the top
    level, using the language's exception/panic mechanism or result
    propagation. Because output is buffered, all-or-nothing behaviour costs
    nothing extra. The no-error path must not pay for per-node checks beyond a
    branch.

## Left to the implementer

- Exact container types (hash-map flavour, vector or array type, small-array
  versus light map for the small scopes in item 6), struct and class layout,
  and whether names are interned to integers or compared as strings (no
  string may be built during a lookup either way).
- Exceptions versus result types for errors. Recursion versus explicit
  stacks in the parser and interpreter.
- Module and file structure, naming, and how the lexer hands tokens to the
  parser (a token array per tag or an on-demand cursor).
- Reusing one loop scope across iterations by clearing it (safe because
  macros and blocks never occur inside loops) versus creating a new one per
  iteration.
- Micro-optimisations: ASCII fast paths for code-point operations,
  identity short-cuts in `==` for the same list or dict, appending integers
  to the buffer without a temporary string, reserving buffer capacity, an
  arena for AST nodes.

## Pitfalls

- Dispatching on node kind by trying a sequence of runtime type casts or
  `instanceof` checks, so later node kinds pay for every failed test. Use a
  kind tag or a virtual call.
- Comparing operator or filter **names as strings** on every evaluation (for
  example a string switch over `"+"`, `"-"` and so on, or over filter
  names). Resolve them at parse time, but raise an unknown-filter error
  only from the post-parse filter check, so syntax errors still win.
- Rendering `include` or block bodies into a temporary string and then
  copying it into the parent buffer. Nested includes and blocks then copy the
  same text once per nesting level.
- Copying a whole list to iterate it, to take its sequence view, or to pass
  it to a macro (`xs` in the recursive `total_rest(xs, i)` idiom would make
  each call O(len)). Lists are shared, never copied.
- Building a list of all a string's characters to index one of them, or
  re-decoding the whole string for each `[i]`.
- Allocating a fresh hash map (and a hash-map-backed `loop` dict) for every
  loop iteration and macro call when a few slots suffice, or a "bound"
  set per macro call. Copying or merging
  parent scopes into child scopes.
- Allocating a new string for a constant attribute name on every `a.NAME`
  evaluation. Doing two hash probes ("has", then "get") for one member
  lookup.
- Finding the shortest float representation by trying every precision from
  1 to 17, with a heap-allocated format and a parse per attempt.
- Building the output by repeated immutable string concatenation (`s = s +
  piece`), which is quadratic. Use an append buffer or a list of pieces
  joined once.
- Writing output piecemeal to an unbuffered stream, or flushing per node.
- Splitting the input into a line array and re-joining it line by line to
  rebuild template bodies when one slice of the input suffices.
