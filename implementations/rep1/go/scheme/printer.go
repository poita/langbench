package scheme

import "strconv"

// String returns the write form of v (strings quoted and escaped).
func (v Value) String() string { return string(appendValue(nil, v, false)) }

// Display returns the display form of v (strings raw, at any depth).
func (v Value) Display() string { return string(appendValue(nil, v, true)) }

// appendValue appends the write (display == false) or display form of v to b.
// Lists are walked iteratively along the cdr chain; only cars recurse.
func appendValue(b []byte, v Value, display bool) []byte {
	switch v.t {
	case tFix:
		return strconv.AppendInt(b, v.n, 10)
	case tBig:
		return append(b, toBig(v).String()...)
	case tBool:
		if v.n != 0 {
			return append(b, "#t"...)
		}
		return append(b, "#f"...)
	case tNil:
		return append(b, "()"...)
	case tVoid:
		return append(b, "#<void>"...)
	case tSym:
		return append(b, v.symName()...)
	case tStr:
		if display {
			return append(b, v.str()...)
		}
		return appendQuoted(b, v.str())
	case tPrim, tClosure:
		return append(b, "#<procedure>"...)
	case tPair:
		b = append(b, '(')
		for {
			p := v.pair()
			b = appendValue(b, p.car, display)
			v = p.cdr
			if v.t == tPair {
				b = append(b, ' ')
				continue
			}
			if v.t != tNil {
				b = append(b, " . "...)
				b = appendValue(b, v, display)
			}
			break
		}
		return append(b, ')')
	}
	return append(b, "#<unknown>"...)
}

func appendQuoted(b []byte, s string) []byte {
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		switch c := s[i]; c {
		case '\\':
			b = append(b, '\\', '\\')
		case '"':
			b = append(b, '\\', '"')
		case '\n':
			b = append(b, '\\', 'n')
		case '\t':
			b = append(b, '\\', 't')
		default:
			b = append(b, c)
		}
	}
	return append(b, '"')
}
