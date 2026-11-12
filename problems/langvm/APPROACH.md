# langvm: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `S` is the input size (at most 8 MB), `I` the number of VM instructions
executed (up to about 3 × 10^7).

## Algorithm

A compiler to bytecode plus a stack machine, in the phases of SPEC.md §16:

- **Front end:** each module is lexed and parsed by recursive descent with
  precedence climbing into a syntax tree.
- **Names:** each module's four namespaces map names to items; every reference
  is resolved once, to an id for its function, method, lambda, struct, enum,
  variant, field, trait or built-in.
- **Types:** bidirectional checking with unification over inference variables
  bound directly (union-find with the occurs check, no substitution map
  re-applied to whole types); a generic call instantiates fresh variables. Exhaustiveness and reachability use the usefulness algorithm of
  SPEC.md §12.4, per match.
- **Compile:** each checked function body becomes code for the instruction set
  of SPEC.md §16.2, with arithmetic already chosen by type.
- **Run:** a fetch-decode-execute interpreter with a value stack and its own
  call frames, so Vellum call depth is not limited by host recursion.
  `CALL_METHOD` finds its method by trait and head constructor in O(1).
  `sortBy` is SPEC.md §15.6's merge sort.

## Required rules

1. **Bytecode only, interpreted.** No direct AST interpretation, register
   machine, native code generation or JIT.
2. **No lookups by name after resolution.** The checker, compiler and VM refer
   to items by id; nothing at run time looks up a string.
3. **Strings are sequences of Unicode scalar values**, so `charAt` and `strLen`
   are O(1).
4. **Maps are insertion-ordered hash maps** with O(1) amortised insert, lookup
   and delete (SPEC.md §15.7).

## Complexity

The front end, name resolution and compilation are O(S); type checking is
near-linear in the program size, and exhaustiveness checking is local to each
match. Execution is O(I) apart from the work of the built-ins themselves (for
example O(n log n) comparator calls for `sortBy`).
