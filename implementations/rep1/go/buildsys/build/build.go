// Package build runs one Kiln build: it evaluates the build files, validates
// and traverses the dependency graph, decides which steps are stale, and
// executes them on a simulated set of parallel workers against a virtual file
// system, persisting its knowledge in .kiln-state.
package build

import (
	"sort"

	"buildsys/command"
	"buildsys/kbl"
	"buildsys/kilnerr"
	"buildsys/plan"
	"buildsys/state"
	"buildsys/vfs"
)

// EventKind distinguishes the lines a build contributes to the log.
type EventKind uint8

// Event kinds.
const (
	KindHit EventKind = iota
	KindRun
	KindFail
	KindCancel
)

// Event is one scheduling event. For Hit, Start == End == the time of the hit
// and Worker is -1.
type Event struct {
	Kind       EventKind
	Serial     int
	Start, End int64
	Worker     int
	Target     string // primary output path
	Command    string // canonical command string
}

// Result is the outcome of a build.
type Result struct {
	Events []Event // sorted by start time, then step serial
	Ran    int     // commands that executed successfully
	Hits   int     // cache hits
	Time   int64   // completion time
	Err    *kilnerr.Error
}

// Run performs a build of the given targets (or the default targets when
// targets is empty) with the given number of workers. A configuration error
// leaves the file system untouched; once execution starts, .kiln-state is
// always rewritten.
func Run(fs *vfs.FS, targets []string, workers int) *Result {
	res := &Result{}
	p, err := kbl.Evaluate(fs)
	if err != nil {
		res.Err = err
		return res
	}
	g, err := buildGraph(fs, p)
	if err != nil {
		res.Err = err
		return res
	}
	roots, err := g.requested(targets)
	if err != nil {
		res.Err = err
		return res
	}
	col, err := g.reach(roots)
	if err != nil {
		res.Err = err
		return res
	}
	if workers < 1 {
		workers = 1
	}
	st := loadState(fs)
	r := &runner{g: g, fs: fs, st: st, col: col, workers: workers, res: res}
	r.schedule()
	fs.Write(vfs.StateFile, st.Marshal())
	sort.SliceStable(res.Events, func(i, j int) bool {
		a, b := res.Events[i], res.Events[j]
		if a.Start != b.Start {
			return a.Start < b.Start
		}
		return a.Serial < b.Serial
	})
	return res
}

func loadState(fs *vfs.FS) state.State {
	data, ok := fs.Read(vfs.StateFile)
	if !ok {
		return state.State{}
	}
	st, _ := state.Parse(data)
	return st
}

type worker struct {
	active     bool
	step       int
	start, end int64
	event      int // index into res.Events
	exec       *execution
}

// execution is the result of running a command, computed at dispatch time
// from the inputs captured then and applied at the command's end time.
type execution struct {
	err   *kilnerr.Error
	outs  []outFile
	entry *state.Entry
}

type outFile struct {
	path    string
	content []byte
	hash    uint64
}

type runner struct {
	g       *graph
	fs      *vfs.FS
	st      state.State
	col     []colour
	workers int
	res     *Result

	pending    []int32
	dependents [][]int32
	undecided  minHeap
	stale      minHeap
	time       int64
	maxEnd     int64
}

func (r *runner) schedule() {
	g := r.g
	n := len(g.kind)
	r.pending = make([]int32, n)
	r.dependents = make([][]int32, n)
	for id := 0; id < n; id++ {
		if r.col[id] == white {
			continue
		}
		r.pending[id] = int32(len(g.succ[id]))
		for _, m := range g.succ[id] {
			r.dependents[m] = append(r.dependents[m], int32(id))
		}
	}
	// Initialisation: steps with nothing to wait for are ready; sources and
	// phonies with nothing to wait for complete at time 0, cascading.
	var instant []int32
	for id := 0; id < n; id++ {
		if r.col[id] == white || r.pending[id] != 0 {
			continue
		}
		if g.kind[id] == nStep {
			r.undecided.push(id)
		} else {
			instant = append(instant, int32(id))
		}
	}
	r.completeAll(instant)

	ws := make([]worker, r.workers)
	running := 0
	events := &r.res.Events
	for {
		// (A) settle cache hits at the current time.
		for r.undecided.len() > 0 {
			id := r.undecided.pop()
			s := r.g.plan.Steps[id]
			if r.fresh(s) {
				r.res.Hits++
				*events = append(*events, Event{Kind: KindHit, Serial: id, Start: r.time, End: r.time,
					Worker: -1, Target: s.Primary(), Command: s.CmdString})
				r.bump(r.time)
				r.completeAll([]int32{int32(id)})
			} else {
				r.stale.push(id)
			}
		}
		// (B) dispatch.
		for r.stale.len() > 0 {
			w := -1
			for i := range ws {
				if !ws[i].active {
					w = i
					break
				}
			}
			if w < 0 {
				break
			}
			id := r.stale.pop()
			s := r.g.plan.Steps[id]
			end := r.time + s.Cost
			*events = append(*events, Event{Kind: KindRun, Serial: id, Start: r.time, End: end,
				Worker: w, Target: s.Primary(), Command: s.CmdString})
			ws[w] = worker{active: true, step: id, start: r.time, end: end,
				event: len(*events) - 1, exec: r.execute(s)}
			r.bump(end)
			running++
		}
		// (C) advance the clock.
		if running == 0 {
			break
		}
		next := int64(-1)
		for i := range ws {
			if ws[i].active && (next < 0 || ws[i].end < next) {
				next = ws[i].end
			}
		}
		r.time = next
		var failed []int
		var done []int32
		for i := range ws {
			if !ws[i].active || ws[i].end != r.time {
				continue
			}
			w := &ws[i]
			w.active = false
			running--
			if w.exec.err != nil {
				(*events)[w.event].Kind = KindFail
				failed = append(failed, w.step)
				continue
			}
			for _, o := range w.exec.outs {
				r.fs.WriteHashed(o.path, o.content, o.hash)
			}
			r.st[r.g.plan.Steps[w.step].Primary()] = w.exec.entry
			r.res.Ran++
			done = append(done, int32(w.step))
		}
		if len(failed) > 0 {
			best := failed[0]
			for _, f := range failed {
				if f < best {
					best = f
				}
			}
			for i := range ws {
				if ws[i].active {
					(*events)[ws[i].event].Kind = KindCancel
					delete(r.st, r.g.plan.Steps[ws[i].step].Primary())
				}
			}
			for _, f := range failed {
				delete(r.st, r.g.plan.Steps[f].Primary())
			}
			for i := range ws {
				if ws[i].exec != nil && ws[i].exec.err != nil && ws[i].step == best {
					r.res.Err = ws[i].exec.err
				}
			}
			break
		}
		r.completeAll(done)
	}
	r.res.Time = r.maxEnd
}

func (r *runner) bump(t int64) {
	if t > r.maxEnd {
		r.maxEnd = t
	}
}

// completeAll completes the given nodes at the current time. Completing a
// node releases its dependents; phony and source nodes whose last dependency
// completes complete immediately, cascading.
func (r *runner) completeAll(nodes []int32) {
	for len(nodes) > 0 {
		n := nodes[len(nodes)-1]
		nodes = nodes[:len(nodes)-1]
		for _, d := range r.dependents[n] {
			r.pending[d]--
			if r.pending[d] != 0 {
				continue
			}
			if r.g.kind[d] == nStep {
				r.undecided.push(int(d))
			} else {
				nodes = append(nodes, d)
			}
		}
	}
}

// fresh decides whether step s is a cache hit against the current workspace
// and state.
func (r *runner) fresh(s *plan.Step) bool {
	e := r.st[s.Primary()]
	if e == nil || e.Cmd != s.CmdString {
		return false
	}
	if !samePaths(e.Out, s.FullOuts) || !samePaths(e.In, s.FileIns) {
		return false
	}
	for _, list := range [3][]state.PathHash{e.In, e.Dep, e.Out} {
		for _, ph := range list {
			h, ok := r.fs.Hash(ph.Path)
			if !ok || h != ph.Hash {
				return false
			}
		}
	}
	return true
}

func samePaths(a []state.PathHash, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Path != b[i] {
			return false
		}
	}
	return true
}

// execute reads the step's inputs now and runs its command, returning the
// effects to apply at its end time.
func (r *runner) execute(s *plan.Step) *execution {
	inputs := make([]command.Input, len(s.FileIns))
	entry := &state.Entry{Cmd: s.CmdString}
	for i, p := range s.FileIns {
		c, _ := r.fs.Read(p)
		h, _ := r.fs.Hash(p)
		inputs[i] = command.Input{Path: p, Content: c, Hash: h}
		entry.In = append(entry.In, state.PathHash{Path: p, Hash: h})
	}
	res, err := command.Run(s.Cmd, s.Args, inputs, r.fs)
	if err != nil {
		return &execution{err: err}
	}
	ex := &execution{entry: entry}
	for _, d := range res.Deps {
		h, _ := r.fs.Hash(d)
		entry.Dep = append(entry.Dep, state.PathHash{Path: d, Hash: h})
	}
	add := func(path string, content []byte) {
		h := vfs.Hash64(content)
		ex.outs = append(ex.outs, outFile{path, content, h})
		entry.Out = append(entry.Out, state.PathHash{Path: path, Hash: h})
	}
	add(s.Outs[0], res.Out)
	if s.Depfile != "" {
		add(s.Depfile, res.Depfile)
	}
	return ex
}
