package depresolve

import (
	"fmt"
	"strings"
)

// Requirement says that a package must be present at a version in Range.
type Requirement struct {
	Name  string
	Range Range
}

// String formats the requirement as "name range".
func (r Requirement) String() string { return r.Name + " " + r.Range.String() }

// ParseRequirements parses a comma-separated requirement list such as
// "a ^1.0.0, b >=2.0.0 <3.0.0". The empty string yields no requirements.
func ParseRequirements(s string) ([]Requirement, error) {
	if s == "" {
		return nil, nil
	}
	var out []Requirement
	for _, item := range strings.Split(s, ", ") {
		name, rng, ok := strings.Cut(item, " ")
		if !ok || !ValidName(name) {
			return nil, fmt.Errorf("invalid requirement %q", item)
		}
		r, err := ParseRange(rng)
		if err != nil {
			return nil, err
		}
		out = append(out, Requirement{Name: name, Range: r})
	}
	return out, nil
}

// MustParseRequirements is like ParseRequirements but panics on error.
func MustParseRequirements(s string) []Requirement {
	r, err := ParseRequirements(s)
	if err != nil {
		panic(err)
	}
	return r
}

// ValidName reports whether s is a legal package name: a lowercase letter
// followed by lowercase letters, digits and hyphens.
func ValidName(s string) bool {
	if s == "" || s[0] < 'a' || s[0] > 'z' {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// packageVersion is one declared version of a package.
type packageVersion struct {
	version Version
	reqs    []Requirement
}

// Registry holds every known version of every package. The zero value is
// not usable; create registries with NewRegistry or Parse.
type Registry struct {
	names    []string // package names in first-seen order
	index    map[string]int
	versions [][]packageVersion // per package, in insertion order
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{index: make(map[string]int)}
}

// Add declares version v of package name with the given requirements. It
// returns an error if that exact name and version was already added. The
// requirements slice is retained and must not be modified afterwards.
func (g *Registry) Add(name string, v Version, reqs []Requirement) error {
	id, ok := g.index[name]
	if !ok {
		id = len(g.names)
		g.index[name] = id
		g.names = append(g.names, name)
		g.versions = append(g.versions, nil)
	}
	for _, pv := range g.versions[id] {
		if pv.version == v {
			return fmt.Errorf("duplicate package version %s %s", name, v)
		}
	}
	g.versions[id] = append(g.versions[id], packageVersion{v, reqs})
	return nil
}

// NumPackages returns the number of distinct packages declared.
func (g *Registry) NumPackages() int { return len(g.names) }
