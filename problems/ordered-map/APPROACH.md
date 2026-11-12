# ordered-map: required approach

SPEC.md defines what the program does; this note defines how it computes it.
Where the two seem to disagree, SPEC.md wins.

Sizes: `Q ≤ 200,000` commands, `n ≤ Q` keys in the map, `r` the keys printed
by one `range`.

## Algorithm

A balanced binary search tree (AVL, red-black, treap, ...) or a skip list,
written from scratch and augmented with subtree sizes (or, for a skip list,
span counts). Insert and delete keep the structure balanced and the sizes
current. Every point query (get, floor, ceil, succ, pred, rank, select, min,
max) is one search from the root; `size` is read from the root. `range` is an
in-order traversal pruned to `[lo, hi]`.

## Required rules

1. **O(log n) per operation** (expected, for a randomised structure). No
   unbalanced tree, and no sorted sequence with insertion and deletion by
   shifting.
2. **Rank and select use the subtree sizes**, O(log n), never stepping through
   keys in order.
3. **`range` is O(log n + r)**: one pruned traversal, not one successor search
   per key printed.

## Complexity

Each insert, delete and query is O(log n); `range` is O(log n + r). A run is
O(input + output + Q log n).
