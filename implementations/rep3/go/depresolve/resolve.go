package depresolve

import (
	"io"
	"slices"
	"strings"
)

// A Pick is the version chosen for one package.
type Pick struct {
	Package string
	Version Version
}

// A Resolution lists the chosen version of every needed package, sorted by
// package name in ascending byte order.
type Resolution []Pick

// Lookup returns the version chosen for name.
func (r Resolution) Lookup(name string) (Version, bool) {
	i, ok := slices.BinarySearchFunc(r, name, func(p Pick, n string) int {
		return strings.Compare(p.Package, n)
	})
	if !ok {
		return Version{}, false
	}
	return r[i].Version, true
}

// WriteTo writes one "name MAJOR.MINOR.PATCH" line per pick, using a single
// write.
func (r Resolution) WriteTo(w io.Writer) (int64, error) {
	buf := make([]byte, 0, 24*len(r))
	for _, p := range r {
		buf = append(buf, p.Package...)
		buf = append(buf, ' ')
		buf = p.Version.appendTo(buf)
		buf = append(buf, '\n')
	}
	n, err := w.Write(buf)
	return int64(n), err
}

// String returns the resolution in the form written by WriteTo.
func (r Resolution) String() string {
	var sb strings.Builder
	r.WriteTo(&sb)
	return sb.String()
}

// pendingCell is one cell of the persistent singly linked pending list. The
// list tail is shared between choice points; a cell is consumed by moving to
// next.
type pendingCell struct {
	req  int32 // index into Problem.reqs
	next int32 // index of the next cell, or noCell
}

// frame is one choice point: the package being tried, the cursor over its
// candidate window, the pending list that follows the requirement that opened
// it, and the arena length to restore on backtrack.
type frame struct {
	pkg  int32
	cur  int32 // index into Problem.vers of the version currently chosen
	end  int32
	rest int32
	mark int32
}

const (
	noCell = int32(-1)
	none   = int32(-1)
)

// Resolve returns the first complete solution in the search order defined by
// the specification: requirements are processed depth-first in the order
// listed, a newly chosen version's requirements go in front of the remaining
// pending ones, candidates are tried newest first, and failure backtracks
// chronologically to the most recent choice with an untried candidate. It
// returns ErrUnsatisfiable when the search fails.
//
// The search is iterative (no recursion) and takes time proportional to the
// number of search steps plus the requirements prepended.
func (p *Problem) Resolve() (Resolution, error) {
	vers, reqs := p.vers, p.reqs
	chosen := make([]int32, len(p.names))
	for i := range chosen {
		chosen[i] = none
	}
	arena := make([]pendingCell, 0, 1024)
	frames := make([]frame, 0, 256)

	// prepend pushes the requirements of version vi in front of tail, last
	// requirement first, so the first one ends up at the head.
	prepend := func(vi, tail int32) int32 {
		v := &vers[vi]
		for i := v.reqCount - 1; i >= 0; i-- {
			arena = append(arena, pendingCell{req: v.reqStart + i, next: tail})
			tail = int32(len(arena) - 1)
		}
		return tail
	}

	head := noCell
	for i := p.rootCount - 1; i >= 0; i-- {
		arena = append(arena, pendingCell{req: p.rootStart + i, next: head})
		head = int32(len(arena) - 1)
	}

	for {
		if head == noCell {
			break // success
		}
		cell := arena[head]
		r := &reqs[cell.req]
		if c := chosen[r.pkg]; c != none {
			if c >= r.first && c < r.last {
				head = cell.next
				continue
			}
		} else if r.first < r.last {
			frames = append(frames, frame{
				pkg: r.pkg, cur: r.first, end: r.last,
				rest: cell.next, mark: int32(len(arena)),
			})
			chosen[r.pkg] = r.first
			head = prepend(r.first, cell.next)
			continue
		}

		// Backtrack: advance the newest frame that has an untried candidate.
		for {
			if len(frames) == 0 {
				return nil, ErrUnsatisfiable
			}
			f := &frames[len(frames)-1]
			f.cur++
			if f.cur < f.end {
				arena = arena[:f.mark]
				chosen[f.pkg] = f.cur
				head = prepend(f.cur, f.rest)
				break
			}
			chosen[f.pkg] = none
			frames = frames[:len(frames)-1]
		}
	}

	res := make(Resolution, len(frames))
	for i, f := range frames {
		res[i] = Pick{Package: p.names[f.pkg], Version: versionFromKey(vers[f.cur].key)}
	}
	slices.SortFunc(res, func(a, b Pick) int { return strings.Compare(a.Package, b.Package) })
	return res, nil
}
