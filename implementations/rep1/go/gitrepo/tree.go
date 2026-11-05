package gitrepo

import (
	"bytes"
	"fmt"
	"sort"
	"strings"
)

// LookupPath resolves a slash-separated path of directory names below the
// tree id and returns the id of the tree it names. The path must be one or
// more non-empty components, none of them "." or "..".
func (r *Repository) LookupPath(tree ID, path string) (ID, error) {
	comps := strings.Split(path, "/")
	for _, c := range comps {
		if c == "" || c == "." || c == ".." {
			return ID{}, fmt.Errorf("%w: bad path %q", ErrRevision, path)
		}
	}
	cur := tree
	for _, c := range comps {
		t, err := r.Tree(cur)
		if err != nil {
			return ID{}, err
		}
		e, ok := t.Lookup([]byte(c))
		if !ok || e.Type() != TypeTree {
			return ID{}, fmt.Errorf("%w: %q is not a tree in %s", ErrNotFound, c, cur)
		}
		cur = e.ID
	}
	return cur, nil
}

// DiffStatus is the kind of change reported for a path.
type DiffStatus byte

// Diff statuses.
const (
	Added       DiffStatus = 'A'
	Deleted     DiffStatus = 'D'
	Modified    DiffStatus = 'M'
	TypeChanged DiffStatus = 'T'
)

// DiffEntry describes one changed path between two trees. For an absent side
// the mode is 0 and the id is the zero id.
type DiffEntry struct {
	Path         []byte
	OldMode      uint32
	NewMode      uint32
	OldID, NewID ID
	Status       DiffStatus
}

type flatEntry struct {
	path []byte
	mode uint32
	id   ID
}

// flatten appends every non-tree entry below the tree, with full paths.
func (r *Repository) flatten(tree ID, prefix []byte, out []flatEntry) ([]flatEntry, error) {
	t, err := r.Tree(tree)
	if err != nil {
		return nil, err
	}
	for i := range t.Entries {
		e := &t.Entries[i]
		path := make([]byte, 0, len(prefix)+len(e.Name)+1)
		path = append(append(path, prefix...), e.Name...)
		if e.Type() == TypeTree {
			path = append(path, '/')
			if out, err = r.flatten(e.ID, path, out); err != nil {
				return nil, err
			}
			continue
		}
		out = append(out, flatEntry{path, e.Mode, e.ID})
	}
	return out, nil
}

// DiffTrees compares two trees recursively and returns the changed paths
// sorted by path bytes. There is no rename or copy detection.
func (r *Repository) DiffTrees(a, b ID) ([]DiffEntry, error) {
	fa, err := r.flatten(a, nil, nil)
	if err != nil {
		return nil, err
	}
	fb, err := r.flatten(b, nil, nil)
	if err != nil {
		return nil, err
	}
	byPath := func(f []flatEntry) func(i, j int) bool {
		return func(i, j int) bool { return bytes.Compare(f[i].path, f[j].path) < 0 }
	}
	sort.SliceStable(fa, byPath(fa))
	sort.SliceStable(fb, byPath(fb))
	var out []DiffEntry
	i, j := 0, 0
	for i < len(fa) || j < len(fb) {
		switch {
		case j == len(fb) || (i < len(fa) && bytes.Compare(fa[i].path, fb[j].path) < 0):
			out = append(out, DiffEntry{Path: fa[i].path, OldMode: fa[i].mode, OldID: fa[i].id, Status: Deleted})
			i++
		case i == len(fa) || bytes.Compare(fa[i].path, fb[j].path) > 0:
			out = append(out, DiffEntry{Path: fb[j].path, NewMode: fb[j].mode, NewID: fb[j].id, Status: Added})
			j++
		default:
			x, y := fa[i], fb[j]
			if x.mode != y.mode || x.id != y.id {
				st := Modified
				if x.mode&ModeTypeMask != y.mode&ModeTypeMask {
					st = TypeChanged
				}
				out = append(out, DiffEntry{x.path, x.mode, y.mode, x.id, y.id, st})
			}
			i++
			j++
		}
	}
	return out, nil
}
