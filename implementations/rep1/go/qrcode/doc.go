// Package qrcode encodes text as QR Code Model 2 symbols (ISO/IEC 18004).
//
// The package is organised by responsibility:
//
//   - segment.go: mode selection and data bit-stream construction
//   - tables.go: capacity, error-correction and alignment tables
//   - codewords.go: padding, Reed-Solomon coding and block interleaving
//   - matrix.go: function patterns, format/version information, data placement
//   - mask.go: mask patterns and the automatic-mask penalty score
//   - qrcode.go: the public API tying the stages together
//
// A minimal use:
//
//	sym, err := qrcode.Encode("HELLO WORLD", qrcode.M, qrcode.AutoMask)
//	if err != nil {
//		log.Fatal(err)
//	}
//	fmt.Print(sym) // '#' and '.' rows
//
// The text is treated as a byte string. Numeric, alphanumeric or byte mode is
// chosen automatically, a single segment is emitted, and no ECI header is
// written.
package qrcode
