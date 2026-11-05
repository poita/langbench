package depresolve

// frame is one choice point: the package whose candidates are being tried,
// the cursor into its window, the pending list to continue with, and the
// arena length to restore on backtrack.
type frame struct {
	pkg  int32
	cur  int32
	end  int32
	rest int32
	mark int32
}

// solver runs the SPEC's search iteratively with an explicit frame stack,
// a persistent pending list in an arena, and a chosen array indexed by
// package id. Nothing is copied per step.
type solver struct {
	ix   *index
	reqs []creq // index requirements followed by the root's
	root span

	cellReq  []int32 // arena of pending cells: requirement index
	cellNext []int32 // and the next cell (-1 ends the list)
}

func newSolver(ix *index, root []Requirement) *solver {
	reqs := make([]creq, len(ix.reqs), len(ix.reqs)+len(root))
	copy(reqs, ix.reqs)
	for _, q := range root {
		reqs = append(reqs, ix.compile(q))
	}
	return &solver{
		ix:   ix,
		reqs: reqs,
		root: span{int32(len(ix.reqs)), int32(len(root))},
	}
}

// push prepends the requirements of sp (in order) to the list starting at
// head, one new cell each, and returns the new head.
func (s *solver) push(sp span, head int32) int32 {
	for i := sp.start + sp.n - 1; i >= sp.start; i-- {
		s.cellReq = append(s.cellReq, i)
		s.cellNext = append(s.cellNext, head)
		head = int32(len(s.cellReq) - 1)
	}
	return head
}

func (s *solver) run() (Resolution, bool) {
	ix := s.ix
	np := len(ix.names) + 1
	chosen := make([]int32, np)
	for i := range chosen {
		chosen[i] = -1
	}
	reqs := s.reqs
	vreqs := ix.vreqs
	var frames []frame

	head := s.push(s.root, -1)
	for head >= 0 {
		q := &reqs[s.cellReq[head]]
		next := s.cellNext[head]
		c := chosen[q.pkg]
		if c >= 0 {
			if c >= q.first && c < q.last {
				head = next
				continue
			}
		} else if q.first < q.last {
			frames = append(frames, frame{q.pkg, q.first, q.last, next, int32(len(s.cellReq))})
			chosen[q.pkg] = q.first
			head = s.push(vreqs[q.pkg][q.first], next)
			continue
		}
		// Backtrack: advance the newest choice point that has candidates left.
		head = -2
		for len(frames) > 0 {
			f := &frames[len(frames)-1]
			s.cellReq = s.cellReq[:f.mark]
			s.cellNext = s.cellNext[:f.mark]
			f.cur++
			if f.cur < f.end {
				chosen[f.pkg] = f.cur
				head = s.push(vreqs[f.pkg][f.cur], f.rest)
				break
			}
			chosen[f.pkg] = -1
			frames = frames[:len(frames)-1]
		}
		if head == -2 {
			return nil, false
		}
	}

	out := make(Resolution, len(frames))
	for i, f := range frames {
		out[i] = Pick{ix.names[f.pkg], VersionFromKey(ix.vkeys[f.pkg][f.cur])}
	}
	return out, true
}
