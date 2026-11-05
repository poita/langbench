package gitrepo

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
)

// maxSymrefDepth is the number of symbolic refs followed before giving up.
const maxSymrefDepth = 5

type refResult struct {
	id ID
	ok bool
}

// validRefName reports whether name may be looked up on disk: it must be
// HEAD or begin with refs/, and have no empty, "." or ".." component.
func validRefName(name string) bool {
	if name != "HEAD" && !strings.HasPrefix(name, "refs/") {
		return false
	}
	for _, c := range strings.Split(name, "/") {
		if c == "" || c == "." || c == ".." {
			return false
		}
	}
	return true
}

// loadPackedRefs parses packed-refs on first use.
func (r *Repository) loadPackedRefs() {
	if r.packedRefs != nil {
		return
	}
	r.packedRefs = make(map[string]ID)
	data, err := os.ReadFile(filepath.Join(r.dir, "packed-refs"))
	if err != nil {
		return
	}
	for _, line := range bytes.Split(data, []byte{'\n'}) {
		if len(line) == 0 || line[0] == '#' || line[0] == '^' {
			continue
		}
		if len(line) < 42 || line[40] != ' ' {
			continue
		}
		id, ok := parseIDBytes(line[:40])
		if !ok {
			continue
		}
		r.packedRefs[string(line[41:])] = id
	}
}

// ResolveRef resolves a full ref name (HEAD or refs/...) to the object id it
// holds. A loose ref file wins over packed-refs; symbolic refs are followed
// up to five times. The object the id names need not exist.
func (r *Repository) ResolveRef(name string) (ID, bool) {
	return r.resolveRef(name, 0)
}

func (r *Repository) resolveRef(name string, depth int) (ID, bool) {
	if depth > maxSymrefDepth || !validRefName(name) {
		return ID{}, false
	}
	if depth == 0 {
		if res, ok := r.refCache[name]; ok {
			return res.id, res.ok
		}
	}
	id, ok := r.lookupRef(name, depth)
	if depth == 0 {
		r.refCache[name] = refResult{id, ok}
	}
	return id, ok
}

func (r *Repository) lookupRef(name string, depth int) (ID, bool) {
	path := filepath.Join(r.dir, filepath.FromSlash(name))
	if st, err := os.Stat(path); err == nil && st.Mode().IsRegular() {
		data, err := os.ReadFile(path)
		if err != nil {
			return ID{}, false
		}
		data = bytes.TrimRight(data, " \t\r\n\v\f")
		if rest, ok := bytes.CutPrefix(data, []byte("ref:")); ok {
			return r.resolveRef(string(bytes.TrimSpace(rest)), depth+1)
		}
		if len(data) == 40 {
			for _, c := range data {
				if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
					return ID{}, false
				}
			}
			return parseIDBytes(data)
		}
		return ID{}, false
	}
	r.loadPackedRefs()
	id, ok := r.packedRefs[name]
	return id, ok
}
