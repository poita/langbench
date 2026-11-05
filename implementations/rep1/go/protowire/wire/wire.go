// Package wire implements the low-level primitives of the Protocol Buffers
// wire format: varints, zigzag, fixed-width integers, tags and strict
// lowercase hex conversion.
//
// All readers are bounds-checked and return the package's static errors, so
// reporting a malformed input never allocates.
package wire

import (
	"errors"
	"math/bits"
)

// Wire types.
const (
	Varint     = 0
	Fixed64    = 1
	Bytes      = 2 // length-delimited
	StartGroup = 3
	EndGroup   = 4
	Fixed32    = 5
)

// Limits enforced by the decoder.
const (
	MaxVarintLen    = 10 // longest varint accepted
	MaxTagLen       = 5  // longest tag accepted
	MaxLenPrefixLen = 5  // longest length prefix accepted
)

var (
	// ErrTruncated reports that the input ended inside a value.
	ErrTruncated = errors.New("wire: truncated input")
	// ErrTooLong reports a varint longer than its permitted maximum.
	ErrTooLong = errors.New("wire: varint too long")
)

// ConsumeVarint reads one varint from the start of b, accepting at most
// maxLen bytes (1..MaxVarintLen). It returns the value (taken modulo 2^64)
// and the number of bytes consumed. Non-minimal encodings are accepted.
func ConsumeVarint(b []byte, maxLen int) (uint64, int, error) {
	var v uint64
	for i := 0; i < len(b) && i < maxLen; i++ {
		c := b[i]
		v |= uint64(c&0x7f) << (7 * uint(i))
		if c < 0x80 {
			return v, i + 1, nil
		}
	}
	if len(b) >= maxLen {
		return 0, 0, ErrTooLong
	}
	return 0, 0, ErrTruncated
}

// AppendVarint appends the minimal varint encoding of v to dst.
func AppendVarint(dst []byte, v uint64) []byte {
	for v >= 0x80 {
		dst = append(dst, byte(v)|0x80)
		v >>= 7
	}
	return append(dst, byte(v))
}

// SizeVarint returns the length in bytes of the minimal varint encoding of v.
func SizeVarint(v uint64) int {
	return (bits.Len64(v|1) + 6) / 7
}

// AppendFixed32 appends v as 4 little-endian bytes.
func AppendFixed32(dst []byte, v uint32) []byte {
	return append(dst, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}

// AppendFixed64 appends v as 8 little-endian bytes.
func AppendFixed64(dst []byte, v uint64) []byte {
	return append(dst, byte(v), byte(v>>8), byte(v>>16), byte(v>>24),
		byte(v>>32), byte(v>>40), byte(v>>48), byte(v>>56))
}

// ReadFixed32 reads 4 little-endian bytes; b must hold at least 4 bytes.
func ReadFixed32(b []byte) uint32 {
	_ = b[3]
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

// ReadFixed64 reads 8 little-endian bytes; b must hold at least 8 bytes.
func ReadFixed64(b []byte) uint64 {
	_ = b[7]
	return uint64(ReadFixed32(b)) | uint64(ReadFixed32(b[4:]))<<32
}

// ZigZag32 maps a signed 32-bit integer to an unsigned one so that values
// of small magnitude have short varints.
func ZigZag32(v int32) uint32 { return uint32(v<<1) ^ uint32(v>>31) }

// UnZigZag32 inverts ZigZag32.
func UnZigZag32(u uint32) int32 { return int32(u>>1) ^ -int32(u&1) }

// ZigZag64 is the 64-bit analogue of ZigZag32.
func ZigZag64(v int64) uint64 { return uint64(v<<1) ^ uint64(v>>63) }

// UnZigZag64 inverts ZigZag64.
func UnZigZag64(u uint64) int64 { return int64(u>>1) ^ -int64(u&1) }

// AppendTag appends the varint tag for a field number and wire type.
func AppendTag(dst []byte, number uint32, wireType int) []byte {
	return AppendVarint(dst, uint64(number)<<3|uint64(wireType))
}
