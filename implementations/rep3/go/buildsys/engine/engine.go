// Package engine runs one Kiln build against a virtual file system: it
// evaluates the build files, validates and walks the graph, runs the
// simulated scheduler, and persists the build state.
package engine

import (
	"buildsys/diag"
	"buildsys/graph"
	"buildsys/kbl"
	"buildsys/sched"
	"buildsys/state"
	"buildsys/vfs"
)

// RootFile is the workspace path of the root build file.
const RootFile = "main.kiln"

// Report describes the outcome of a build.
type Report struct {
	// Events are the hit/run/fail/cancel events, sorted by start time then
	// step serial. Empty when the build failed during configuration.
	Events []sched.Event
	Ran    int
	Hits   int
	// Time is the completion time of a successful build.
	Time int64
	// Err is the build's error (a *diag.Error), or nil on success.
	Err error
	// Executed is true if the build reached its execution phase, in which
	// case .kiln-state was (re)written.
	Executed bool
}

// Build performs one build of the given targets (or the default targets when
// none are given) on the given number of workers. On a configuration error the
// workspace is left untouched.
func Build(fs *vfs.FS, targets []string, workers int) *Report {
	rep := &Report{}
	fail := func(err error) *Report { rep.Err = err; return rep }

	if !fs.Exists(RootFile) {
		return fail(diag.New(diag.NoBuildFile, RootFile))
	}
	b, err := kbl.Evaluate(fs, RootFile)
	if err != nil {
		return fail(err)
	}
	g, err := graph.New(b, fs)
	if err != nil {
		return fail(err)
	}
	roots, err := g.Requested(targets)
	if err != nil {
		return fail(err)
	}
	reach, err := g.Reach(roots)
	if err != nil {
		return fail(err)
	}

	data, _ := fs.Read(vfs.StateFile)
	st := state.Parse(data)
	res := sched.Run(sched.Config{Graph: g, Reach: reach, FS: fs, State: st, Workers: workers})
	fs.Write(vfs.StateFile, st.Encode())

	rep.Executed = true
	rep.Events, rep.Ran, rep.Hits, rep.Time, rep.Err = res.Events, res.Ran, res.Hits, res.Time, res.Err
	return rep
}
