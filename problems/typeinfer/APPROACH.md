# typeinfer: required implementation approach

SPEC.md defines what the program must output. This note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

## Overall approach

Algorithm J with destructive union-find unification and level-based
(Rémy-style) generalisation. Read all of stdin, lex it in one pass into a token
array with identifiers interned to dense integer ids, and parse every
declaration with a recursive-descent parser into a compact AST. Type terms are
mutable nodes in a shared graph (a DAG: sub-terms are shared, never copied
unless they must change). Inference is a single left-to-right recursive pass
that unifies as it goes, keeps an environment of per-name binding stacks, marks
quantified variables in place at each `let`, and instantiates a scheme by one
memoised walk over the reachable type DAG. Each result is rendered into one
output buffer that is written once at the end.

## Required choices

1. **One-pass lexing with interned identifiers.** Read stdin whole; the lexer
   walks the bytes once, producing tokens with an integer kind (one kind per
   keyword and per symbol, longest match) and, for identifiers, a dense id from
   one hash map. Integer literals carry no value. Parsing is recursive descent
   over the token array, O(tokens); `::` chains and list literals are collected
   iteratively, `let f x y = e` is desugared to nested `fun`s at parse time.
2. **Type representation.** A type node is either a variable (link to its
   representative or none, an integer level) or a constructor (`int`, `bool`,
   `unit` as shared singletons; arrow, list and n-ary tuple with child
   references). Every node also has a visit stamp and a memo slot (the
   instantiation result), stored in the node or in arrays indexed by node id.
   Nodes live in an arena or as heap objects; either way a node and its stamp
   and memo are reached by a direct reference or index, never by a hash
   lookup. `find` follows links with path compression. The stamp counter is
   wide enough never to wrap during a run.
3. **Environment as per-name stacks indexed by interned id.** Binding pushes
   onto that name's stack and records the name on a trail; leaving a scope pops
   it; a failed declaration unwinds the trail to its starting mark. Lookup is
   an array index plus a top-of-stack read: O(1), independent of environment
   size. Each binding carries a flag saying whether it is polymorphic
   (let-bound, may contain quantified variables) or monomorphic (lambda
   parameter, `let rec` name inside its own body).
4. **Unification is eager, recursive and ordered as SPEC.md requires.**
   Find both sides; identical nodes succeed; a variable is bound after an
   occurs check; constructors must match in kind and arity and their children
   are unified left to right, each fully before the next. The first failure
   aborts the declaration (exception, panic or error return) with its kind.
5. **Occurs check fused with level adjustment, visiting each node once.**
   Binding variable `v` to `t` walks `t` once, failing with `occurs` if it
   reaches `v` and lowering every reached variable's level to at most
   `v`'s. Compound nodes already visited in this walk are skipped using a
   per-node stamp compared with a global counter incremented per walk, so the
   walk is O(distinct nodes of the DAG), not O(size of the expanded tree).
6. **Level-based generalisation, in place.** The right-hand side of every
   `let`/`let rec` (and every top-level binding or bare expression) is inferred
   at level + 1; for `let rec` the name's fresh variable is also created at
   level + 1, and is unified with the right-hand side's type before
   generalising. Afterwards one stamped walk over the result marks each unbound
   variable whose level exceeds the current level as quantified (a dedicated
   "generic" level value). The environment is never scanned: the cost is
   O(nodes of the generalised type), whatever the number of bindings in scope.
7. **Instantiation by a memoised DAG copy that shares unchanged sub-terms.**
   A monomorphic binding returns its type unchanged with no walk. For a
   polymorphic one, walk the type once under a fresh stamp: a quantified
   variable maps to one fresh variable at the current level; a non-quantified
   variable maps to itself; a compound node is rebuilt only if the result for
   some child differs from that child's representative (a child that is merely
   a bound variable does not count as changed), otherwise the original node
   is returned. Each visited node records
   its result in its own memo slot guarded by the stamp, so a node shared many
   times is copied once and the copy keeps the original's sharing. The cost is
   O(distinct nodes of the scheme) per use of a variable.
8. **Printing walks the expanded type into one buffer.** Render with a context
   argument (top/right of arrow, left of arrow, tuple component or list
   element) that decides parentheses. Variable names are assigned in order of
   first appearance via a per-declaration map from variable node to index;
   build the name text only when a variable is first named. All output is
   appended to one buffer and written once.
9. **Deep recursion is supported directly.** Expressions and types nest up to
   several thousand levels; run parsing, inference and printing on a thread
   (or with a stack limit) large enough for plain recursion rather than
   rewriting the algorithms around an explicit stack.

With these choices one declaration costs O(AST size + total nodes created and
visited by unification, generalisation and instantiation). The nested-`let`
chains are inherently quadratic in chain length (each `let` generalises and
each use instantiates a type that grows along the chain); no other step may add
a factor of the environment size, the number of declarations or the expanded
(tree) size of a shared type.

## Left to the implementer

- Arena of nodes with integer indices versus individually allocated objects;
  how constructor children are stored (fixed fields for arrow/list plus a
  child array for tuples, or one shared child pool); integer widths.
- Whether the AST is a node array with indices or a tree of objects, token and
  AST layout, the interner's hash map type, how errors propagate (exceptions,
  panics, result values).
- Whether a level-based or stamp-based "already generalised" test is used, as
  long as each walk visits each distinct node at most once.
- Module structure, naming, micro-optimisations, and compiler flags beyond a
  normal optimised release build.

Optimisations that change the asymptotic work of item 6 or 7 (for example
per-node level summaries that let generalisation or instantiation skip whole
sub-terms, or delayed level adjustment) are not part of this approach; every
implementation performs the walks described above.

## Pitfalls

- A hash map as the copy memo or for visit marks, whether created per
  instantiation or kept globally and cleared per call (a keyed or
  cryptographic default hasher makes it worse). Store the stamp and copy
  result per node; the instantiation memo is the hottest path in the
  large-type and let-chain inputs.
- Instantiating without memoising compound nodes (only variables): a shared
  DAG then expands into a tree, turning a pair tower of a dozen nodes into thousands
  and making later unification and occurs checks exponential in tower depth.
- Occurs-check, generalisation or instantiation walks without visit stamps,
  which re-traverse shared sub-terms once per path.
- Walking a monomorphic binding's type on every use (it may be linked to a
  very large type) instead of returning it directly.
- Generalising by computing free variables of the whole environment, or
  looking names up through a chain of scopes or a string-keyed map rebuilt per
  scope; both make the many-binding inputs quadratic.
- Copying node payloads during unification or traversal, e.g. cloning a
  tuple's child array, or allocating a temporary child list to iterate a
  node's children; iterate the children in place. During instantiation,
  allocate the new child list only once a child is known to have changed.
- Rebuilding compound nodes during instantiation when no child changed, which
  allocates a full copy of every non-generic type at every use.
- Allocating a separate small heap array for every arrow and list node's two
  or one children when the runtime makes that costly; prefer fixed fields or a
  shared pool.
- Re-parsing or re-tokenising per declaration, building strings for tokens
  that are keywords or symbols, or writing output line by line unbuffered.
