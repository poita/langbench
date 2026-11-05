# scheme — required approach

SPEC.md defines what the interpreter does; this note defines how it is built.
Where the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input into memory once and parse it with a hand-written
recursive-descent reader into datums (pairs, interned symbols, integers,
strings, booleans). Compile each top-level datum once into a tree of
pre-analysed nodes, then evaluate that tree with a single trampolined
evaluator: one loop that dispatches on the node kind, recurses for subforms in
non-tail position, and replaces its current node and environment for forms in
tail position. Environments are heap frames holding `(symbol id, value)` slots
searched linearly, with the global environment as an array indexed by symbol
id. Values are small tagged words with unboxed fixnums; integers that overflow
a fixnum become hand-written sign-magnitude bignums in base 2³². All output is
appended to one buffer that is written to stdout once at the end.

Sizes: `S` is the program length in bytes, `d` the lexical nesting depth at a
variable reference, `k` the number of slots in a frame, `n`/`m` bignum
lengths in 32-bit limbs.

## Required choices

1. **Reader, O(S).** Scan the in-memory input by index; no regular
   expressions and no intermediate list of token strings that is then
   re-scanned. Build each list by collecting its elements and consing them
   from the back (or by keeping a tail pointer), never by walking to the end
   for every element. Intern every symbol once, at read time, through one hash
   map from name to a dense integer id; the special-form names and `else`
   receive known ids so recognising them is an integer comparison. Integer
   tokens become fixnums when they fit, otherwise bignums built from nine-digit
   chunks by multiply-by-10⁹-and-add. Quoted data is built once by the reader
   and returned as the same object every time the `quote` is evaluated.
2. **Compile once to a node tree.** Before evaluating a top-level form,
   convert it into nodes that carry a kind tag and pre-extracted parts: the
   symbol id of a variable, `define` or `set!`; the test/then/else children of
   `if`; child arrays for `begin`/`and`/`or` and application operands;
   pre-split `cond` clauses with an `else` flag; binding name and init arrays
   for the `let` family; and, for every `lambda`, named `let` and procedure
   `define`, a shared procedure descriptor holding the parameter ids, the
   rest-parameter flag and the compiled body array. Bodies are compiled when
   the enclosing form is compiled, never when a closure is created or called.
   The evaluator never inspects raw s-expression data, never converts a body or
   argument list to an array at run time, and never re-parses a parameter list.
3. **Value representation.** A value is a small fixed-size word or struct
   passed by value (one machine word with pointer tagging, or a tag plus a
   one-word payload). Fixnums, booleans, `()`, void, symbols (by id) and
   primitives (by id) are immediate and never allocate. Pairs, strings,
   bignums and closures are heap objects. A closure is exactly a pointer to
   its procedure descriptor plus its captured environment, so creating one is
   one small allocation. Fixnums are signed machine integers (62 to 64 bits);
   every arithmetic result that fits one is stored as a fixnum, so each
   integer has one representation and `eq?`/`=` on fixnums is a word compare
   (`eq?` on two bignums compares them numerically, as SPEC.md requires). In a
   language whose only integer type is unbounded, its integers within the
   fixnum range play the role of fixnums, with an explicit range check after
   each operation.
4. **Environments.** A frame is a parent pointer plus a growable array of
   `(symbol id, value)` slots (or parallel id and value arrays, the id array
   shared with the procedure descriptor and copied before a `define` appends
   to it), filled in order at creation; `define` replaces a slot with the same
   id in the innermost frame or appends one. A `letrec` frame starts empty and
   each variable is appended, as by `define`, once its init is evaluated. Lookup and
   `set!` scan each frame's slots, innermost frame first, then read the global
   array indexed by symbol id (with an "unbound" sentinel): O(d·k) per access,
   where `d` and `k` are small. Frames are created exactly where SPEC.md says:
   one per closure call, one per `let`/`letrec`, one per `let*` binding (and
   one for a `let*` with no bindings, so a `define` in its body stays local),
   and for a named `let` one frame for the loop name plus one per call. The
   global array grows as new symbols are interned. Do not
   resolve variables to (depth, index) addresses at compile time and do not
   give frames hash tables; both are unnecessary at these frame sizes and
   complicate the `define`-anywhere rule.
5. **Calls without per-call argument allocation.** Evaluate the operator,
   then the operands left to right, pushing each operand value onto one
   shared, growable argument stack. A primitive receives a view of the top of
   that stack. A closure call checks arity, allocates its frame with exactly
   the parameter count of slots (plus one for a rest list, which is built
   fresh from the extra arguments), copies the arguments in, pops the stack,
   and continues the evaluator loop with the closure's body. The only heap
   allocation in a fixed-arity closure call is its frame (header and slot
   array, allocated together where the language allows).
6. **Proper tail calls by trampolining.** The evaluator is one loop. The last
   form of every body, both arms of `if`, the chosen `cond` clause body, the
   last operand of `and`/`or`, the call of a named `let` and the call made by
   `apply` set the current node (and environment) and continue the loop; they
   never recurse into the evaluator and never return a "tail call" object that
   is allocated on the heap. `apply` rearranges the argument stack in place
   (drop the procedure, splice the list's elements after the leading
   arguments) and retries the application. Non-tail subforms recurse in the
   host language, so the interpreter runs on a thread created with a large
   stack (at least 256 MB), on a runtime whose stacks grow on demand, or with
   an equivalently raised recursion limit; 10,000-deep Scheme recursion must
   not overflow it.
7. **Primitives.** Each primitive is an integer id dispatched through one
   switch or a table of functions taking the argument view. Check arity first,
   then type-check every argument, then compute (SPEC.md's order). Variadic
   arithmetic and comparison take the fixnum path while all operands are
   fixnums and both operands of each step fit: overflow is detected with
   checked add/sub/mul (or a wider intermediate) and only then promotes to a
   bignum. `quotient` and `remainder` on two fixnums use the machine's
   truncating division. Negating the most negative fixnum and dividing it by
   −1 overflow too and must promote rather than wrap or trap.
8. **Bignums, schoolbook.** Sign plus a little-endian magnitude of unsigned
   32-bit limbs with no high zero limbs; all limb arithmetic uses 64-bit
   intermediates. Add, subtract and compare are O(n + m); multiplication is
   schoolbook O(n·m), result allocated zeroed once, skipping zero multiplier
   limbs; division with a one-limb divisor is short division O(n), otherwise
   Knuth's Algorithm D (normalise by shifting so the divisor's top bit is set)
   in O((n − m + 1)·m), producing quotient and remainder in one call. No
   Karatsuba or other subquadratic method, and no arbitrary-precision library
   or built-in unbounded integer type (in a language whose only integer type is
   unbounded, limbs are plain integers below 2³² and every intermediate stays
   below 2⁶⁴). Decimal conversion
   repeatedly divides a scratch copy by 10⁹
   with short division, then prints the top group unpadded and the rest as
   nine zero-padded digits: O(n²).
9. **Memory management.** Unreachable objects are reclaimed while the program
   runs, using the language's ordinary mechanism: the built-in tracing
   collector with default settings where the language has one, or reference
   counting (or a hand-written tracing collector) where it does not. Reference
   counting may leak cyclic closure/frame garbage; that is acceptable. Do not
   use an allocator that never frees, and do not disable or retune the
   runtime's collector.
10. **Output.** `display`, `newline`, top-level results and the final error
    line all append to one in-memory output buffer (or a large buffered
    writer); write it to stdout once at the end. Printing walks lists
    iteratively along the `cdr` chain and appends directly into that buffer
    rather than building and concatenating intermediate strings per element.
    A runtime error unwinds to the top level with the language's exception,
    panic or error-result mechanism, appends `error: <category>` and stops.

## Left to the implementer

- Exact value encoding (pointer tagging, NaN-boxing or a tag-plus-union
  struct), fixnum width within 62–64 bits, and object header layout.
- Whether node dispatch is a switch on a kind tag or a per-node method or
  function pointer, provided tail positions return control to the single
  evaluator loop as in choice 6.
- How primitives are stored (switch versus function table), container types,
  symbol-table hash map, module structure and naming.
- Whether the whole program is read into datums before evaluation starts or
  form by form (inputs are well formed).
- Error propagation mechanism; how the large stack is obtained.
- Micro-optimisations that keep the same algorithms: special-casing two
  fixnum operands, fast paths for one-limb bignum operands, avoiding a copy of
  a bignum magnitude for read-only operations, small-integer caches.

## Pitfalls

- Interpreting raw s-expressions at run time: re-walking `(let ...)` or
  `(cond ...)` lists, re-extracting bindings, converting bodies or clause
  lists to fresh arrays on every evaluation, or re-parsing a lambda's
  parameter list every time a closure is created. Each costs allocations on
  every loop iteration; compile once (choice 2).
- Allocating a new argument array for every call, then another array for the
  frame, then a frame object: three allocations where choice 5 needs one.
  Growing `apply`'s argument list by repeated appends instead of splicing in
  place.
- Representing integers as heap objects (boxed in an interface, a reference
  counted cell or a class instance) so that every `(+ i 1)` allocates.
- Storing the global environment in a hash map consulted on every global
  reference, or making each lookup of `car`, `+` or a user procedure hash a
  string. Globals are an array indexed by symbol id.
- Heap-allocating a "tail call" record on every tail call, or implementing
  tail calls by recursion that only happens to work with a large stack.
- Comparing or copying symbols as strings anywhere after reading.
- Recursion proportional to list length in printing, `equal?`, list
  construction in the reader or, under reference counting, in freeing a long
  list: iterate along the `cdr` and recurse only into the `car`.
- Building output with repeated string concatenation, or writing to an
  unbuffered stream once per `display`.
- Converting fixnum operands to bignums for ordinary arithmetic or
  comparison, or computing `number->string` of a bignum digit by digit
  (division by 10 per digit) instead of by 10⁹.
