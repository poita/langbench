package gitrepo

import (
	"bytes"
	"container/heap"
	"fmt"
	"sort"
	"strings"

	"gitrepo/object"
)

// ---- log ----

// LogEntry is one commit of a history walk.
type LogEntry struct {
	ID         object.ID
	Author     []byte // author name, raw bytes
	AuthorTime uint64 // author timestamp, seconds
	Subject    []byte // see object.Subject
}

type walkItem struct {
	id   object.ID
	date uint64
	seq  int
}

type walkQueue []walkItem

func (q walkQueue) Len() int { return len(q) }
func (q walkQueue) Less(i, j int) bool {
	if q[i].date != q[j].date {
		return q[i].date > q[j].date
	}
	return q[i].seq < q[j].seq
}
func (q walkQueue) Swap(i, j int) { q[i], q[j] = q[j], q[i] }
func (q *walkQueue) Push(x any)   { *q = append(*q, x.(walkItem)) }
func (q *walkQueue) Pop() any {
	old := *q
	it := old[len(old)-1]
	*q = old[:len(old)-1]
	return it
}

// Log walks history from rev, peeled to a commit, in reverse chronological
// order of committer date (ties go to the commit discovered first), and
// returns at most limit entries. A negative limit means no limit. It fails if
// the walk reaches a commit that is missing or damaged.
func (r *Repo) Log(rev string, limit int) ([]LogEntry, error) {
	id, err := r.RevParse(rev)
	if err != nil {
		return nil, err
	}
	if id, err = r.peel(id, object.Commit); err != nil {
		return nil, err
	}
	start, err := r.commit(id)
	if err != nil {
		return nil, err
	}
	var out []LogEntry
	if limit == 0 {
		return out, nil
	}
	seen := map[object.ID]bool{id: true}
	seq := 0
	q := &walkQueue{{id, start.Committer.When, seq}}
	for q.Len() > 0 {
		it := heap.Pop(q).(walkItem)
		c, err := r.commit(it.id)
		if err != nil {
			return nil, err
		}
		out = append(out, LogEntry{it.id, c.Author.Name, c.Author.When, c.Subject()})
		if limit > 0 && len(out) >= limit {
			break
		}
		for _, p := range c.Parents {
			if seen[p] {
				continue
			}
			seen[p] = true
			pc, err := r.commit(p)
			if err != nil {
				return nil, err
			}
			seq++
			heap.Push(q, walkItem{p, pc.Committer.When, seq})
		}
	}
	return out, nil
}

// ---- ls-tree ----

// LsTree returns the entries, in stored order, of the tree that rev peels to,
// or of the subtree at path when path is not empty. path is names separated
// by single slashes, with no empty, "." or ".." component.
func (r *Repo) LsTree(rev, path string) ([]object.TreeEntry, error) {
	var comps []string
	if path != "" {
		comps = strings.Split(path, "/")
		for _, c := range comps {
			if c == "" || c == "." || c == ".." {
				return nil, fmt.Errorf("bad path %q", path)
			}
		}
	}
	id, err := r.peelRev(rev, object.Tree)
	if err != nil {
		return nil, err
	}
	for _, c := range comps {
		entries, err := r.tree(id)
		if err != nil {
			return nil, err
		}
		found := false
		for _, e := range entries {
			if string(e.Name) == c {
				if e.Type() != object.Tree {
					return nil, fmt.Errorf("%q is not a tree", c)
				}
				id, found = e.ID, true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("no entry %q", c)
		}
	}
	return r.tree(id)
}

func (r *Repo) peelRev(rev string, want object.Type) (object.ID, error) {
	id, err := r.RevParse(rev)
	if err != nil {
		return id, err
	}
	return r.peel(id, want)
}

// ---- cat-file ----

// CatFile resolves rev to an object, reads it and verifies that the SHA-1 of
// its stored form equals its id.
func (r *Repo) CatFile(rev string) (*object.Object, error) {
	id, err := r.RevParse(rev)
	if err != nil {
		return nil, err
	}
	o, err := r.store.Read(id)
	if err != nil {
		return nil, err
	}
	if o.ID() != id {
		return nil, fmt.Errorf("object %s: hash mismatch", id)
	}
	return o, nil
}

// ---- diff ----

// DiffEntry is one changed path between two trees.
type DiffEntry struct {
	Path             []byte
	OldMode, NewMode uint32 // 0 when the path is absent on that side
	OldID, NewID     object.ID
	Status           byte // 'A', 'D', 'M' or 'T'
}

type flatEntry struct {
	path []byte
	mode uint32
	id   object.ID
}

func (r *Repo) flatten(id object.ID, prefix []byte, out *[]flatEntry) error {
	entries, err := r.tree(id)
	if err != nil {
		return err
	}
	for _, e := range entries {
		path := make([]byte, 0, len(prefix)+len(e.Name)+1)
		path = append(append(path, prefix...), e.Name...)
		if e.Type() == object.Tree {
			if err := r.flatten(e.ID, append(path, '/'), out); err != nil {
				return err
			}
			continue
		}
		*out = append(*out, flatEntry{path, e.Mode, e.ID})
	}
	return nil
}

func (r *Repo) flatTree(rev string) ([]flatEntry, error) {
	id, err := r.peelRev(rev, object.Tree)
	if err != nil {
		return nil, err
	}
	var out []flatEntry
	if err := r.flatten(id, nil, &out); err != nil {
		return nil, err
	}
	sort.SliceStable(out, func(i, j int) bool { return bytes.Compare(out[i].path, out[j].path) < 0 })
	return out, nil
}

// Diff compares the trees rev1 and rev2 peel to, recursively and without
// rename detection, and returns the changed paths sorted by path bytes.
func (r *Repo) Diff(rev1, rev2 string) ([]DiffEntry, error) {
	a, err := r.flatTree(rev1)
	if err != nil {
		return nil, err
	}
	b, err := r.flatTree(rev2)
	if err != nil {
		return nil, err
	}
	var out []DiffEntry
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		var cmp int
		switch {
		case i >= len(a):
			cmp = 1
		case j >= len(b):
			cmp = -1
		default:
			cmp = bytes.Compare(a[i].path, b[j].path)
		}
		switch {
		case cmp < 0:
			out = append(out, DiffEntry{Path: a[i].path, OldMode: a[i].mode, OldID: a[i].id, Status: 'D'})
			i++
		case cmp > 0:
			out = append(out, DiffEntry{Path: b[j].path, NewMode: b[j].mode, NewID: b[j].id, Status: 'A'})
			j++
		default:
			x, y := a[i], b[j]
			if x.mode != y.mode || x.id != y.id {
				st := byte('M')
				if x.mode&object.ModeTypeMask != y.mode&object.ModeTypeMask {
					st = 'T'
				}
				out = append(out, DiffEntry{x.path, x.mode, y.mode, x.id, y.id, st})
			}
			i++
			j++
		}
	}
	return out, nil
}
