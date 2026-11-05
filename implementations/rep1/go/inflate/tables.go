package inflate

// Constant tables from RFC 1951 section 3.2.5.

// lengthBase and lengthExtra are indexed by (length symbol - 257).
var lengthBase = [29]uint16{
	3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
	35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
}

var lengthExtra = [29]uint8{
	0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
	3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
}

// distBase and distExtra are indexed by distance symbol.
var distBase = [30]uint16{
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
	257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
}

var distExtra = [30]uint8{
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
	7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}

// codeLengthOrder is the order in which code-length-code lengths are stored.
var codeLengthOrder = [19]uint8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

const (
	maxCodeBits  = 15  // longest Huffman code
	maxLitLen    = 286 // usable literal/length symbols in a dynamic block
	maxDist      = 30  // usable distance symbols in a dynamic block
	numCodeLen   = 19  // code-length alphabet size
	endOfBlock   = 256
	firstLenSym  = 257
	lastLenSym   = 285
	lastDistSym  = 29
	litRootBits  = 10 // root table width for literal/length codes
	distRootBits = 8  // root table width for distance codes
	clRootBits   = 7  // code-length codes are at most 7 bits: single level
)
