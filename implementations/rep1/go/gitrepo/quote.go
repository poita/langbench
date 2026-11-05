package gitrepo

// AppendQuoted appends name to dst using git's default path quoting: the
// name is written as-is when every byte is printable ASCII other than '"'
// and '\\'; otherwise it is wrapped in double quotes with C-style escapes
// and three-digit octal for other bytes.
func AppendQuoted(dst, name []byte) []byte {
	plain := true
	for _, c := range name {
		if c < 0x20 || c > 0x7e || c == '"' || c == '\\' {
			plain = false
			break
		}
	}
	if plain {
		return append(dst, name...)
	}
	dst = append(dst, '"')
	for _, c := range name {
		switch {
		case c >= 7 && c <= 13:
			dst = append(dst, '\\', "abtnvfr"[c-7])
		case c == '"' || c == '\\':
			dst = append(dst, '\\', c)
		case c < 0x20 || c >= 0x7f:
			dst = append(dst, '\\', '0'+c>>6, '0'+(c>>3)&7, '0'+c&7)
		default:
			dst = append(dst, c)
		}
	}
	return append(dst, '"')
}
