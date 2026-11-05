// Package engine implements the Tessera storage engine: a paged,
// write-ahead-logged document store with a B+tree primary index, overflow
// pages, secondary indexes, crash recovery and checkpointing.
//
// The engine works entirely in memory on byte images of the database file and
// the log; see Open and DB.Images.
package engine

// Constants fixed by the file format.
const (
	PageSize      = 1024
	MaxIndexKey   = 128
	MaxInline     = 192
	OvfPayload    = 1012
	BtreeHeader   = 16
	Capacity      = PageSize - BtreeHeader
	MinFill       = 336
	MaxIndexes    = 16
	WALLimit      = 262144
	walHeaderSize = 32
	recHeaderSize = 24
)

// Page type bytes.
const (
	typeFree     = 0
	typeLeaf     = 1
	typeInterior = 2
	typeOverflow = 3
	typeIdxLeaf  = 5
)
