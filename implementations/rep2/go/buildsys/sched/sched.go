// Package sched simulates Kiln's deterministic parallel scheduler: ready steps
// are drawn in serial order from a priority queue, freshness is decided when a
// step becomes ready, commands occupy simulated workers for their cost, and the
// clock jumps from one completion to the next.
package sched

import (
	"sort"

	"buildsys/cmds"
	"buildsys/graph"
	"buildsys/kerr"
	"buildsys/state"
	"buildsys/vfs"
)

// EventKind classifies a scheduler event.
type EventKind uint8

// Event kinds.
const (
	KindHit EventKind = iota
	KindRun
	KindFail
	KindCancel
)

// Event records one step's outcome in a build.
type Event struct {
	Kind   EventKind
	Serial int
	// Start and End are the simulated times; for a Hit both equal the time
	// of the hit.
	Start, End int64
	Worker     int
	// Target is the step's primary output and Cmd its canonical command.
	Target string
	Cmd    string
}

// Result summarises a scheduled build.
type Result struct {
	// Events are sorted by start time, then step serial.
	Events []Event
	// Err is the build's execution error, if any.
	Err *kerr.Error
	// Ran and Hits count successfully executed commands and cache hits.
	Ran, Hits int
	// Time is the build's completion time.
	Time int64
}

// heap is a min-heap of ints (step serials).
type heap []int

func (h *heap) push(x int) {
	*h = append(*h, x)
	a := *h
	i := len(a) - 1
	for i > 0 {
		p := (i - 1) / 2
		if a[p] <= a[i] {
			break
		}
		a[p], a[i] = a[i], a[p]
		i = p
	}
}

func (h *heap) pop() int {
	a := *h
	top := a[0]
	n := len(a) - 1
	a[0] = a[n]
	a = a[:n]
	*h = a
	i := 0
	for {
		l, r, m := 2*i+1, 2*i+2, i
		if l < n && a[l] < a[m] {
			m = l
		}
		if r < n && a[r] < a[m] {
			m = r
		}
		if m == i {
			break
		}
		a[i], a[m] = a[m], a[i]
		i = m
	}
	return top
}

func (h heap) len() int { return len(h) }

type slot struct {
	busy       bool
	step       *graph.Step
	start, end int64
	inputs     []cmds.Input
	res        cmds.Result
	err        *kerr.Error
	event      int
}

// Run schedules and executes the reachable steps of g on the given number of
// workers. The state st is updated in place: entries are replaced for steps
// that ran and removed for steps that failed or were cancelled. Output files
// are written to fs as steps complete.
func Run(g *graph.Graph, reach []bool, st *state.State, fs *vfs.FS, workers int) *Result {
	nodes := g.Nodes
	pending := make([]int, len(nodes))
	dependents := make([][]int, len(nodes))
	for n := range nodes {
		if !reach[n] {
			continue
		}
		pending[n] = len(nodes[n].Succ)
		for _, m := range nodes[n].Succ {
			dependents[m] = append(dependents[m], n)
		}
	}

	var undecided, ready heap
	complete := func(n int) {
		work := []int{n}
		for len(work) > 0 {
			x := work[len(work)-1]
			work = work[:len(work)-1]
			for _, d := range dependents[x] {
				pending[d]--
				if pending[d] != 0 {
					continue
				}
				if nodes[d].Kind == graph.StepNode {
					undecided.push(d)
				} else {
					work = append(work, d)
				}
			}
		}
	}
	for n := range nodes {
		if !reach[n] || pending[n] != 0 {
			continue
		}
		if nodes[n].Kind == graph.StepNode {
			undecided.push(n)
		} else {
			complete(n)
		}
	}

	res := &Result{}
	running := make([]slot, workers)
	var time int64
	for {
		// (A) settle cache hits.
		for undecided.len() > 0 {
			n := undecided.pop()
			s := nodes[n].Step
			e, _ := st.Get(s.Primary())
			if state.Fresh(e, s.Canonical(), s.FileInputs, s.FullOutputs, fs) {
				res.Hits++
				res.Events = append(res.Events, Event{Kind: KindHit, Serial: s.Serial, Start: time, End: time,
					Target: s.Primary(), Cmd: s.Canonical()})
				complete(n)
			} else {
				ready.push(n)
			}
		}
		// (B) dispatch.
		for ready.len() > 0 {
			w := -1
			for i := range running {
				if !running[i].busy {
					w = i
					break
				}
			}
			if w < 0 {
				break
			}
			s := nodes[ready.pop()].Step
			sl := &running[w]
			*sl = slot{busy: true, step: s, start: time, end: time + s.Cost, event: len(res.Events)}
			res.Events = append(res.Events, Event{Kind: KindRun, Serial: s.Serial, Start: time, End: sl.end,
				Worker: w, Target: s.Primary(), Cmd: s.Canonical()})
			sl.inputs = make([]cmds.Input, len(s.FileInputs))
			for i, p := range s.FileInputs {
				f := fs.Get(p)
				if f == nil {
					f = vfs.NewFile("")
				}
				sl.inputs[i] = cmds.Input{Path: p, File: f}
			}
			// The command reads everything it needs now; its effects are
			// applied at its end time.
			sl.res, sl.err = s.Spec.Run(s.Cmd, sl.inputs, fs)
		}
		// (C) advance the clock.
		first := true
		for i := range running {
			if running[i].busy && (first || running[i].end < time) {
				time, first = running[i].end, false
			}
		}
		if first {
			break
		}
		var failed []int
		var finished []int
		for w := range running {
			sl := &running[w]
			if !sl.busy || sl.end != time {
				continue
			}
			sl.busy = false
			if sl.err != nil {
				res.Events[sl.event].Kind = KindFail
				failed = append(failed, w)
				continue
			}
			commit(sl, st, fs)
			res.Ran++
			finished = append(finished, w)
		}
		if len(failed) > 0 {
			best := failed[0]
			for _, w := range failed[1:] {
				if running[w].step.Serial < running[best].step.Serial {
					best = w
				}
			}
			res.Err = running[best].err
			for w := range running {
				if running[w].busy {
					res.Events[running[w].event].Kind = KindCancel
					st.Remove(running[w].step.Primary())
					running[w].busy = false
				}
			}
			for _, w := range failed {
				st.Remove(running[w].step.Primary())
			}
			break
		}
		for _, w := range finished {
			complete(running[w].step.Serial)
		}
	}

	for _, ev := range res.Events {
		if ev.End > res.Time {
			res.Time = ev.End
		}
	}
	sort.SliceStable(res.Events, func(i, j int) bool {
		a, b := res.Events[i], res.Events[j]
		if a.Start != b.Start {
			return a.Start < b.Start
		}
		return a.Serial < b.Serial
	})
	return res
}

// commit writes a successful command's outputs and records its state entry.
func commit(sl *slot, st *state.State, fs *vfs.FS) {
	s := sl.step
	fs.Write(s.Primary(), sl.res.Output)
	if s.HasDepfile {
		fs.Write(s.Depfile, sl.res.Depfile)
	}
	e := &state.Entry{Step: s.Primary(), Cmd: s.Canonical()}
	for _, in := range sl.inputs {
		e.In = append(e.In, state.PathHash{Path: in.Path, Hash: in.File.Hash()})
	}
	for _, d := range sl.res.Deps {
		e.Dep = append(e.Dep, state.PathHash{Path: d.Path, Hash: d.File.Hash()})
	}
	for _, p := range s.FullOutputs {
		e.Out = append(e.Out, state.PathHash{Path: p, Hash: fs.Get(p).Hash()})
	}
	st.Put(e)
}
