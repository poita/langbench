package commands

import (
	"bytes"

	"example.com/webhooks/signature"
)

// Limits from the protocol grammar.
const (
	maxSecretLen   = 512
	maxSecrets     = 16
	maxIDLen       = 256
	maxVerifyTsLen = 64
	maxNameLen     = 64
	maxFilterTypes = 16
	maxScript      = 64
	maxEndpoints   = 64
	maxEvents      = 20000
)

// splitFields splits line on single spaces into dst[:0], reusing its storage.
// Adjacent, leading and trailing spaces yield empty fields.
func splitFields(dst [][]byte, line []byte) [][]byte {
	dst = dst[:0]
	for {
		i := bytes.IndexByte(line, ' ')
		if i < 0 {
			return append(dst, line)
		}
		dst = append(dst, line[:i])
		line = line[i+1:]
	}
}

func hasEmpty(fields [][]byte) bool {
	for _, f := range fields {
		if len(f) == 0 {
			return true
		}
	}
	return false
}

func isBlank(line []byte) bool {
	for _, c := range line {
		if c != ' ' {
			return false
		}
	}
	return true
}

func printable(c byte) bool { return c >= 0x21 && c <= 0x7e }

// isToken reports whether f is 1..max printable ASCII characters.
func isToken(f []byte, max int) bool {
	if len(f) == 0 || len(f) > max {
		return false
	}
	for _, c := range f {
		if !printable(c) {
			return false
		}
	}
	return true
}

func isNameChar(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c == '_' || c == '.' || c == '-'
}

// isName reports whether f is 1..64 characters from [A-Za-z0-9_.-].
func isName(f []byte) bool {
	if len(f) == 0 || len(f) > maxNameLen {
		return false
	}
	for _, c := range f {
		if !isNameChar(c) {
			return false
		}
	}
	return true
}

// parseInt parses a canonical <int> field.
func parseInt(f []byte) (int64, bool) {
	if len(f) > 17 {
		return 0, false
	}
	return signature.ParseTimestamp(string(f))
}

// parseSecrets parses a <secrets> field: 1..16 comma-separated valid secrets.
func parseSecrets(f []byte) ([]*signature.Secret, bool) {
	var out []*signature.Secret
	for {
		entry := f
		i := bytes.IndexByte(f, ',')
		if i >= 0 {
			entry = f[:i]
		}
		if !isToken(entry, maxSecretLen) || len(out) == maxSecrets {
			return nil, false
		}
		s, err := signature.ParseSecret(string(entry))
		if err != nil {
			return nil, false
		}
		out = append(out, s)
		if i < 0 {
			return out, true
		}
		f = f[i+1:]
	}
}
