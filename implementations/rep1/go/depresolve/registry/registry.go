// Package registry holds a package registry (every known version of every
// package together with its requirements) and parses the textual input format
// understood by the depresolve command.
package registry

import (
	"fmt"
	"sort"

	"depresolve/semver"
)

// Requirement says that some package must be present at a version in Range.
type Requirement struct {
	Package string
	Range   semver.Range
}

// Release is one version of a package with its dependency requirements, in
// declaration order (the order is significant to the resolver).
type Release struct {
	Version  semver.Version
	Requires []Requirement
}

// Registry is a collection of packages. The zero value is not usable; call New.
type Registry struct {
	pkgs  map[string]*entry
	order []string // package names in first-seen order
}

type entry struct {
	releases []Release
	sorted   bool // releases are ordered newest first
}

// New returns an empty registry.
func New() *Registry {
	return &Registry{pkgs: make(map[string]*entry)}
}

// Add declares a release of a package. Declaring the same name and version
// twice is a mistake that Validate reports.
func (r *Registry) Add(name string, v semver.Version, requires []Requirement) {
	e := r.pkgs[name]
	if e == nil {
		e = &entry{sorted: true}
		r.pkgs[name] = e
		r.order = append(r.order, name)
	}
	if e.sorted && len(e.releases) > 0 && !v.Less(e.releases[len(e.releases)-1].Version) {
		e.sorted = false
	}
	e.releases = append(e.releases, Release{Version: v, Requires: requires})
}

// Packages returns the names of all packages that have at least one release,
// in the order they were first added. The slice must not be modified.
func (r *Registry) Packages() []string { return r.order }

// Releases returns all releases of the named package ordered from newest to
// oldest, or nil if the package is unknown. The slice is owned by the
// registry and must not be modified.
func (r *Registry) Releases(name string) []Release {
	e := r.pkgs[name]
	if e == nil {
		return nil
	}
	if !e.sorted {
		sort.Slice(e.releases, func(i, j int) bool {
			return e.releases[j].Version.Less(e.releases[i].Version)
		})
		e.sorted = true
	}
	return e.releases
}

// Validate reports an error if any package declares the same version twice.
func (r *Registry) Validate() error {
	for _, name := range r.order {
		rel := r.Releases(name)
		for i := 1; i < len(rel); i++ {
			if rel[i].Version == rel[i-1].Version {
				return fmt.Errorf("registry: duplicate release %s %s", name, rel[i].Version)
			}
		}
	}
	return nil
}
