package jsoncanon

import "slices"

// Canonicalize parses data and returns its canonical serialization (without a
// trailing newline). See the package documentation for the canonical form.
func Canonicalize(data []byte) ([]byte, error) {
	v, err := Parse(data)
	if err != nil {
		return nil, err
	}
	return v.AppendCanonical(make([]byte, 0, len(data))), nil
}

// AppendCanonical appends the canonical serialization of v to dst and returns
// the extended slice. The tree is written in one pass into dst; no
// intermediate text is built per subtree.
//
// In objects, members are ordered by [CompareKeys] on their keys (stable), and
// of each run of equal keys only the last member is written. The tree itself
// is not modified.
func (v *Value) AppendCanonical(dst []byte) []byte {
	switch v.Kind {
	case Null:
		return append(dst, "null"...)
	case Bool:
		if v.Bool {
			return append(dst, "true"...)
		}
		return append(dst, "false"...)
	case Number:
		return append(dst, v.Text...)
	case String:
		return appendString(dst, v.Text)
	case Array:
		dst = append(dst, '[')
		for i := range v.Elems {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst = v.Elems[i].AppendCanonical(dst)
		}
		return append(dst, ']')
	case Object:
		return appendObject(dst, v.Members)
	}
	return dst
}

func appendObject(dst []byte, members []Member) []byte {
	dst = append(dst, '{')
	// Sort indices rather than members, to keep the sort cheap and leave the
	// tree untouched.
	idx := make([]int32, len(members))
	for i := range idx {
		idx[i] = int32(i)
	}
	slices.SortStableFunc(idx, func(a, b int32) int {
		return CompareKeys(members[a].Key, members[b].Key)
	})
	first := true
	for i := 0; i < len(idx); i++ {
		// Last member of each run of equal keys.
		if i+1 < len(idx) && members[idx[i]].Key == members[idx[i+1]].Key {
			continue
		}
		m := &members[idx[i]]
		if !first {
			dst = append(dst, ',')
		}
		first = false
		dst = appendString(dst, m.Key)
		dst = append(dst, ':')
		dst = m.Value.AppendCanonical(dst)
	}
	return append(dst, '}')
}

const hexDigits = "0123456789abcdef"

// appendString appends s as a quoted JSON string, escaping only '"', '\' and
// U+0000–U+001F.
func appendString(dst []byte, s string) []byte {
	dst = append(dst, '"')
	start := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' {
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
			dst = append(dst, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&0xF])
		}
	}
	dst = append(dst, s[start:]...)
	return append(dst, '"')
}
