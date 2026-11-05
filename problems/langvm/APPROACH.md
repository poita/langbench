# langvm: required implementation approach

SPEC.md defines what the program must output. This note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

## Overall approach

A conventional single-pass-per-phase compiler feeding a switch-dispatched stack
VM. Read all of stdin at once, split it into modules, lex each module once into
a token array, and parse it by recursive descent into an AST. Resolve names
through hash maps to dense integer ids, type-check with mutable inference
variables, check exhaustiveness per match, then compile each function once into
a flat array of fixed-format instructions in which every name has become an
integer index. The VM runs one dispatch loop over that code with a preallocated
value stack and frame array. Values are small fixed-size tagged cells: scalars
inline, everything else a reference to a heap object. Output is collected in one
byte buffer.

## Required choices

1. **Bulk input, linear front end.** Read stdin with one bulk read (or a few
   large block reads). Lex each module in a single left-to-right pass into an
   array of tokens carrying kind, line, column and literal payload. The parser
   is recursive descent with precedence climbing over that array, using bounded
   lookahead; nothing is re-lexed or re-parsed. Front-end cost is O(input
   size).
2. **Integer ids after resolution.** Each module's four namespaces are hash
   maps from name to item. Every function, method, lambda, struct, enum,
   variant, field, trait and built-in gets a dense integer id; resolution
   happens once per reference and the result is stored on the AST node. No
   later phase looks anything up by string.
3. **Inference with mutable variables.** Primitive types are shared singletons.
   An inference variable is a mutable cell bound at most once; reading it
   follows the binding chain (path compression allowed). Unification walks two
   types structurally with the occurs check; a generic call instantiates fresh
   variables for its type parameters. No substitution map is re-applied to
   whole types or environments. Exhaustiveness and reachability use the
   usefulness algorithm of SPEC 12.4 directly on each match's rows; its cost is
   local to the match.
4. **Bytecode compiled once per function.** One walk over the checked body
   assigns local slots, collects capture lists, and emits code with forward
   jumps fixed through patch lists. Constants go into a pool deduplicated by
   hash maps. Each function records its parameter count, slot count and an
   upper bound on its operand-stack depth (the exact maximum, or a safe bound
   such as its code length).
5. **Flat instruction encoding.** A function's code is one contiguous array
   of integers (opcode then inline operands) or of fixed-size instruction
   records. Operands are pool indices, slot numbers, jump targets, function,
   field, variant, trait/method and built-in ids. Arithmetic opcodes are typed
   by the checker (`ADD_I` vs `ADD_F` and so on), so the VM never tests tags to
   do arithmetic.
6. **Instruction set: SPEC 16.2 plus a fixed set of fused forms, nothing
   else.** Every implementation adds exactly these:
   - *Slot-based match tests.* The scrutinee (and each nested sub-value being
     tested) is stored once in a local slot. Tests read from the slot and
     branch in one instruction: "jump to t unless the enum in slot s is variant
     v", "jump to t unless the list in slot s has length = n (or >= n)". Pushing
     a component reads from the slot: "push payload i / field i / tuple
     component i / list element i of slot s". Literal tests stay `PUSH_CONST`,
     `EQ`, `JUMP_IF_FALSE`.
   - *Loop forms.* "push length of the list or string in slot s", "push element
     at the index in slot i of the sequence in slot s", and "increment the Int
     in slot i". A `for` over a sequence evaluates the sequence once into a slot
     and, before every iteration, reads its current length with the fused
     length form (SPEC 11.4: a body that appends to or shortens the list
     changes the iteration count); a range `for` keeps the counter and the
     evaluated bound in two Int slots and uses `LT` and the increment.
   No further superinstructions, register allocation, inline caches,
   specialisation by profiling, or native code generation.
7. **One dispatch loop with cached machine state.** The VM loop is a single
   switch (jump table) on the opcode, or the host's closest equivalent. `pc`,
   `sp`, the frame base, the current code array and the current closure are
   local variables, reloaded only on call, return and re-entry. The value
   stack is one preallocated array indexed by `sp`; capacity is checked once
   per call using the callee's slot count plus its stack-depth bound (growing
   geometrically if needed), never per push.
   The frame array is preallocated for 20000 frames; a call is a bounds check,
   one frame record write and a jump. Vellum calls never use host recursion.
   Built-ins that call closures (`sortBy`, `listMap`, ...) push the arguments
   on the value stack and re-enter the same loop with a stop depth.
8. **Value representation.** A value is a fixed-size tagged cell: a tag plus a
   64-bit payload holding an Int, Float bits, Bool, Char or Unit, or a
   reference to a heap object. Use a union of payload and reference where the
   language allows it; a cell with separate scalar and typed-reference fields
   is acceptable where it does not. A host whose native values already carry
   their type may use them directly, provided Int/Bool and Char/Str stay
   distinguishable for dispatch. Scalars never allocate. Tuples, structs and
   enum payloads are one object holding a declaration id, a variant index and
   a contiguous array of values accessed by index. A variant without payload is
   represented without allocating (the variant index in the cell, or one shared
   object per variant). Lists are growable contiguous arrays of cells.
   Strings are immutable arrays of Unicode scalar values (so `charAt` and
   `strLen` are O(1)), shared by reference and encoded to UTF-8 only on output.
9. **Memory management.** Garbage-collected hosts use their collector. Hosts
   without one use non-atomic reference counting on heap objects only: no count
   traffic for scalar tags, popping or storing a value moves ownership instead
   of copying it and then releasing the original, and freeing a long chain of
   objects is iterative. Objects are reclaimed during the run, not leaked.
10. **Direct call paths.** `CALL` names its function index statically.
    `CALL_METHOD` reads the receiver's head-constructor id (a small integer
    from its tag, plus the declaration id for structs and enums) and indexes a
    dense table `[trait][head constructor] -> method function ids` built once
    after compilation. `CALL_BUILTIN` indexes a table of host functions and
    passes a direct view of the `argc` argument slots on the value stack (a
    pointer or slice); the arguments are dropped and the result is written
    where the first argument was (pushed when `argc` is 0). No call path
    allocates an argument array.
11. **Comparisons.** `EQ`/`NE`/`LT`/`LE`/`GT`/`GE` test the operand tag and
    handle Int, Char and Bool inline, then Float, then Str through a scalar
    array compare. Structural recursion runs only for compound values.
12. **Insertion-ordered maps.** A map is a vector of entries (key, value, live
    flag) plus a hash index from key to entry position. Keys are only Int,
    Bool, Char or Str: scalars hash their 64-bit payload with a cheap
    non-cryptographic mix, and strings hash their scalar array in place.
    Deletion clears the entry and marks it dead; compact when dead entries
    exceed half the vector. Every operation is O(1) amortised, and iteration
    walks the vector skipping dead entries.
13. **Built-ins over the representation.** String built-ins work on scalar
    arrays and build each result in one growable buffer. `strIndexOf`,
    `strSplit` and `strReplace` scan left to right with direct comparison at
    each position. List built-ins use the host's contiguous-array operations.
    `sortBy` is exactly SPEC 15.6's bottom-up merge sort, with the two buffers
    allocated once per call. Float printing uses the host's correctly rounded
    fixed-point formatting, as SPEC 19 suggests.
14. **Buffered output.** `print` and `emit` append UTF-8 bytes to one output
    buffer. Write it in one go at the end, or in large chunks. On a panic,
    append the panic line and write the buffer. A diagnostic replaces all
    output.

## Left to the implementer

- Hash table implementation and hash function (any cheap non-cryptographic
  hash), and whether string objects cache their hash. A host whose standard
  hash map already preserves insertion order with exactly the semantics of
  SPEC 15.7 (re-assignment keeps the position, delete then insert moves the
  key to the end, O(1) amortised operations) may use it for maps.
- AST and type layout, whether types are hash-consed, and how diagnostics and
  panics propagate inside the program (exceptions, result values, flags).
- Exact opcode numbering, operand width, whether small integer constants are
  immediates, and how fused instructions are named.
- Running the compiler on a thread with a larger host stack for deep parser
  or checker recursion.
- Module layout, naming, and normal optimised release build flags.

## Pitfalls

- Reading stdin one character at a time through a stream iterator, which can
  cost more than lexing and parsing the 2 MB input combined.
- Allocating a fresh argument array for every built-in call or every closure
  call made from a built-in. `charAt`, map access and comparator calls sit in
  the hottest loops.
- Looking up a hash map keyed by (trait, head constructor) on every method
  call instead of indexing a dense table.
- Using a dynamically growing stack with a capacity check on every push and
  pop, or resizing or zero-filling the stack on every call.
- In reference-counted hosts, copying a value then releasing the original on
  every pop and store, or touching counts for scalars. In collected hosts,
  boxing values so that creating a string or list cell allocates twice.
- Allocating a heap object for every payload-less enum value, or for every
  enum or struct even when the payload count is zero.
- Converting a string key to a different string type, or copying it, on every
  map lookup.
- Generic arithmetic opcodes that dispatch on both operand tags, when the
  checker already knows the type.
- Compiling match tests as repeated load / test / jump sequences on the
  operand stack instead of the slot-based fused forms. Re-evaluating the
  sequence expression on every `for` iteration, or caching a list's length
  before the loop (wrong when the body mutates the list).
- Writing output unbuffered or flushing per `print`.
- In collected hosts, heavy allocation churn in the front end (temporary
  arrays per node, repeated array concatenation instead of appending to one
  builder). On the largest input, collection time can dominate compilation.
