// Package sched simulates the execution of a build on a fixed number of
// workers: it decides which steps are fresh, dispatches the stale ones in
// serial order to the lowest-numbered free worker, advances a deterministic
// clock, runs the in-process commands against the virtual file system, and
// maintains the persisted state.
package sched

import (
	"sort"

	"buildsys/cmds"
	"buildsys/graph"
	"buildsys/plan"
	"buildsys/state"
	"buildsys/vfs"
)

// EventKind classifies a scheduler event.
type EventKind uint8

// Event kinds.
const (
	KindHit    EventKind = iota // a cache hit
	KindRun                     // a command that executed successfully
	KindFail                    // a command that raised an execution error
	KindCancel                  // a command still running when the build aborted
)

// Event is one line of a build's log: a cache hit (Start == End == the time,
// Worker == -1) or one command execution.
type Event struct {
	Kind   EventKind
	Step   *plan.Step
	Start  int64
	End    int64
	Worker int
}

// Config is the input of Run.
type Config struct {
	Graph   *graph.Graph
	Reach   []bool // reachable nodes, as returned by Graph.Reach
	FS      *vfs.FS
	State   state.State // modified in place
	Workers int
}

// Result is the outcome of Run.
type Result struct {
	// Events are sorted by start time, then step serial.
	Events []Event
	Ran    int
	Hits   int
	// Time is the build's completion time.
	Time int64
	// Err is the execution error that aborted the build, or nil.
	Err error
}

type running struct {
	step       *plan.Step
	start, end int64
	event      int
	result     cmds.Result
	err        error
	ins        []state.PathHash
	deps       []state.PathHash
}

// Run executes the reachable steps of cfg.Graph.
func Run(cfg Config) Result {
	g, fs, st := cfg.Graph, cfg.FS, cfg.State
	n := g.NumNodes()
	pending := make([]int, n)
	dependents := make([][]int, n)
	for node := 0; node < n; node++ {
		if !cfg.Reach[node] {
			continue
		}
		succ := g.Successors(node)
		pending[node] = len(succ)
		for _, m := range succ {
			dependents[m] = append(dependents[m], node)
		}
	}

	var undecided, stale minHeap
	var scratch []int
	complete := func(start int) {
		scratch = append(scratch[:0], start)
		for len(scratch) > 0 {
			x := scratch[len(scratch)-1]
			scratch = scratch[:len(scratch)-1]
			for _, d := range dependents[x] {
				pending[d]--
				if pending[d] != 0 {
					continue
				}
				if g.NodeKind(d) == graph.StepNode {
					undecided.push(d)
				} else {
					scratch = append(scratch, d)
				}
			}
		}
	}
	for node := 0; node < n; node++ {
		if !cfg.Reach[node] || pending[node] != 0 {
			continue
		}
		if g.NodeKind(node) == graph.StepNode {
			undecided.push(node)
		} else {
			complete(node)
		}
	}

	var res Result
	workers := make([]*running, cfg.Workers)
	var time int64
	for {
		// (A) settle cache hits at the current time.
		for undecided.len() > 0 {
			id := undecided.pop()
			s := g.Step(id)
			if st[s.Primary()].Fresh(s.CmdString, s.FileInputs, s.FullOuts, fs) {
				res.Hits++
				res.Events = append(res.Events, Event{Kind: KindHit, Step: s, Start: time, End: time, Worker: -1})
				complete(id)
			} else {
				stale.push(id)
			}
		}

		// (B) dispatch stale steps to free workers, lowest id first.
		for w := 0; w < len(workers) && stale.len() > 0; w++ {
			if workers[w] != nil {
				continue
			}
			s := g.Step(stale.pop())
			r := &running{step: s, start: time, end: time + s.Cost, event: len(res.Events)}
			res.Events = append(res.Events, Event{Kind: KindRun, Step: s, Start: r.start, End: r.end, Worker: w})
			execute(r, fs)
			workers[w] = r
		}

		// (C) advance the clock to the earliest finishing command.
		next, any := int64(0), false
		for _, r := range workers {
			if r != nil && (!any || r.end < next) {
				next, any = r.end, true
			}
		}
		if !any {
			break
		}
		time = next
		var finished, failed []*running
		for w, r := range workers {
			if r == nil || r.end != time {
				continue
			}
			workers[w] = nil
			if r.err != nil {
				res.Events[r.event].Kind = KindFail
				failed = append(failed, r)
				continue
			}
			commit(r, fs, st)
			res.Ran++
			finished = append(finished, r)
		}
		if len(failed) > 0 {
			first := failed[0]
			for _, f := range failed[1:] {
				if f.step.Serial < first.step.Serial {
					first = f
				}
			}
			res.Err = first.err
			for _, r := range workers {
				if r != nil {
					res.Events[r.event].Kind = KindCancel
					delete(st, r.step.Primary())
				}
			}
			for _, f := range failed {
				delete(st, f.step.Primary())
			}
			break
		}
		for _, r := range finished {
			complete(r.step.Serial)
		}
	}

	for _, e := range res.Events {
		if e.End > res.Time {
			res.Time = e.End
		}
	}
	sort.SliceStable(res.Events, func(i, j int) bool {
		a, b := res.Events[i], res.Events[j]
		if a.Start != b.Start {
			return a.Start < b.Start
		}
		return a.Step.Serial < b.Step.Serial
	})
	return res
}

// execute captures the step's inputs at dispatch time and computes what the
// command will write; the files are only written when the command ends.
func execute(r *running, fs *vfs.FS) {
	s := r.step
	inputs := make([]cmds.Input, len(s.FileInputs))
	r.ins = make([]state.PathHash, len(s.FileInputs))
	for i, p := range s.FileInputs {
		c, _ := fs.Read(p)
		h, _ := fs.Hash(p)
		inputs[i] = cmds.Input{Path: p, Content: c, Hash: h}
		r.ins[i] = state.PathHash{Path: p, Hash: h}
	}
	r.result, r.err = cmds.Execute(s.Cmd, inputs, fs)
	if r.err != nil {
		return
	}
	for _, p := range r.result.Deps {
		h, _ := fs.Hash(p)
		r.deps = append(r.deps, state.PathHash{Path: p, Hash: h})
	}
}

// commit writes a finished command's outputs and replaces its state entry.
func commit(r *running, fs *vfs.FS, st state.State) {
	s := r.step
	fs.Write(s.Outs[0], r.result.Out)
	if s.Depfile != "" {
		fs.Write(s.Depfile, r.result.Depfile)
	}
	outs := make([]state.PathHash, len(s.FullOuts))
	for i, p := range s.FullOuts {
		h, _ := fs.Hash(p)
		outs[i] = state.PathHash{Path: p, Hash: h}
	}
	st[s.Primary()] = &state.Entry{Cmd: s.CmdString, Ins: r.ins, Deps: r.deps, Outs: outs}
}
