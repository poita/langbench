// Package sched simulates a build on N parallel workers with an integer clock,
// deciding freshness, dispatching steps deterministically and executing their
// commands against the virtual file system.
package sched

import (
	"container/heap"
	"sort"

	"buildsys/cmds"
	"buildsys/graph"
	"buildsys/state"
	"buildsys/vfs"
)

// EventKind classifies a log event.
type EventKind uint8

// Event kinds.
const (
	EvHit EventKind = iota
	EvRun
	EvFail
	EvCancel
)

func (k EventKind) String() string {
	return [...]string{"hit", "run", "fail", "cancel"}[k]
}

// Event is one line of a build's log. For a hit, Start == End == the time.
type Event struct {
	Kind    EventKind
	Serial  int
	Start   int
	End     int
	Worker  int
	Target  string
	Command string
}

// Result is the outcome of a simulated build.
type Result struct {
	Events []Event // sorted by start time, then serial
	Ran    int
	Hits   int
	Time   int
	Err    error // execution error, if the build failed
}

type intHeap []int

func (h intHeap) Len() int           { return len(h) }
func (h intHeap) Less(i, j int) bool { return h[i] < h[j] }
func (h intHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *intHeap) Push(x any)        { *h = append(*h, x.(int)) }
func (h *intHeap) Pop() any {
	old := *h
	x := old[len(old)-1]
	*h = old[:len(old)-1]
	return x
}

type job struct {
	serial     int
	start, end int
	event      int // index into events
}

type simulation struct {
	g       *graph.Graph
	fs      *vfs.FS
	st      *state.State
	pending []int
	rev     [][]int
	done    []bool

	undecided intHeap // ready steps whose freshness is not yet decided
	stale     intHeap // ready steps decided stale, awaiting a worker

	events []Event
	hits   int
}

// Run simulates the build of the selected part of the graph. State entries are
// updated in st as steps execute; the caller persists them.
func Run(g *graph.Graph, sel *graph.Selection, fs *vfs.FS, st *state.State, workers int) *Result {
	s := &simulation{
		g: g, fs: fs, st: st,
		pending: make([]int, len(g.Nodes)),
		rev:     make([][]int, len(g.Nodes)),
		done:    make([]bool, len(g.Nodes)),
	}
	for n, node := range g.Nodes {
		if !sel.Reachable[n] {
			continue
		}
		s.pending[n] = len(node.Succ)
		for _, m := range node.Succ {
			s.rev[m] = append(s.rev[m], n)
		}
	}
	// Initialisation: steps with no dependencies are ready; sources complete at
	// time 0, as do phonies with no dependencies, cascading.
	for n, node := range g.Nodes {
		if sel.Reachable[n] && node.Kind == graph.Step && s.pending[n] == 0 {
			heap.Push(&s.undecided, n)
		}
	}
	for n, node := range g.Nodes {
		if sel.Reachable[n] && node.Kind != graph.Step && s.pending[n] == 0 && !s.done[n] {
			s.complete(n)
		}
	}

	res := &Result{}
	running := make([]*job, workers)
	nrunning := 0
	time := 0
	maxEnd := 0
loop:
	for {
		// (A) settle cache hits at the current time.
		for s.undecided.Len() > 0 {
			n := heap.Pop(&s.undecided).(int)
			step := g.Nodes[n].Step
			if state.Fresh(st.Get(step.Primary()), step, fs) {
				s.hits++
				s.events = append(s.events, Event{Kind: EvHit, Serial: n, Start: time, End: time,
					Target: step.Primary(), Command: step.Command})
				maxEnd = max(maxEnd, time)
				s.complete(n)
			} else {
				heap.Push(&s.stale, n)
			}
		}
		// (B) dispatch.
		for s.stale.Len() > 0 && nrunning < workers {
			n := heap.Pop(&s.stale).(int)
			step := g.Nodes[n].Step
			w := 0
			for running[w] != nil {
				w++
			}
			s.events = append(s.events, Event{Kind: EvRun, Serial: n, Start: time, End: time + step.Cost,
				Worker: w, Target: step.Primary(), Command: step.Command})
			running[w] = &job{serial: n, start: time, end: time + step.Cost, event: len(s.events) - 1}
			nrunning++
			maxEnd = max(maxEnd, time+step.Cost)
		}
		// (C) advance the clock.
		if nrunning == 0 {
			break
		}
		time = -1
		for _, j := range running {
			if j != nil && (time < 0 || j.end < time) {
				time = j.end
			}
		}
		type outcome struct {
			serial int
			err    error
		}
		var finished []int
		var failed []outcome
		for w, j := range running {
			if j == nil || j.end != time {
				continue
			}
			running[w] = nil
			nrunning--
			step := g.Nodes[j.serial].Step
			r, err := cmds.Run(step.Spec, step.Args, step.FileInputs, fs)
			if err != nil {
				s.events[j.event].Kind = EvFail
				failed = append(failed, outcome{j.serial, err})
				continue
			}
			fs.Write(step.Primary(), r.Out)
			if step.Depfile != "" {
				fs.Write(step.Depfile, r.Depfile)
			}
			st.Put(state.Capture(step, r.Discovered, fs))
			res.Ran++
			finished = append(finished, j.serial)
		}
		if len(failed) > 0 {
			first := failed[0] // workers are scanned in order; pick the lowest serial
			for _, f := range failed[1:] {
				if f.serial < first.serial {
					first = f
				}
			}
			res.Err = first.err
			for w, j := range running {
				if j == nil {
					continue
				}
				s.events[j.event].Kind = EvCancel
				st.Delete(g.Nodes[j.serial].Step.Primary())
				running[w] = nil
			}
			for _, f := range failed {
				st.Delete(g.Nodes[f.serial].Step.Primary())
			}
			break loop
		}
		for _, n := range finished {
			s.complete(n)
		}
	}

	sort.SliceStable(s.events, func(i, j int) bool {
		a, b := s.events[i], s.events[j]
		if a.Start != b.Start {
			return a.Start < b.Start
		}
		return a.Serial < b.Serial
	})
	res.Events = s.events
	res.Hits = s.hits
	res.Time = maxEnd
	return res
}

// complete marks node n done and releases its dependents, cascading through
// source and phony nodes.
func (s *simulation) complete(n int) {
	s.done[n] = true
	for _, d := range s.rev[n] {
		s.pending[d]--
		if s.pending[d] != 0 {
			continue
		}
		if s.g.Nodes[d].Kind == graph.Step {
			heap.Push(&s.undecided, d)
		} else {
			s.complete(d)
		}
	}
}
