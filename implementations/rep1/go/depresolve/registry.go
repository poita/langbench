package depresolve

import (
	"errors"
	"fmt"
	"slices"
	"sort"
)

// ErrUnsatisfiable is returned by Resolve when no resolution exists.
var ErrUnsatisfiable = errors.New("depresolve: unsatisfiable")

// Registry holds every known version of every package together with its
// requirements. The zero value is not usable; call NewRegistry.
type Registry struct {
	entries []entry
	seen    map[versionID]struct{}
	index   *index // compiled form, rebuilt lazily after Add
}

type entry struct {
	name    string
	version Version
	reqs    []Requirement
}

type versionID struct {
	name string
	key  uint64
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{seen: map[versionID]struct{}{}}
}

// Add declares a package version with its requirements (in order). It
// returns an error if the same name and version was already added. The
// requirements slice is copied.
func (r *Registry) Add(name string, v Version, reqs []Requirement) error {
	id := versionID{name, v.Key()}
	if _, dup := r.seen[id]; dup {
		return fmt.Errorf("duplicate package version %s %s", name, v)
	}
	r.seen[id] = struct{}{}
	r.entries = append(r.entries, entry{name, v, slices.Clone(reqs)})
	r.index = nil
	return nil
}

// Len returns the number of package versions in the registry.
func (r *Registry) Len() int { return len(r.entries) }

// Pick is one chosen package version.
type Pick struct {
	Name    string
	Version Version
}

// Resolution is a complete resolution, sorted by package name in ascending
// byte order.
type Resolution []Pick

// Resolve returns the first complete solution of the depth-first,
// newest-first, chronologically backtracking search over the registry for
// the given root requirements (in order). It returns ErrUnsatisfiable if the
// search fails. See SPEC.md for the exact algorithm.
func (r *Registry) Resolve(root []Requirement) (Resolution, error) {
	if r.index == nil {
		r.index = buildIndex(r.entries)
	}
	s := newSolver(r.index, root)
	picks, ok := s.run()
	if !ok {
		return nil, ErrUnsatisfiable
	}
	sort.Slice(picks, func(i, j int) bool { return picks[i].Name < picks[j].Name })
	return picks, nil
}
