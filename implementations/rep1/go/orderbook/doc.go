// Package orderbook implements a single-instrument limit order book with
// price-time priority, together with a parser and runner for the line-based
// command protocol used by the accompanying command-line tool.
//
// # Design
//
// All prices that will ever be used are known up front (they are collected
// from the command stream in a first pass), sorted, de-duplicated and given a
// dense rank. Each side of the book is then a plain array of price levels
// indexed by rank, and a segment tree over that array (per-node quantity sum
// and non-empty-level count) answers, in O(log P):
//
//   - what is the best non-empty level on this side,
//   - how much quantity rests at or better than a given rank (fill-or-kill),
//   - what is the next non-empty level after a given one (book listings).
//
// Resting orders live in one arena addressed by integer index. Within a level
// they form an intrusive doubly linked FIFO list, so fills at the head and
// cancels from the middle are O(1). A single hash map from order id to arena
// index serves CANCEL and REPLACE.
//
// # Usage
//
// The simplest entry point is [Run], which takes the whole text protocol and
// returns the whole text output. For programmatic use build a [Book] over a
// fixed, sorted price table with [NewBook] and call [Book.Limit],
// [Book.Market], [Book.Cancel], [Book.Replace] and [Book.Snapshot]; every
// call appends its events, in the protocol's text form, to the book's output
// buffer, available from [Book.Output].
//
// A Book is not safe for concurrent use.
package orderbook
