package scheme

import "strconv"

// Write returns the write form of v: strings are quoted and escaped.
func Write(v Value) string { return string(appendValue(nil, v, false)) }

// Display returns the display form of v: strings appear raw, at any depth.
func Display(v Value) string { return string(appendValue(nil, v, true)) }

func appendValue(dst []byte, v Value, display bool) []byte {
	switch v := v.(type) {
	case Int:
		return strconv.AppendInt(dst, int64(v), 10)
	case *Big:
		return append(dst, v.N.String()...)
	case Bool:
		if v {
			return append(dst, "#t"...)
		}
		return append(dst, "#f"...)
	case *String:
		if display {
			return append(dst, v.S...)
		}
		dst = append(dst, '"')
		for i := 0; i < len(v.S); i++ {
			switch c := v.S[i]; c {
			case '\\':
				dst = append(dst, '\\', '\\')
			case '"':
				dst = append(dst, '\\', '"')
			case '\n':
				dst = append(dst, '\\', 'n')
			case '\t':
				dst = append(dst, '\\', 't')
			default:
				dst = append(dst, c)
			}
		}
		return append(dst, '"')
	case *Symbol:
		return append(dst, v.Name...)
	case Null:
		return append(dst, "()"...)
	case Void:
		return append(dst, "#<void>"...)
	case *Pair:
		dst = append(dst, '(')
		var cur Value = v
		first := true
		for {
			p, ok := cur.(*Pair)
			if !ok {
				break
			}
			if !first {
				dst = append(dst, ' ')
			}
			first = false
			dst = appendValue(dst, p.Car, display)
			cur = p.Cdr
		}
		if _, ok := cur.(Null); !ok {
			dst = append(dst, " . "...)
			dst = appendValue(dst, cur, display)
		}
		return append(dst, ')')
	case *Primitive, *Closure:
		return append(dst, "#<procedure>"...)
	}
	return append(dst, "#<unknown>"...)
}
