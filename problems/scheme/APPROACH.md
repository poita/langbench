# scheme: required approach

SPEC.md defines what the interpreter does; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `S` is the program length (up to about 200 KB), `d` the number of frames
between a variable reference and its binding, `k` the bindings in a frame, `n`
and `m` the lengths of bignum operands.

## Algorithm

A pre-analysing interpreter with a trampoline. A recursive-descent reader turns
the input into datums, interning symbols. Each top-level form is analysed once
into a tree of nodes (variable references, `if`, `lambda` with its parameter
list and analysed body, applications, and so on), and that tree is evaluated.
Environments are a chain of frames, each a small map from symbol to value,
ending in the global environment. Integers become bignums when they overflow a
machine word.

## Required rules

1. **Analyse once.** Every form, including every `lambda` body, is analysed
   once, before it first runs; evaluation never re-examines the raw
   s-expressions of a form.
2. **Variables are looked up by name at run time**, innermost frame first and
   then the global environment. No compile-time (depth, index) addressing.
3. **Tail calls by trampolining**, so tail loops use constant host stack.
   Non-tail calls nest, and 10,000-deep recursion must work.
4. **Classical bignum algorithms:** schoolbook multiplication and Knuth's
   Algorithm D for division. No Karatsuba or other subquadratic method.
   Decimal output divides repeatedly by a power of ten.

## Complexity

Reading and analysis are O(S). A variable access is O(d·k); every other
evaluation step is O(1) apart from the work SPEC.md's primitives do on their
arguments. Bignum addition, subtraction and comparison are O(n + m),
multiplication O(n·m), division O((n − m + 1)·m) and decimal conversion O(n²).
