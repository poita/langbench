# orderbook: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` is the number of commands, `P` the number of price levels on a side
(up to about 12,000), `k` the number of levels a `BOOK` prints.

## Algorithm

Commands are executed in order. Each side of the book is an ordered collection
of price levels: any sorted structure or heap over prices, as SPEC.md allows
(a balanced tree, skip list, sorted sequence, heap, or a segment or Fenwick
tree over prices compressed in advance). A level holds its FIFO queue of
resting orders, its total resting quantity and its order count. A map from
order id to the resting order serves `CANCEL` and `REPLACE`. Matching consumes
makers from the best opposite level's queue head, level by level.

## Required rules

1. **Best price without a scan.** A side's best level is found, and an
   emptied best level removed, in O(log P) or better; matching never scans
   all levels.
2. **Removal from the middle of a level is O(1)** (or amortised O(1)): a
   `CANCEL` or priority-losing `REPLACE` takes the order out of its queue
   without scanning it.
3. **Level totals are kept up to date**, so a FOK check and a `BOOK` line read
   each level's quantity in O(1) instead of summing its orders.

## Complexity

Parsing is O(input size). A command costs O(fills + levels visited × log P)
plus any level it adds to or removes from the ordered structure (O(log P) in a
tree or heap); `CANCEL` and `REPLACE` add one id lookup. A FOK check is
O(levels crossed) or better, and a `BOOK` is O(k log P) or better.
