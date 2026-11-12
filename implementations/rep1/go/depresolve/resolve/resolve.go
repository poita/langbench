// Package resolve picks one version for every needed package, following a
// fully specified search: depth-first in requirement order, newest candidate
// first, with chronological backtracking. The first complete solution found
// is returned, so the result is deterministic.
//
// The implementation is an explicit-stack machine, so recursion depth is not
// limited by the goroutine stack. Registry data is compiled once into flat
// integer tables; each requirement's admissible candidates are a contiguous
// index range into the package's newest-first version list, found by binary
// search. Pending requirements form a persistent linked list that is shared
// between choice points, and choices are undone through the choice stack, so a
// search step costs O(1) plus the requirements it pushes.
package resolve

import (
	"errors"
	"sort"

	"depresolve/registry"
	"depresolve/semver"
)

// ErrUnsatisfiable is returned when the search exhausts every candidate
// without finding a resolution.
var ErrUnsatisfiable = errors.New("resolve: no resolution exists")

// Pick is the version chosen for one package.
type Pick struct {
	Package string
	Version semver.Version
}

// Resolution is the set of chosen packages, sorted by package name in
// ascending byte order.
type Resolution []Pick

// Resolve returns the first resolution of the root requirements against reg in
// the order defined by the search, or ErrUnsatisfiable.
func Resolve(reg *registry.Registry, root []registry.Requirement) (Resolution, error) {
	p := compile(reg, root)
	return p.search()
}

// problem is the compiled, integer-indexed form of a registry and root.
type problem struct {
	names []string // package id -> name

	// Versions of all packages, newest first within each package, flattened.
	// Package p owns versions [verBase[p], verBase[p+1]).
	verBase  []int32
	versions []semver.Version
	// Requirements of flattened version v are reqs [reqStart[v], reqStart[v+1]).
	reqStart []int32

	// Requirements, flattened. A requirement names a package and admits
	// candidate indices [reqFrom, reqTo) within that package's version list
	// (index 0 is the newest version).
	reqPkg  []int32
	reqFrom []int32
	reqTo   []int32

	rootFrom, rootTo int32 // root requirements are reqs [rootFrom, rootTo)
}

func compile(reg *registry.Registry, root []registry.Requirement) *problem {
	p := &problem{}
	ids := make(map[string]int32)
	intern := func(name string) int32 {
		if id, ok := ids[name]; ok {
			return id
		}
		id := int32(len(p.names))
		ids[name] = id
		p.names = append(p.names, name)
		return id
	}
	for _, name := range reg.Packages() {
		intern(name)
	}
	nReg := len(p.names)

	// Pass 1: lay out versions.
	p.verBase = make([]int32, 0, nReg+1)
	for id := 0; id < nReg; id++ {
		p.verBase = append(p.verBase, int32(len(p.versions)))
		for _, rel := range reg.Releases(p.names[id]) {
			p.versions = append(p.versions, rel.Version)
		}
	}
	p.verBase = append(p.verBase, int32(len(p.versions)))

	// Pass 2: flatten requirements, resolving each range to an index range.
	// Targets missing from the registry get ids >= nReg with no versions.
	add := func(rq registry.Requirement) {
		id := intern(rq.Package)
		from, to := p.candidates(id, nReg, rq.Range)
		p.reqPkg = append(p.reqPkg, id)
		p.reqFrom = append(p.reqFrom, from)
		p.reqTo = append(p.reqTo, to)
	}
	p.reqStart = make([]int32, 0, len(p.versions)+1)
	for id := 0; id < nReg; id++ {
		for _, rel := range reg.Releases(p.names[id]) {
			p.reqStart = append(p.reqStart, int32(len(p.reqPkg)))
			for _, rq := range rel.Requires {
				add(rq)
			}
		}
	}
	p.reqStart = append(p.reqStart, int32(len(p.reqPkg)))
	p.rootFrom = int32(len(p.reqPkg))
	for _, rq := range root {
		add(rq)
	}
	p.rootTo = int32(len(p.reqPkg))
	return p
}

// candidates returns the index range [from, to) of the versions of package id
// accepted by r. Versions are sorted newest first.
func (p *problem) candidates(id int32, nReg int, r semver.Range) (from, to int32) {
	if int(id) >= nReg {
		return 0, 0
	}
	vs := p.versions[p.verBase[id]:p.verBase[id+1]]
	// from: first index whose version is below Hi (skips versions >= Hi).
	if !r.Unbounded {
		from = int32(sort.Search(len(vs), func(i int) bool { return vs[i].Compare(r.Hi) < 0 }))
	}
	// to: first index whose version is below Lo.
	to = int32(sort.Search(len(vs), func(i int) bool { return vs[i].Compare(r.Lo) < 0 }))
	if to < from {
		to = from
	}
	return from, to
}

// node is a cell of the persistent pending-requirement list.
type node struct {
	req  int32 // index into the flattened requirements
	next int32 // arena index of the next cell, or -1
}

// choice is a choice point: package pkg is currently set to candidate cur out
// of [.., end); on failure it advances. rest is the pending list that follows
// the requirement that created the choice; arena is the arena length to
// restore.
type choice struct {
	pkg, cur, end, rest, arena int32
}

func (p *problem) search() (Resolution, error) {
	np := len(p.names)
	chosen := make([]int32, np) // candidate index per package, -1 if unchosen
	for i := range chosen {
		chosen[i] = -1
	}
	arena := make([]node, 0, 1024)
	var stack []choice

	// push prepends requirements [lo, hi) to the list rest, returning the new head.
	push := func(lo, hi, rest int32) int32 {
		if lo == hi {
			return rest
		}
		head := int32(len(arena))
		for r := lo; r < hi-1; r++ {
			arena = append(arena, node{r, int32(len(arena)) + 1})
		}
		arena = append(arena, node{hi - 1, rest})
		return head
	}
	// enter makes candidate cur of cp current and prepends its requirements.
	enter := func(cp *choice, rest int32) int32 {
		v := p.verBase[cp.pkg] + cp.cur
		return push(p.reqStart[v], p.reqStart[v+1], rest)
	}

	pending := push(p.rootFrom, p.rootTo, -1)
	for {
		ok := true
		if pending < 0 {
			break
		}
		n := arena[pending]
		r := n.req
		pk := p.reqPkg[r]
		if c := chosen[pk]; c >= 0 {
			if c >= p.reqFrom[r] && c < p.reqTo[r] {
				pending = n.next
				continue
			}
			ok = false
		} else if from := p.reqFrom[r]; from >= p.reqTo[r] {
			ok = false
		} else {
			stack = append(stack, choice{pkg: pk, cur: from, end: p.reqTo[r], rest: n.next, arena: int32(len(arena))})
			chosen[pk] = from
			pending = enter(&stack[len(stack)-1], n.next)
		}
		if ok {
			continue
		}
		// Backtrack to the most recent choice with an untried candidate.
		for ; ; stack = stack[:len(stack)-1] {
			if len(stack) == 0 {
				return nil, ErrUnsatisfiable
			}
			cp := &stack[len(stack)-1]
			cp.cur++
			if cp.cur < cp.end {
				chosen[cp.pkg] = cp.cur
				arena = arena[:cp.arena]
				pending = enter(cp, cp.rest)
				break
			}
			chosen[cp.pkg] = -1
		}
	}

	var res Resolution
	for id, c := range chosen {
		if c >= 0 {
			res = append(res, Pick{p.names[id], p.versions[p.verBase[id]+c]})
		}
	}
	sort.Slice(res, func(i, j int) bool { return res[i].Package < res[j].Package })
	if res == nil {
		res = Resolution{}
	}
	return res, nil
}
