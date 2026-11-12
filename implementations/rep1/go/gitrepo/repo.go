package gitrepo

import (
	"fmt"
	"os"
	"path/filepath"

	"gitrepo/object"
	"gitrepo/odb"
)

// Repo is an opened repository: the contents of a .git directory, or a bare
// repository. Only HEAD, refs/**, packed-refs and the object database under
// objects/ are ever read.
type Repo struct {
	dir     string
	store   *odb.Store
	packed  map[string]object.ID
	commits map[object.ID]*object.CommitObject
	trees   map[object.ID][]object.TreeEntry
}

// Open opens the repository rooted at dir. It reads the pack indexes, the set
// of loose objects and packed-refs once; everything else is read on demand.
// Missing pieces (no objects, no packed-refs) are treated as empty.
func Open(dir string) (*Repo, error) {
	fi, err := os.Stat(dir)
	if err != nil {
		return nil, err
	}
	if !fi.IsDir() {
		return nil, fmt.Errorf("%s: not a directory", dir)
	}
	store, err := odb.Open(filepath.Join(dir, "objects"))
	if err != nil {
		return nil, err
	}
	r := &Repo{
		dir:     dir,
		store:   store,
		commits: map[object.ID]*object.CommitObject{},
		trees:   map[object.ID][]object.TreeEntry{},
	}
	r.loadPackedRefs()
	return r, nil
}

// Store returns the repository's object database.
func (r *Repo) Store() *odb.Store { return r.store }

// CountObjects reports the number of loose objects, packed objects and packs.
func (r *Repo) CountObjects() odb.Counts { return r.store.Counts() }

// commit reads and parses the commit with the given id.
func (r *Repo) commit(id object.ID) (*object.CommitObject, error) {
	if c, ok := r.commits[id]; ok {
		return c, nil
	}
	o, err := r.store.Read(id)
	if err != nil {
		return nil, err
	}
	if o.Type != object.Commit {
		return nil, fmt.Errorf("object %s is a %s, not a commit", id, o.Type)
	}
	c, err := object.ParseCommit(o.Data)
	if err != nil {
		return nil, fmt.Errorf("commit %s: %w", id, err)
	}
	r.commits[id] = c
	return c, nil
}

// tree reads and parses the tree with the given id.
func (r *Repo) tree(id object.ID) ([]object.TreeEntry, error) {
	if t, ok := r.trees[id]; ok {
		return t, nil
	}
	o, err := r.store.Read(id)
	if err != nil {
		return nil, err
	}
	if o.Type != object.Tree {
		return nil, fmt.Errorf("object %s is a %s, not a tree", id, o.Type)
	}
	t, err := object.ParseTree(o.Data)
	if err != nil {
		return nil, fmt.Errorf("tree %s: %w", id, err)
	}
	r.trees[id] = t
	return t, nil
}
