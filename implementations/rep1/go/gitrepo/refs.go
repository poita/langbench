package gitrepo

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"gitrepo/object"
)

// ErrRefNotFound means a name does not resolve to a ref.
var ErrRefNotFound = errors.New("ref not found")

// maxSymrefDepth is how many symbolic refs are followed before giving up.
const maxSymrefDepth = 5

func (r *Repo) loadPackedRefs() {
	r.packed = map[string]object.ID{}
	data, err := os.ReadFile(filepath.Join(r.dir, "packed-refs"))
	if err != nil {
		return
	}
	for _, line := range bytes.Split(data, []byte("\n")) {
		if len(line) == 0 || line[0] == '#' || line[0] == '^' {
			continue
		}
		if len(line) < 42 || line[40] != ' ' {
			continue
		}
		id, ok := parseRefID(line[:40])
		if !ok {
			continue
		}
		r.packed[string(line[41:])] = id
	}
}

// parseRefID accepts exactly 40 lowercase hexadecimal digits.
func parseRefID(b []byte) (object.ID, bool) {
	var id object.ID
	if len(b) != 40 {
		return id, false
	}
	for _, c := range b {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return id, false
		}
	}
	id, err := object.ParseID(string(b))
	return id, err == nil
}

// validRefName reports whether name may be looked up as a ref: HEAD or a name
// under refs/, with no empty, "." or ".." component.
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

// ReadRef resolves the ref called name (for example "HEAD" or
// "refs/heads/main") to the object id it holds. The loose file repo/<name>
// wins over a packed-refs entry; symbolic refs ("ref: <name>") are followed at
// most five times. The id is taken at face value: the object need not exist.
// A name that is not a ref yields an error wrapping ErrRefNotFound.
func (r *Repo) ReadRef(name string) (object.ID, error) {
	return r.readRef(name, 0)
}

func (r *Repo) readRef(name string, depth int) (object.ID, error) {
	var zero object.ID
	if !validRefName(name) {
		return zero, ErrRefNotFound
	}
	data, err := os.ReadFile(filepath.Join(r.dir, filepath.FromSlash(name)))
	if err != nil {
		if id, ok := r.packed[name]; ok {
			return id, nil
		}
		return zero, ErrRefNotFound
	}
	data = bytes.TrimRight(data, " \t\r\n\v\f")
	if target, ok := bytes.CutPrefix(data, []byte("ref: ")); ok {
		if depth >= maxSymrefDepth {
			return zero, ErrRefNotFound
		}
		return r.readRef(string(target), depth+1)
	}
	if id, ok := parseRefID(data); ok {
		return id, nil
	}
	return zero, ErrRefNotFound
}
