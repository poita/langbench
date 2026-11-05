package jsoncanon

import (
	"bytes"
	"slices"
)

// handle refers to one member of an object while its members are sorted.
type handle struct {
	key []byte
	idx int // index of the member's value in Value.kids
}

// AppendCanonical appends the canonical serialization of v (without a
// trailing newline) to dst and returns the extended slice.
func (v *Value) AppendCanonical(dst []byte) []byte {
	switch v.kind {
	case Null:
		return append(dst, "null"...)
	case False:
		return append(dst, "false"...)
	case True:
		return append(dst, "true"...)
	case Number:
		return append(dst, v.text...)
	case String:
		return appendString(dst, v.text)
	case Array:
		dst = append(dst, '[')
		for i := range v.kids {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = v.kids[i].AppendCanonical(dst)
		}
		return append(dst, ']')
	}
	return v.appendObject(dst)
}

func (v *Value) appendObject(dst []byte) []byte {
	m := len(v.kids) / 2
	dst = append(dst, '{')
	switch {
	case m == 1:
		dst = appendString(dst, v.kids[0].text)
		dst = append(dst, ':')
		dst = v.kids[1].AppendCanonical(dst)
	case m > 1:
		hs := make([]handle, m)
		for i := range hs {
			hs[i] = handle{v.kids[2*i].text, 2*i + 1}
		}
		slices.SortFunc(hs, func(a, b handle) int {
			if c := compareKeys(a.key, b.key); c != 0 {
				return c
			}
			return a.idx - b.idx
		})
		first := true
		for i, h := range hs {
			// Within a run of equal keys the last one has the highest index
			// and is the one to keep.
			if i+1 < m && bytes.Equal(h.key, hs[i+1].key) {
				continue
			}
			if !first {
				dst = append(dst, ',')
			}
			first = false
			dst = appendString(dst, h.key)
			dst = append(dst, ':')
			dst = v.kids[h.idx].AppendCanonical(dst)
		}
	}
	return append(dst, '}')
}

// needsEscape marks the bytes that must be escaped in canonical strings.
var needsEscape = special

const hexDigits = "0123456789abcdef"

// appendString appends s as a quoted JSON string, escaping only '"', '\' and
// control characters. Runs of other bytes are copied in bulk.
func appendString(dst, s []byte) []byte {
	dst = append(dst, '"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !needsEscape[c] {
			continue
		}
		dst = append(dst, s[start:i]...)
		start = i + 1
		switch c {
		case '"':
			dst = append(dst, '\\', '"')
		case '\\':
			dst = append(dst, '\\', '\\')
		case '\b':
			dst = append(dst, '\\', 'b')
		case '\f':
			dst = append(dst, '\\', 'f')
		case '\n':
			dst = append(dst, '\\', 'n')
		case '\r':
			dst = append(dst, '\\', 'r')
		case '\t':
			dst = append(dst, '\\', 't')
		default:
			dst = append(dst, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&15])
		}
	}
	dst = append(dst, s[start:]...)
	return append(dst, '"')
}
