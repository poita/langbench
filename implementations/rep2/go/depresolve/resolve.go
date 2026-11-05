package depresolve

import (
	"errors"
	"slices"
	"sort"
	"strings"
)

// ErrUnsatisfiable is returned by Resolve when no resolution exists.
var ErrUnsatisfiable = errors.New("depresolve: unsatisfiable")

// Package is one entry of a Resolution: a package and its chosen version.
type Package struct {
	Name    string
	Version Version
}

// Resolution is the set of chosen packages, sorted by name in ascending byte
// order.
type Resolution []Package

// Get returns the chosen version of the named package.
func (res Resolution) Get(name string) (Version, bool) {
	i := sort.Search(len(res), func(i int) bool { return res[i].Name >= name })
	if i < len(res) && res[i].Name == name {
		return res[i].Version, true
	}
	return Version{}, false
}

// String formats the resolution as one "name version\n" line per package, the
// format the command-line tool prints. An empty resolution is the empty
// string.
func (res Resolution) String() string {
	var b strings.Builder
	for _, p := range res {
		b.WriteString(p.Name)
		b.WriteByte(' ')
		b.Write(p.Version.appendTo(nil))
		b.WriteByte('\n')
	}
	return b.String()
}

// cell is one node of the persistent pending list.
type cell struct {
	req  int32 // index into compiled.reqs
	next int32 // index of the next cell, or -1
}

// frame is a choice point: the package whose candidates are being tried.
type frame struct {
	pkg  int32
	cur  int32 // current candidate index in the package's newest-first list
	end  int32 // one past the last candidate of the window
	rest int32 // pending list after the requirement that opened the frame
	mark int32 // arena length when the frame was opened
}

// creq is a requirement resolved to a window [first, last) of candidate
// indices in the target package's newest-first version list.
type creq struct {
	pkg         int32
	first, last int32
}

// cver is a version in a package's newest-first list.
type cver struct {
	reqStart, reqCount int32
}

// compiled is the immutable, search-ready form of a Registry plus a root.
type compiled struct {
	vers     [][]cver // per package, newest first
	versions [][]Version
	reqs     []creq // registry requirements, then root requirements
	rootBeg  int32
	rootCnt  int32
	names    []string
}

func sortVersionsDesc(vs []Version) {
	slices.SortFunc(vs, func(a, b Version) int { return b.Compare(a) })
}

func (r *Registry) compile(root []Requirement) *compiled {
	np := len(r.pkgs)
	c := &compiled{
		vers:     make([][]cver, np+1), // +1: ghost package for unknown root names
		versions: make([][]Version, np+1),
		names:    make([]string, np+1),
	}
	keys := make([][]Key, np+1)
	for id := range r.pkgs {
		p := &r.pkgs[id]
		c.names[id] = p.name
		sorted := slices.Clone(p.versions)
		slices.SortFunc(sorted, func(a, b verInfo) int {
			switch {
			case a.key > b.key:
				return -1
			case a.key < b.key:
				return 1
			}
			return 0
		})
		cv := make([]cver, len(sorted))
		ks := make([]Key, len(sorted))
		vv := make([]Version, len(sorted))
		for i, s := range sorted {
			cv[i] = cver{s.reqStart, s.reqCount}
			ks[i] = s.key
			vv[i] = s.version
		}
		c.vers[id], keys[id], c.versions[id] = cv, ks, vv
	}

	window := func(pkg int32, rng Range) creq {
		if int(pkg) >= np || rng.Empty() {
			return creq{pkg, 0, 0}
		}
		ks := keys[pkg]
		// ks is descending: candidates are those with lo <= key < hi.
		first := sort.Search(len(ks), func(i int) bool { return ks[i] < rng.hi })
		last := sort.Search(len(ks), func(i int) bool { return ks[i] < rng.lo })
		if last <= first {
			return creq{pkg, 0, 0}
		}
		return creq{pkg, int32(first), int32(last)}
	}

	c.reqs = make([]creq, 0, len(r.reqs)+len(root))
	for _, q := range r.reqs {
		c.reqs = append(c.reqs, window(q.pkg, q.rng))
	}
	c.rootBeg = int32(len(c.reqs))
	c.rootCnt = int32(len(root))
	for _, q := range root {
		id, ok := r.ids[q.Name]
		if !ok {
			id = int32(np)
		}
		c.reqs = append(c.reqs, window(id, q.Range))
	}
	return c
}

// Resolve returns the first complete solution of the specified search for the
// root requirements: depth-first in requirement order, newest candidate
// first, with chronological backtracking. It returns ErrUnsatisfiable if no
// solution exists.
func (r *Registry) Resolve(root []Requirement) (Resolution, error) {
	c := r.compile(root)

	reqs := c.reqs
	vers := c.vers
	chosen := make([]int32, len(vers)) // candidate index, or -1
	for i := range chosen {
		chosen[i] = -1
	}
	arena := make([]cell, 0, 1024)
	frames := make([]frame, 0, 256)

	// prepend pushes the requirements [start, start+count) in front of head,
	// last first, and returns the new head.
	prepend := func(head, start, count int32) int32 {
		for i := start + count - 1; i >= start; i-- {
			arena = append(arena, cell{i, head})
			head = int32(len(arena) - 1)
		}
		return head
	}

	head := prepend(-1, c.rootBeg, c.rootCnt)
	for head >= 0 {
		cl := arena[head]
		q := reqs[cl.req]
		head = cl.next

		if cur := chosen[q.pkg]; cur >= 0 {
			if cur >= q.first && cur < q.last {
				continue
			}
		} else if q.first < q.last {
			frames = append(frames, frame{q.pkg, q.first, q.last, head, int32(len(arena))})
			chosen[q.pkg] = q.first
			v := vers[q.pkg][q.first]
			head = prepend(head, v.reqStart, v.reqCount)
			continue
		}

		// Backtrack: advance the most recent choice point with a candidate
		// left, discarding the choice points above it.
		for {
			if len(frames) == 0 {
				return nil, ErrUnsatisfiable
			}
			f := &frames[len(frames)-1]
			arena = arena[:f.mark]
			f.cur++
			if f.cur < f.end {
				chosen[f.pkg] = f.cur
				v := vers[f.pkg][f.cur]
				head = prepend(f.rest, v.reqStart, v.reqCount)
				break
			}
			chosen[f.pkg] = -1
			frames = frames[:len(frames)-1]
		}
	}

	res := make(Resolution, len(frames))
	for i, f := range frames {
		res[i] = Package{c.names[f.pkg], c.versions[f.pkg][f.cur]}
	}
	slices.SortFunc(res, func(a, b Package) int { return strings.Compare(a.Name, b.Name) })
	return res, nil
}
