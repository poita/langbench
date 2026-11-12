// Package orderedmap implements an ordered map from int64 keys to string
// values, backed by a hand-written AVL tree whose nodes are augmented with
// subtree sizes.
//
// Insertion, deletion, lookup, neighbour queries (Floor, Ceil, Successor,
// Predecessor) and order statistics (Rank, Select) all run in O(log n).
// Range visits the keys in [lo, hi] in O(log n + r) where r is the number
// of keys visited.
//
// A Map is not safe for concurrent use without external synchronisation.
package orderedmap
