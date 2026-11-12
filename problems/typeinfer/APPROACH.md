# typeinfer: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `n` is the size of one declaration's syntax tree, `s` the number of
distinct nodes in a type (types are shared, so `s` can be far below the size of
the printed type).

## Algorithm

Algorithm J. Each declaration is parsed by recursive descent into a syntax tree
and inferred in one left-to-right pass that unifies as it goes:

- **Types** form a shared graph (a DAG): variables are union-find nodes with a
  level; constructors refer to their child types.
- **Unification** is union-find unification with an occurs check whenever a
  variable is bound; the same walk lowers the levels of the variables it
  reaches.
- **Generalisation** is level-based (Rémy): a `let` right-hand side is inferred
  one level deeper, and its unbound variables above the outer level are
  quantified.
- **Instantiation** copies a scheme's quantified variables to fresh ones and
  shares every sub-term that contains none.
- **The environment** maps names to their innermost binding, polymorphic
  (let-bound) or monomorphic (lambda parameter, recursive name in its own body).

## Required rules

1. **Walks are O(s).** The occurs check, generalisation and instantiation visit
   each distinct node once, never the type expanded into a tree, and an
   instantiated copy keeps the original's sharing.
2. **A monomorphic binding's type is used as it is**, in O(1).
3. **Generalisation never scans the environment**, and name lookup does not
   depend on the number of bindings in scope.
4. **No per-node summaries** (such as cached levels) that let generalisation or
   instantiation skip sub-terms, and no delayed level adjustment.

## Complexity

One declaration costs O(n) plus the distinct nodes visited by its
unifications, occurs checks, generalisations and instantiations. Chains of
nested `let`s are inherently quadratic in their length; nothing else may add a
factor of the environment size or of a type's expanded size. Expressions and
types nest a few thousand levels deep, which the program must handle.
