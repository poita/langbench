package vfs

// ValidPath reports whether s is a workspace path: one to 1024 bytes made of
// "/"-separated components of 1..255 bytes from [A-Za-z0-9_.+-], none of
// which is "." or "..".
func ValidPath(s string) bool {
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

// FirstComponent returns the text of p before its first "/" (all of p when
// it has no "/").
func FirstComponent(p string) string {
	for i := 0; i < len(p); i++ {
		if p[i] == '/' {
			return p[:i]
		}
	}
	return p
}

// StatePath is the workspace path of the persisted build state.
const StatePath = ".kiln-state"

// IsGenerated reports whether p lies in the reserved "out" tree.
func IsGenerated(p string) bool { return FirstComponent(p) == "out" }

// GlobEligible reports whether glob may ever match p.
func GlobEligible(p string) bool { return !IsGenerated(p) && p != StatePath }

// IsIdent reports whether s has the shape [A-Za-z_][A-Za-z0-9_]*.
func IsIdent(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || i > 0 && c >= '0' && c <= '9' {
			continue
		}
		return false
	}
	return true
}
