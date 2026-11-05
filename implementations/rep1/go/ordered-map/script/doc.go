// Package script executes the line-oriented command language of the ordered-map
// tool (insert, delete, get, size, min, max, floor, ceil, succ, pred, rank,
// select, range) against an orderedmap.Map.
//
// The first line of a script holds the command count Q; the following Q lines
// hold one command each. Execute parses the whole script from a byte slice with
// a hand-written cursor and appends one response line per command to a single
// output buffer. Values stored by insert are slices of the input and are not
// copied, so the input must stay unmodified while the map is in use.
package script
