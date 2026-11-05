// Package inflate implements a decoder for raw DEFLATE streams (RFC 1951).
//
// The decoder is table driven: Huffman codes are expanded into two-level
// lookup tables, bits are served from a 64-bit LSB-first bit buffer, and the
// whole output doubles as the back-reference window. It is deliberately
// strict: it rejects every malformation that zlib rejects (invalid block
// types, bad stored-block lengths, over-subscribed or incomplete Huffman
// codes, distances that reach before the start of the output, truncated
// streams) and, unlike most decompressors, also rejects whole bytes left
// over after the final block.
//
// The package does not understand the zlib (RFC 1950) or gzip (RFC 1952)
// wrappers; strip them before calling Decode.
//
// Basic use:
//
//	out, err := inflate.Decode(compressed)
//	if errors.Is(err, inflate.ErrTruncated) {
//		// ...
//	}
//
// To decode many streams, create a Decoder once and reuse it so that its
// Huffman table buffers are recycled.
package inflate
