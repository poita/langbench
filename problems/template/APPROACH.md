# template: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `I` is the input size, `B` a template body's length, `O` the output
size.

## Algorithm

Split the input into the JSON context and the named template bodies, and parse
the JSON once by recursive descent. Templates load lazily: the first time one
is needed it is lexed, parsed by recursive descent into a syntax tree and
filter-checked. Rendering is a tree-walking interpreter over those trees, with
a chain of lexical scopes. Inheritance keeps, per rendering, a map from block
name to its chain of bodies, extended as `extends` tags run.

## Required rules

1. **Each template is lexed, parsed and checked at most once.** No bytecode or
   code generation: the interpreter walks the tree.
2. **Values are shared, never copied.** Binding a name, passing an argument,
   returning a value and iterating a list cost O(1) per value, whatever its
   size.
3. **Creating a scope is O(1)**, and a lookup costs O(scope-chain depth). Dict
   member lookup and `in` on a dict are expected O(1).
4. **Total output work is O(O) plus macro and `super()` results.** `include`,
   `block` and `extends` add no cost per nesting level; only a macro call and
   `super()` produce a separate string, as SPEC.md says.
5. **`sort` is a stable comparison sort** with O(k log k) comparisons.

## Complexity

Splitting and JSON parsing are O(I). Lexing and parsing a template are O(B).
Rendering is linear in the nodes executed plus `O`; indexing a string at code
point `i` costs O(i).
