package buildsys

import (
	"errors"

	"buildsys/graph"
	"buildsys/kbl"
	"buildsys/kerr"
	"buildsys/sched"
	"buildsys/state"
	"buildsys/vfs"
)

// Options configures one build.
type Options struct {
	// Targets are the requested targets: workspace paths or "@phony" names.
	// If empty, the build file's default targets are built.
	Targets []string
	// Workers is the number of simulated parallel workers (at least 1).
	Workers int
}

// Result is the outcome of one build.
type Result struct {
	// Events lists the cache hits and executed commands, sorted by start time
	// and then step serial.
	Events []sched.Event
	// Err is the build's single error, or nil if it succeeded.
	Err *kerr.Error
	// Ran is the number of commands that executed successfully, Hits the
	// number of cache hits.
	Ran, Hits int
	// Time is the simulated completion time of the build.
	Time int64
	// Executed reports whether the build reached its execution phase. A build
	// that fails during configuration leaves the workspace untouched.
	Executed bool
}

// Build evaluates the workspace's build files and executes the out-of-date
// steps reachable from the requested targets. Output files and the state file
// are written to fs.
//
// The phases are: build file lookup, evaluation, whole-graph validation,
// target resolution, cycle detection, state loading, scheduling and execution,
// and finally writing the state file.
func Build(fs *vfs.FS, opts Options) *Result {
	res := &Result{}
	fail := func(err error) *Result {
		var ke *kerr.Error
		if !errors.As(err, &ke) {
			ke = kerr.New("E_INTERNAL", "%v", err)
		}
		res.Err = ke
		return res
	}

	if !fs.Exists(kbl.MainFile) {
		return fail(kerr.New(kerr.NoBuildFile, kbl.MainFile))
	}
	ev, err := kbl.Evaluate(fs, kbl.MainFile)
	if err != nil {
		return fail(err)
	}
	g, kerrp := graph.New(fs, ev.Steps, ev.Phonies)
	if kerrp != nil {
		return fail(kerrp)
	}
	if kerrp := g.ResolveDefaults(ev.Defaults); kerrp != nil {
		return fail(kerrp)
	}
	targets := opts.Targets
	if len(targets) == 0 {
		targets = ev.Defaults
		if len(targets) == 0 {
			return fail(kerr.New(kerr.NoDefault, ""))
		}
	}
	roots, kerrp := g.Request(targets)
	if kerrp != nil {
		return fail(kerrp)
	}
	reach, kerrp := g.Reachable(roots)
	if kerrp != nil {
		return fail(kerrp)
	}

	st := state.New()
	if f := fs.Get(vfs.StateFile); f != nil {
		st = state.Parse(f.Content())
	}
	workers := max(opts.Workers, 1)
	sr := sched.Run(g, reach, st, fs, workers)
	fs.Write(vfs.StateFile, st.Serialize())

	res.Executed = true
	res.Events, res.Err = sr.Events, sr.Err
	res.Ran, res.Hits, res.Time = sr.Ran, sr.Hits, sr.Time
	return res
}
