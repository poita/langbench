package depresolve

import (
	"errors"
	"fmt"
	"slices"
)

// A Requirement asks for any version of Package that lies in Range.
type Requirement struct {
	Package string
	Range   Range
}

// verRec is one registry entry. Its requirements are the contiguous slice
// reqs[reqStart : reqStart+reqCount] of the shared requirement array.
type verRec struct {
	pkg      int32
	reqCount int32
	reqStart int32
	key      uint64
}

// reqRec is a requirement stored once and referenced by index. After Build,
// [first, last) is the window of indices into the sorted version array that
// the range admits (empty when last <= first).
type reqRec struct {
	lo, hi      uint64
	pkg         int32
	first, last int32
}

// A Builder accumulates a registry and a root manifest. The zero value is
// ready to use. A Builder may be reused after Build.
type Builder struct {
	ids       map[string]int32
	names     []string
	vers      []verRec
	reqs      []reqRec
	rootStart int32
	rootCount int32
	err       error
}

func (b *Builder) intern(name string) int32 {
	if id, ok := b.ids[name]; ok {
		return id
	}
	if b.ids == nil {
		b.ids = make(map[string]int32)
	}
	id := int32(len(b.names))
	b.ids[name] = id
	b.names = append(b.names, name)
	return id
}

func (b *Builder) addReqs(reqs []Requirement) (start, count int32) {
	start = int32(len(b.reqs))
	for _, r := range reqs {
		b.addReq(r.Package, r.Range)
	}
	return start, int32(len(reqs))
}

func (b *Builder) addReq(name string, r Range) {
	b.reqs = append(b.reqs, reqRec{lo: r.lo, hi: r.hi, pkg: b.intern(name)})
}

// ValidName reports whether s is a legal package name: [a-z][a-z0-9-]* of
// at most 16 characters.
func ValidName(s string) bool {
	if len(s) == 0 || len(s) > 16 || s[0] < 'a' || s[0] > 'z' {
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

func (b *Builder) fail(err error) {
	if b.err == nil {
		b.err = err
	}
}

// AddVersion declares one package version and its requirements. Errors are
// reported by Build.
func (b *Builder) AddVersion(name string, v Version, reqs ...Requirement) {
	if !ValidName(name) {
		b.fail(fmt.Errorf("invalid package name %q", name))
		return
	}
	if v.Major > MaxComponent || v.Minor > MaxComponent || v.Patch > MaxComponent {
		b.fail(fmt.Errorf("version %v of %s: component exceeds %d", v, name, MaxComponent))
		return
	}
	for _, r := range reqs {
		if !ValidName(r.Package) {
			b.fail(fmt.Errorf("invalid package name %q in requirement of %s %v", r.Package, name, v))
			return
		}
	}
	id := b.intern(name)
	start, n := b.addReqs(reqs)
	b.vers = append(b.vers, verRec{pkg: id, reqStart: start, reqCount: n, key: v.key()})
}

// SetRoot sets the root manifest, replacing any previous one.
func (b *Builder) SetRoot(reqs ...Requirement) {
	for _, r := range reqs {
		if !ValidName(r.Package) {
			b.fail(fmt.Errorf("invalid package name %q in root requirement", r.Package))
			return
		}
	}
	b.rootStart, b.rootCount = b.addReqs(reqs)
}

// A Problem is an immutable, fully indexed resolution problem: a registry
// plus a root manifest. It is safe for concurrent use; Resolve does not
// modify it.
type Problem struct {
	names     []string
	vers      []verRec // sorted by (pkg, newest first)
	reqs      []reqRec // with candidate windows filled in
	rootStart int32
	rootCount int32
}

// Packages returns the number of distinct package names mentioned anywhere,
// including names that only occur inside requirements.
func (p *Problem) Packages() int { return len(p.names) }

// Build indexes the accumulated data. It sorts the versions of every package
// newest first and converts each requirement's interval, once, into the
// contiguous window of candidate indices it admits.
func (b *Builder) Build() (*Problem, error) {
	if b.err != nil {
		return nil, b.err
	}
	p := &Problem{
		names:     slices.Clone(b.names),
		vers:      slices.Clone(b.vers),
		reqs:      slices.Clone(b.reqs),
		rootStart: b.rootStart,
		rootCount: b.rootCount,
	}
	slices.SortFunc(p.vers, func(x, y verRec) int {
		switch {
		case x.pkg != y.pkg:
			return int(x.pkg - y.pkg)
		case x.key > y.key:
			return -1
		case x.key < y.key:
			return 1
		}
		return 0
	})

	// pkgStart[i] is the index in p.vers of package i's newest version.
	pkgStart := make([]int32, len(p.names)+1)
	for i, v := range p.vers {
		if i > 0 && p.vers[i-1].pkg == v.pkg && p.vers[i-1].key == v.key {
			return nil, fmt.Errorf("duplicate version %v of package %s",
				versionFromKey(v.key), p.names[v.pkg])
		}
		pkgStart[v.pkg+1]++
	}
	for i := 1; i < len(pkgStart); i++ {
		pkgStart[i] += pkgStart[i-1]
	}

	for i := range p.reqs {
		r := &p.reqs[i]
		lo, hi := pkgStart[r.pkg], pkgStart[r.pkg+1]
		if r.lo >= r.hi || lo == hi {
			r.first, r.last = 0, 0
			continue
		}
		vs := p.vers[lo:hi]
		// Newest first: keys descend. first is the first index whose key is
		// below hi; last is the first index whose key is below lo.
		r.first = lo + int32(searchBelow(vs, r.hi))
		r.last = lo + int32(searchBelow(vs, r.lo))
	}
	return p, nil
}

// searchBelow returns the smallest i such that vs[i].key < bound, or len(vs).
// vs must be sorted by descending key.
func searchBelow(vs []verRec, bound uint64) int {
	lo, hi := 0, len(vs)
	for lo < hi {
		m := int(uint(lo+hi) >> 1)
		if vs[m].key < bound {
			hi = m
		} else {
			lo = m + 1
		}
	}
	return lo
}

// ErrUnsatisfiable is returned by Resolve when no resolution exists.
var ErrUnsatisfiable = errors.New("depresolve: unsatisfiable")
