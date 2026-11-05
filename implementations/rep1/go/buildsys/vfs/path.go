package vfs

// IsPath reports whether s is a valid workspace path: 1..1024 bytes, made of
// 1..255-byte components joined by "/", each component drawn from
// [A-Za-z0-9_.+-] and neither "." nor "..".
func IsPath(s string) bool {
	if len(s) == 0 || len(s) > 1024 {
		return false
	}
	start := 0
	for i := 0; i <= len(s); i++ {
		if i < len(s) && s[i] != '/' {
			if !isPChar(s[i]) {
				return false
			}
			continue
		}
		n := i - start
		if n == 0 || n > 255 {
			return false
		}
		if n <= 2 && s[start] == '.' && (n == 1 || s[start+1] == '.') {
			return false
		}
		start = i + 1
	}
	return true
}

func isPChar(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c == '_' || c == '.' || c == '+' || c == '-'
}

// StateFile is the workspace path of the persisted build state.
const StateFile = ".kiln-state"

// IsGenerated reports whether p lies in the reserved "out" tree, i.e. its
// first component is exactly "out".
func IsGenerated(p string) bool {
	return p == "out" || (len(p) > 3 && p[:4] == "out/")
}

// GlobEligible reports whether glob may match p: it is neither generated nor
// the state file.
func GlobEligible(p string) bool {
	return !IsGenerated(p) && p != StateFile
}
