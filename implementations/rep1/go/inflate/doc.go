// Package inflate is a from-scratch decoder for raw DEFLATE streams
// (RFC 1951).
//
// It decodes a complete in-memory stream in a single pass using
// table-driven Huffman decoding: every literal/length and distance symbol is
// resolved with one or two table lookups (a root table plus second-level
// tables for the longest codes), never bit by bit.
//
// The decoder is strict. Besides the usual structural errors it rejects
// over-subscribed and incomplete code-length sets (apart from the single-code
// and empty-distance-code exceptions that zlib also accepts), back-references
// that reach before the start of the output, truncated input, and whole bytes
// left over after the final block. Every failure is reported as one of the
// sentinel errors declared in this package.
//
// Basic use:
//
//	out, err := inflate.Decode(compressed)
//
// A Decoder may be reused to amortise table allocations across many streams.
package inflate
