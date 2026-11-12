package tessera

// File format constants (SPEC §5.2).
const (
	PageSize    = 1024
	MaxKey      = 128
	MaxIndexKey = 128
	MaxInline   = 192
	OvfPayload  = 1012
	MaxDoc      = 65536
	MaxDepth    = 32
	PageHeader  = 16
	Capacity    = PageSize - PageHeader
	MinFill     = 336
	MaxIndexes  = 16
	MaxPath     = 30
	MaxSegments = 8
	WALLimit    = 262144
	MaxLimit    = 2147483647

	walHeaderSize = 32
	recHeaderSize = 24
	frameSize     = recHeaderSize + PageSize
)

// Page type bytes (SPEC §7.1).
const (
	typeFree     = 0
	typeLeaf     = 1
	typeInterior = 2
	typeOverflow = 3
	typeIndexLf  = 5
)
