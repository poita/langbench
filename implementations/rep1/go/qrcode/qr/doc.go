// Package qr encodes text as QR Code Model 2 symbols (ISO/IEC 18004).
//
// The package supports numeric, alphanumeric and byte modes (single segment,
// no ECI), versions 1 through 40, all four error correction levels, the eight
// mask patterns and automatic mask selection by penalty scoring.
//
// Basic use:
//
//	sym, err := qr.Encode([]byte("HELLO WORLD"), qr.M, qr.AutoMask)
//	if err != nil {
//		log.Fatal(err)
//	}
//	fmt.Print(sym) // '#' for dark modules, '.' for light ones
//
// The implementation is split by responsibility: gf.go (GF(2^8) arithmetic),
// rs.go (Reed-Solomon), bitwriter.go (bit packing), tables.go (capacity
// tables), segment.go (mode and version selection), codewords.go (data and
// ECC codewords), matrix.go (function patterns and placement), mask.go,
// penalty.go and encode.go (the public entry point).
package qr
