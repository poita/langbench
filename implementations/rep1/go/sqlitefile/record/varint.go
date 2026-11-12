// Package record decodes SQLite varints and the record format used for table
// rows and index entries.
package record

import "errors"

// ErrTruncated is returned when input ends in the middle of an encoded item.
var ErrTruncated = errors.New("record: truncated data")

// Varint decodes a SQLite varint (1 to 9 bytes, big-endian groups of 7 bits,
// with all 8 bits of a ninth byte) from the start of b. It returns the signed
// 64-bit value and the number of bytes consumed, or n == 0 if b is too short.
func Varint(b []byte) (v int64, n int) {
	var u uint64
	for i := 0; i < 8; i++ {
		if i >= len(b) {
			return 0, 0
		}
		u = u<<7 | uint64(b[i]&0x7f)
		if b[i]&0x80 == 0 {
			return int64(u), i + 1
		}
	}
	if len(b) < 9 {
		return 0, 0
	}
	u = u<<8 | uint64(b[8])
	return int64(u), 9
}

// PutVarint appends the varint encoding of v to dst.
func PutVarint(dst []byte, v int64) []byte {
	u := uint64(v)
	if u>>56 != 0 {
		// Nine-byte form: the low 8 bits go in the last byte untouched.
		var buf [9]byte
		buf[8] = byte(u)
		u >>= 8
		for i := 7; i >= 0; i-- {
			buf[i] = byte(u&0x7f) | 0x80
			u >>= 7
		}
		return append(dst, buf[:]...)
	}
	var buf [9]byte
	i := 8
	buf[i] = byte(u & 0x7f)
	u >>= 7
	for u != 0 {
		i--
		buf[i] = byte(u&0x7f) | 0x80
		u >>= 7
	}
	return append(dst, buf[i:]...)
}
