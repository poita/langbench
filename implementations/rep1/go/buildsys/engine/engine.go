// Package engine runs a single Kiln build against a workspace: it evaluates the
// build files, validates the graph, simulates the schedule and persists the
// state.
package engine

import (
	"buildsys/graph"
	"buildsys/kbl"
	"buildsys/kerr"
	"buildsys/sched"
	"buildsys/state"
	"buildsys/vfs"
)

// RootFile is the workspace path of the root build file.
const RootFile = "main.kiln"

// Result is the outcome of a build.
type Result struct {
	// Err is nil on success and otherwise the build's single error. It is a
	// *kerr.Error.
	Err error
	// Events lists the hit/run/fail/cancel events, empty for configuration errors.
	Events []sched.Event
	// Ran, Hits and Time are the successful-build summary figures.
	Ran, Hits, Time int
}

// Build performs one build of the given targets (or the default targets if
// none) on the given number of workers (at least 1). Configuration errors
// leave the workspace untouched; once execution starts, .kiln-state is always
// rewritten.
func Build(fs *vfs.FS, targets []string, workers int) *Result {
	if workers < 1 {
		workers = 1
	}
	if !fs.Has(RootFile) {
		return &Result{Err: kerr.New(kerr.NoBuildFile, RootFile)}
	}
	p, err := kbl.Evaluate(fs, RootFile)
	if err != nil {
		return &Result{Err: err}
	}
	g, err := graph.New(p, fs)
	if err != nil {
		return &Result{Err: err}
	}
	sel, err := g.Select(targets)
	if err != nil {
		return &Result{Err: err}
	}
	content, _ := fs.Read(vfs.StateFile)
	st := state.Parse(content)
	sr := sched.Run(g, sel, fs, st, workers)
	fs.Write(vfs.StateFile, st.Format())
	return &Result{Err: sr.Err, Events: sr.Events, Ran: sr.Ran, Hits: sr.Hits, Time: sr.Time}
}
