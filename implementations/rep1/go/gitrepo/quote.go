package gitrepo

import "strconv"

// QuotePath formats a path name the way git does by default: unchanged when
// every byte is printable ASCII other than '"' and '\', otherwise wrapped in
// double quotes with C-style escapes and three-digit octal for other bytes.
func QuotePath(name []byte) []byte {
	plain := true
	for _, c := range name {
		if c < 0x20 || c > 0x7e || c == '"' || c == '\\' {
			plain = false
			break
		}
	}
	if plain {
		return name
	}
	out := make([]byte, 0, len(name)+8)
	out = append(out, '"')
	for _, c := range name {
		switch c {
		case 7:
			out = append(out, '\\', 'a')
		case 8:
			out = append(out, '\\', 'b')
		case 9:
			out = append(out, '\\', 't')
		case 10:
			out = append(out, '\\', 'n')
		case 11:
			out = append(out, '\\', 'v')
		case 12:
			out = append(out, '\\', 'f')
		case 13:
			out = append(out, '\\', 'r')
		case '"':
			out = append(out, '\\', '"')
		case '\\':
			out = append(out, '\\', '\\')
		default:
			if c < 0x20 || c >= 0x7f {
				o := strconv.FormatUint(uint64(c), 8)
				out = append(out, '\\')
				for k := len(o); k < 3; k++ {
					out = append(out, '0')
				}
				out = append(out, o...)
			} else {
				out = append(out, c)
			}
		}
	}
	return append(out, '"')
}
