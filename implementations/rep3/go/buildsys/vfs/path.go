package vfs

import "strings"

// IsWorkspacePath reports whether s is a valid workspace path: one or more
// '/'-separated components of 1..255 bytes drawn from [A-Za-z0-9_.+-], none of
// which is "." or "..", with a total length of at most 1024 bytes.
func IsWorkspacePath(s string) bool {
	if len(s) == 0 || len(s) > 1024 {
		return false
	}
	start := 0
	for i := 0; i <= len(s); i++ {
		if i < len(s) && s[i] != '/' {
			if !isPathByte(s[i]) {
				return false
			}
			continue
		}
		n := i - start
		if n == 0 || n > 255 {
			return false
		}
		if c := s[start:i]; c == "." || c == ".." {
			return false
		}
		start = i + 1
	}
	return true
}

func isPathByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c == '_' || c == '.' || c == '+' || c == '-'
}

// StateFile is the workspace path of the persisted build state.
const StateFile = ".kiln-state"

// OutDir is the name of the reserved generated-output tree.
const OutDir = "out"

// IsGenerated reports whether p lies in the reserved `out` tree, i.e. its
// first component is exactly "out".
func IsGenerated(p string) bool {
	return p == OutDir || strings.HasPrefix(p, OutDir+"/")
}

// GlobEligible reports whether glob may return p: it must be neither
// generated nor the state file.
func GlobEligible(p string) bool {
	return !IsGenerated(p) && p != StateFile
}
