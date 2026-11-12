package inflate

// Base values and extra-bit counts for the length symbols 257..285
// (indexed by symbol-257) and the distance symbols 0..29 (RFC 1951 3.2.5).
var (
	lengthBase = [29]uint16{
		3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
		35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
	}
	lengthExtra = [29]uint8{
		0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
		3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
	}
	distBase = [30]uint16{
		1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
		257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
		8193, 12289, 16385, 24577,
	}
	distExtra = [30]uint8{
		0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
		7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
	}
)

// codeLengthOrder is the order in which the code-length code's own lengths
// are stored in a dynamic block header.
var codeLengthOrder = [19]uint8{
	16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
}

const (
	endOfBlock    = 256
	maxLitLenSyms = 286 // symbols usable in a dynamic block
	maxDistSyms   = 30
	numCLSyms     = 19
	maxCodeLen    = 15

	litRootBits  = 10
	distRootBits = 8
	clRootBits   = 7
)
