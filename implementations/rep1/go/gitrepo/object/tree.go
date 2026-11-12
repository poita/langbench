package object

import "bytes"

// Mode bits of a tree entry.
const (
	ModeTypeMask uint32 = 0o170000
	ModeTree     uint32 = 0o040000
	ModeCommit   uint32 = 0o160000 // gitlink (submodule)
)

// TreeEntry is one entry of a tree.
type TreeEntry struct {
	Mode uint32
	Name []byte
	ID   ID
}

// Type returns the object type the entry points at, decided by the mode's
// high bits: a tree, a commit (gitlink) or otherwise a blob.
func (e TreeEntry) Type() Type {
	switch e.Mode & ModeTypeMask {
	case ModeTree:
		return Tree
	case ModeCommit:
		return Commit
	}
	return Blob
}

// ParseTree parses a tree payload into its entries, in stored order. The
// returned names alias data.
func ParseTree(data []byte) ([]TreeEntry, error) {
	var entries []TreeEntry
	for len(data) > 0 {
		sp := bytes.IndexByte(data, ' ')
		if sp <= 0 {
			return nil, malformed("tree entry without mode")
		}
		var mode uint32
		for _, c := range data[:sp] {
			if c < '0' || c > '7' || mode > 1<<28 {
				return nil, malformed("bad tree entry mode %q", data[:sp])
			}
			mode = mode<<3 | uint32(c-'0')
		}
		data = data[sp+1:]
		nul := bytes.IndexByte(data, 0)
		if nul <= 0 {
			return nil, malformed("tree entry with empty or unterminated name")
		}
		name := data[:nul]
		data = data[nul+1:]
		if len(data) < IDSize {
			return nil, malformed("truncated tree entry id")
		}
		e := TreeEntry{Mode: mode, Name: name}
		copy(e.ID[:], data[:IDSize])
		data = data[IDSize:]
		entries = append(entries, e)
	}
	return entries, nil
}
