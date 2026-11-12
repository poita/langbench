package depresolve

import (
	"errors"
	"sort"
)

// ErrUnsatisfiable is returned by Resolve when the search space contains no
// complete resolution.
var ErrUnsatisfiable = errors.New("depresolve: unsatisfiable")

// Package is a package pinned to one version.
type Package struct {
	Name    string
	Version Version
}

// Resolution is the set of chosen packages, sorted by name in ascending
// byte order.
type Resolution []Package

// Lookup returns the chosen version of name, if any.
func (r Resolution) Lookup(name string) (Version, bool) {
	i := sort.Search(len(r), func(i int) bool { return r[i].Name >= name })
	if i < len(r) && r[i].Name == name {
		return r[i].Version, true
	}
	return Version{}, false
}

// compiled form of the registry used by the search. Package names are
// replaced by dense integer ids and every requirement carries the half-open
// range [lo, hi) of indices into its target's newest-first version list that
// satisfy it, so the search never scans versions.

type cReq struct {
	pkg    int32
	lo, hi int32
}

type cVersion struct {
	version Version
	reqs    []cReq
}

type cPackage struct {
	name     string
	versions []cVersion // newest first
}

// choice is one choice point: the package being decided, the candidate
// currently tried (cur, within [.., end)) and the position in the pending
// list that the search continues with once this package's own requirements
// are used up.
type choice struct {
	pkg, cur, end  int32
	parent, parPos int32
}

// Resolve finds the resolution defined by the search described in the
// package documentation. It returns ErrUnsatisfiable if there is none.
//
// The registry is not modified; Resolve may be called many times, with
// different roots, and concurrently from several goroutines as long as the
// registry is not being modified.
func (g *Registry) Resolve(root []Requirement) (Resolution, error) {
	pkgs, rootReqs := g.compile(root)

	// The pending requirement list is a persistent linked list of "frames".
	// Frame 0 is the root manifest; frame k+1 is the requirement list of the
	// version currently picked by choice point k. A position is a pair
	// (frame, index into that frame's list); each choice point records the
	// position it continues with, so choosing a version is O(1) and nothing
	// is copied. Frames of popped choice points are never referenced again.
	stack := make([]choice, 0, len(pkgs))
	chosen := make([]int32, len(pkgs)) // picked version index, or -1
	for i := range chosen {
		chosen[i] = -1
	}
	frameReqs := func(f int32) []cReq {
		if f == 0 {
			return rootReqs
		}
		c := &stack[f-1]
		return pkgs[c.pkg].versions[c.cur].reqs
	}

	var frame, pos int32
	reqs := rootReqs
	for {
		if int(pos) == len(reqs) {
			if frame == 0 {
				break // success
			}
			c := &stack[frame-1]
			frame, pos = c.parent, c.parPos
			reqs = frameReqs(frame)
			continue
		}
		r := reqs[pos]
		pos++
		ok := true
		if cur := chosen[r.pkg]; cur >= 0 {
			ok = cur >= r.lo && cur < r.hi
		} else if r.lo < r.hi {
			chosen[r.pkg] = r.lo
			stack = append(stack, choice{pkg: r.pkg, cur: r.lo, end: r.hi, parent: frame, parPos: pos})
			frame, pos = int32(len(stack)), 0
			reqs = pkgs[r.pkg].versions[r.lo].reqs
			continue
		} else {
			ok = false
		}
		if ok {
			continue
		}
		// Backtrack to the most recent choice point with a candidate left.
		for {
			n := len(stack)
			if n == 0 {
				return nil, ErrUnsatisfiable
			}
			c := &stack[n-1]
			c.cur++
			if c.cur < c.end {
				chosen[c.pkg] = c.cur
				frame, pos = int32(n), 0
				reqs = pkgs[c.pkg].versions[c.cur].reqs
				break
			}
			chosen[c.pkg] = -1
			stack = stack[:n-1]
		}
	}

	out := make(Resolution, 0, len(stack))
	for i := range stack {
		c := &stack[i]
		out = append(out, Package{pkgs[c.pkg].name, pkgs[c.pkg].versions[c.cur].version})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// compile converts the registry and root requirements to the compiled form.
// Names that are required but never declared get a package with no versions.
func (g *Registry) compile(root []Requirement) ([]cPackage, []cReq) {
	ids := make(map[string]int32, len(g.names))
	pkgs := make([]cPackage, 0, len(g.names))
	for i, name := range g.names {
		ids[name] = int32(i)
		pkgs = append(pkgs, cPackage{name: name})
	}
	idOf := func(name string) int32 {
		id, ok := ids[name]
		if !ok {
			id = int32(len(pkgs))
			ids[name] = id
			pkgs = append(pkgs, cPackage{name: name})
		}
		return id
	}

	// Sort each package's versions newest first. Requirement index ranges
	// need the final order of every target, so they are resolved in a second
	// pass.
	order := make([][]packageVersion, len(g.names))
	for i, vs := range g.versions {
		sorted := append([]packageVersion(nil), vs...)
		sort.Slice(sorted, func(a, b int) bool { return sorted[b].version.Less(sorted[a].version) })
		order[i] = sorted
		pkgs[i].versions = make([]cVersion, len(sorted))
	}
	// Assign ids for undeclared targets before the slice header is captured.
	for _, vs := range order {
		for _, pv := range vs {
			for _, r := range pv.reqs {
				idOf(r.Name)
			}
		}
	}
	for _, r := range root {
		idOf(r.Name)
	}

	compileReqs := func(rs []Requirement) []cReq {
		if len(rs) == 0 {
			return nil
		}
		out := make([]cReq, len(rs))
		for i, r := range rs {
			id := ids[r.Name]
			out[i] = cReq{pkg: id}
			if int(id) < len(order) {
				out[i].lo, out[i].hi = candidateSpan(order[id], r.Range)
			}
		}
		return out
	}
	for i, vs := range order {
		for j, pv := range vs {
			pkgs[i].versions[j] = cVersion{pv.version, compileReqs(pv.reqs)}
		}
	}
	return pkgs, compileReqs(root)
}

// candidateSpan returns the indices [lo, hi) of the versions in vs (sorted
// newest first) that lie in the range, found by binary search.
func candidateSpan(vs []packageVersion, r Range) (lo, hi int32) {
	if r.Empty() {
		return 0, 0
	}
	// lo: first index whose version is below r's upper bound.
	l := 0
	if !r.hiInf {
		l = sort.Search(len(vs), func(i int) bool { return vs[i].version.Less(r.hi) })
	}
	// hi: first index whose version is below r's lower bound.
	h := sort.Search(len(vs), func(i int) bool { return vs[i].version.Less(r.lo) })
	if h < l {
		h = l
	}
	return int32(l), int32(h)
}
