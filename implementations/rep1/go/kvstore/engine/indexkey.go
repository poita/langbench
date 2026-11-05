package engine

import (
	"encoding/binary"

	"example.com/kvstore/value"
)

// Index key tags.
const (
	vkNull   = 0x10
	vkFalse  = 0x20
	vkTrue   = 0x21
	vkInt    = 0x30
	vkString = 0x40
)

// valueKey appends the order-preserving encoding of a scalar value to dst. It
// reports false for lists and objects, which have none.
func valueKey(dst []byte, v value.Value) ([]byte, bool) {
	switch v.Kind {
	case value.Null:
		return append(dst, vkNull), true
	case value.Bool:
		if v.Bool {
			return append(dst, vkTrue), true
		}
		return append(dst, vkFalse), true
	case value.Int:
		dst = append(dst, vkInt)
		return binary.BigEndian.AppendUint64(dst, uint64(v.Int)^(1<<63)), true
	case value.String:
		dst = append(dst, vkString)
		for i := 0; i < len(v.Str); i++ {
			dst = append(dst, v.Str[i])
			if v.Str[i] == 0 {
				dst = append(dst, 0xFF)
			}
		}
		return append(dst, 0, 0), true
	}
	return dst, false
}

// valueKeyLen returns the length of the value key at the start of b.
func valueKeyLen(b []byte) int {
	switch b[0] {
	case vkInt:
		return 9
	case vkString:
		for i := 1; i+1 < len(b); i++ {
			if b[i] == 0 {
				if b[i+1] == 0xFF {
					i++
					continue
				}
				return i + 2
			}
		}
		return len(b)
	}
	return 1
}

// entryKey computes the index key of document doc (stored under docKey) for
// the indexed path. ok is false when the document is not indexable there.
func entryKey(doc value.Value, path value.Path, docKey []byte) (key []byte, ok bool) {
	v, found := doc.Lookup(path)
	if !found {
		return nil, false
	}
	k, ok := valueKey(nil, v)
	if !ok {
		return nil, false
	}
	return append(k, docKey...), true
}
