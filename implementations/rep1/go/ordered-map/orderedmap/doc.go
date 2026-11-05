// Package orderedmap implements an ordered map from int64 keys to byte-slice
// values, backed by a size-augmented AVL tree.
//
// Every operation — Put, Delete, Get, Floor, Ceil, Successor, Predecessor,
// Rank and Select — runs in O(log n). Ascend visits the keys of a range in
// O(log n + r) where r is the number of keys visited.
//
// Nodes live in a single index-addressed pool (index 0 is a nil sentinel), so
// the tree performs no per-node heap allocation and the garbage collector
// sees one slice rather than a pointer graph of nodes.
//
// Values are stored by reference: Put keeps the slice it is given and Get
// returns that same slice. Callers must not modify a slice after storing it.
//
// A Map is not safe for concurrent use.
package orderedmap
