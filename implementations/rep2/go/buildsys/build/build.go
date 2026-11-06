// Package build implements one Kiln build: evaluating the build files,
// validating and walking the dependency graph, deciding freshness against
// the persisted state, and running the deterministic multi-worker scheduling
// simulation against the virtual file system.
package build

import (
	"sort"

	"kiln/cmds"
	"kiln/errs"
	"kiln/kbl"
	"kiln/vfs"
)

// EventKind classifies a log event of a build.
type EventKind uint8

// Event kinds.
const (
	KindHit EventKind = iota
	KindRun
	KindFail
	KindCancel
)

// String returns the word used in the log.
func (k EventKind) String() string {
	return [...]string{"hit", "run", "fail", "cancel"}[k]
}

// Event is one line of a build's log.
type Event struct {
	Kind   EventKind
	Start  int64 // for a hit, the time of the hit
	End    int64
	Worker int
	Serial int
	Target string // primary output path
	Cmd    string // canonical command string (not set for hits)
}

// Request describes one build.
type Request struct {
	Targets []string // empty means the default targets
	Workers int      // number of simulated workers (at least 1)
}

// Result is the outcome of a build.
type Result struct {
	Events []Event // sorted by start time, then step serial
	Ran    int     // commands that executed successfully
	Hits   int     // cache hits
	Time   int64   // completion time
	Err    *errs.Error
}

type running struct {
	node  int
	start int64
	end   int64
	ev    int // index into events
	res   cmds.Result
	err   *errs.Error
	ins   []cmds.Input
}

// Run performs a build against fs. On a configuration error the file
// system is left untouched. Otherwise .kiln-state is rewritten, even if a
// command fails.
func Run(fs *vfs.FS, req Request) *Result {
	res := &Result{}
	prog, err := kbl.Evaluate(fs)
	if err != nil {
		res.Err = err
		return res
	}
	g, err := newGraph(prog, fs)
	if err != nil {
		res.Err = err
		return res
	}
	roots, err := g.requested(req.Targets)
	if err != nil {
		res.Err = err
		return res
	}
	reach, err := g.reach(roots)
	if err != nil {
		res.Err = err
		return res
	}
	var st *State
	if data, ok := fs.Read(vfs.StatePath); ok {
		st = ParseState(data)
	} else {
		st = NewState()
	}
	workers := max(req.Workers, 1)
	s := &scheduler{g: g, fs: fs, st: st, reach: reach, res: res, workers: make([]*running, workers)}
	s.run()
	sort.SliceStable(res.Events, func(i, j int) bool {
		a, b := &res.Events[i], &res.Events[j]
		if a.Start != b.Start {
			return a.Start < b.Start
		}
		return a.Serial < b.Serial
	})
	fs.Write(vfs.StatePath, st.Encode())
	return res
}

type scheduler struct {
	g       *graph
	fs      *vfs.FS
	st      *State
	reach   []bool
	res     *Result
	workers []*running

	pending    []int
	dependents [][]int
	undecided  minHeap
	stale      minHeap
	time       int64
}

// complete marks node n done and releases its dependents.
func (s *scheduler) complete(n int) {
	for _, d := range s.dependents[n] {
		s.pending[d]--
		if s.pending[d] != 0 {
			continue
		}
		if s.g.nodes[d].kind == nStep {
			s.undecided.push(d)
		} else {
			s.complete(d)
		}
	}
}

func (s *scheduler) record(e Event) int {
	s.res.Events = append(s.res.Events, e)
	if e.End > s.res.Time {
		s.res.Time = e.End
	}
	return len(s.res.Events) - 1
}

func (s *scheduler) run() {
	g := s.g
	s.pending = make([]int, len(g.nodes))
	s.dependents = make([][]int, len(g.nodes))
	for n := range g.nodes {
		if !s.reach[n] {
			continue
		}
		s.pending[n] = len(g.nodes[n].succ)
		for _, m := range g.nodes[n].succ {
			s.dependents[m] = append(s.dependents[m], n)
		}
	}
	for n := range g.nodes {
		if !s.reach[n] || s.pending[n] != 0 {
			continue
		}
		if g.nodes[n].kind == nStep {
			s.undecided.push(n)
		} else {
			s.complete(n)
		}
	}
	for {
		// (A) settle cache hits at the current time.
		for len(s.undecided) > 0 {
			n := s.undecided.pop()
			step := g.nodes[n].step
			if s.st.Fresh(s.fs, step) {
				s.res.Hits++
				s.record(Event{Kind: KindHit, Start: s.time, End: s.time, Serial: step.Serial, Target: step.Primary()})
				s.complete(n)
			} else {
				s.stale.push(n)
			}
		}
		// (B) dispatch.
		for len(s.stale) > 0 {
			w := s.freeWorker()
			if w < 0 {
				break
			}
			s.dispatch(w, s.stale.pop())
		}
		// (C) advance the clock.
		first := true
		var next int64
		for _, r := range s.workers {
			if r != nil && (first || r.end < next) {
				next, first = r.end, false
			}
		}
		if first {
			break
		}
		s.time = next
		var done []*running
		var failed []*running
		for w, r := range s.workers {
			if r == nil || r.end != s.time {
				continue
			}
			s.workers[w] = nil
			if r.err != nil {
				s.res.Events[r.ev].Kind = KindFail
				failed = append(failed, r)
			} else {
				s.finish(r)
				done = append(done, r)
			}
		}
		if len(failed) > 0 {
			// Workers are visited in ascending id, but the winning error is the
			// one of the smallest step serial.
			win := failed[0]
			for _, f := range failed {
				if f.node < win.node {
					win = f
				}
			}
			s.res.Err = win.err
			for w, r := range s.workers {
				if r != nil {
					s.res.Events[r.ev].Kind = KindCancel
					delete(s.st.Entries, g.nodes[r.node].step.Primary())
					s.workers[w] = nil
				}
			}
			for _, f := range failed {
				delete(s.st.Entries, g.nodes[f.node].step.Primary())
			}
			return
		}
		for _, r := range done {
			s.complete(r.node)
		}
	}
}

func (s *scheduler) freeWorker() int {
	for w, r := range s.workers {
		if r == nil {
			return w
		}
	}
	return -1
}

// dispatch starts step node n on worker w: the command reads its inputs now
// and its result is applied at its end time.
func (s *scheduler) dispatch(w, n int) {
	step := s.g.nodes[n].step
	r := &running{node: n, start: s.time, end: s.time + step.Cost}
	r.ins = make([]cmds.Input, len(step.FileIns))
	for i, p := range step.FileIns {
		data, h, _ := s.fs.Lookup(p)
		r.ins[i] = cmds.Input{Path: p, Data: data, Hash: h}
	}
	r.res, r.err = step.Spec.Run(step.Args, r.ins, s.fs)
	r.ev = s.record(Event{Kind: KindRun, Start: r.start, End: r.end, Worker: w, Serial: step.Serial,
		Target: step.Primary(), Cmd: step.CmdStr})
	s.workers[w] = r
}

// finish writes a successful command's outputs and replaces its state entry.
func (s *scheduler) finish(r *running) {
	step := s.g.nodes[r.node].step
	e := &Entry{Cmd: step.CmdStr}
	for _, in := range r.ins {
		e.Ins = append(e.Ins, PathHash{in.Path, in.Hash})
	}
	for _, d := range r.res.Deps {
		e.Deps = append(e.Deps, PathHash{d.Path, d.Hash})
	}
	write := func(path string, data []byte) {
		h := vfs.Hash(data)
		s.fs.WriteHashed(path, data, h)
		e.Outs = append(e.Outs, PathHash{path, h})
	}
	write(step.Outs[0], r.res.Output)
	if step.Depfile != "" {
		write(step.Depfile, r.res.Depfile)
	}
	s.st.Entries[step.Primary()] = e
	s.res.Ran++
}
