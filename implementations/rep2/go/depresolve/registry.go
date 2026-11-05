package depresolve

import "fmt"

// Requirement says that the package Name must be present in the resolution
// at a version accepted by Range.
type Requirement struct {
	Name  string
	Range Range
}

// String formats the requirement as "name range".
func (r Requirement) String() string { return r.Name + " " + r.Range.String() }

// Registry holds every known version of every package together with the
// requirements of each version. Package names are interned to dense integer
// ids and all requirements live in one flat array, so the resolver works on
// integers only. The zero Registry is not usable; call NewRegistry.
//
// A Registry may be resolved against any number of times, but it must not be
// modified concurrently with Resolve.
type Registry struct {
	ids  map[string]int32 // name -> package id
	pkgs []pkgInfo
	reqs []regReq // all requirements of all versions, in Add order
	seen map[verID]struct{}
}

type pkgInfo struct {
	name     string
	versions []verInfo // in Add order
}

type verInfo struct {
	version  Version
	key      Key
	reqStart int32 // slice of Registry.reqs
	reqCount int32
}

type regReq struct {
	pkg int32
	rng Range
}

type verID struct {
	pkg int32
	key Key
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{ids: make(map[string]int32), seen: make(map[verID]struct{})}
}

func (r *Registry) intern(name string) int32 {
	if id, ok := r.ids[name]; ok {
		return id
	}
	id := int32(len(r.pkgs))
	r.ids[name] = id
	r.pkgs = append(r.pkgs, pkgInfo{name: name})
	return id
}

// Add declares that package name has a version v with the given requirements.
// The requirements are copied. Versions of a package may be added in any
// order. Adding the same name and version twice is an error.
func (r *Registry) Add(name string, v Version, reqs []Requirement) error {
	id := r.intern(name)
	vid := verID{id, v.Key()}
	if _, dup := r.seen[vid]; dup {
		return fmt.Errorf("duplicate package version %s %s", name, v)
	}
	r.seen[vid] = struct{}{}
	start := int32(len(r.reqs))
	for _, q := range reqs {
		r.reqs = append(r.reqs, regReq{r.intern(q.Name), q.Range})
	}
	p := &r.pkgs[id]
	p.versions = append(p.versions, verInfo{v, vid.key, start, int32(len(reqs))})
	return nil
}

// NumPackages returns the number of distinct package names the registry
// knows, including names that are only mentioned in requirements.
func (r *Registry) NumPackages() int { return len(r.pkgs) }

// Versions returns the versions of the named package, newest first. It
// returns nil if the package has no versions.
func (r *Registry) Versions(name string) []Version {
	id, ok := r.ids[name]
	if !ok {
		return nil
	}
	src := r.pkgs[id].versions
	out := make([]Version, len(src))
	for i, vi := range src {
		out[i] = vi.version
	}
	sortVersionsDesc(out)
	return out
}

// Requirements returns the requirements of a package version, in the order
// they were added, and whether that version exists.
func (r *Registry) Requirements(name string, v Version) ([]Requirement, bool) {
	id, ok := r.ids[name]
	if !ok {
		return nil, false
	}
	for _, vi := range r.pkgs[id].versions {
		if vi.key == v.Key() {
			out := make([]Requirement, vi.reqCount)
			for i := range out {
				q := r.reqs[int(vi.reqStart)+i]
				out[i] = Requirement{r.pkgs[q.pkg].name, q.rng}
			}
			return out, true
		}
	}
	return nil, false
}
