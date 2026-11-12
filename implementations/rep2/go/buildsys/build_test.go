package buildsys_test

import (
	"testing"

	"buildsys"
	"buildsys/sched"
	"buildsys/vfs"
)

const twoSteps = `
step {
    out "out/a.txt"
    in "src/a.txt"
    cmd upper()
}
step {
    out "out/b.txt"
    in "src/b.txt"
    cmd upper()
}
phony all = ["out/a.txt", "out/b.txt"]
default "@all"
`

func newFS() *vfs.FS {
	fs := vfs.New()
	fs.Write("main.kiln", twoSteps)
	fs.Write("src/a.txt", "a\n")
	fs.Write("src/b.txt", "b\n")
	return fs
}

func TestRequestedTargetsLimitWork(t *testing.T) {
	fs := newFS()
	res := buildsys.Build(fs, buildsys.Options{Targets: []string{"out/a.txt"}, Workers: 4})
	if res.Err != nil || res.Ran != 1 || fs.Exists("out/b.txt") {
		t.Fatalf("res = %+v, b exists = %v", res, fs.Exists("out/b.txt"))
	}
	// Unreachable steps keep (and never touch) their state entries.
	res = buildsys.Build(fs, buildsys.Options{Workers: 1})
	if res.Err != nil || res.Ran != 1 || res.Hits != 1 || res.Time != 2 {
		t.Fatalf("second build = %+v", res)
	}
}

func TestConfigErrorDoesNotTouchWorkspace(t *testing.T) {
	fs := newFS()
	res := buildsys.Build(fs, buildsys.Options{Targets: []string{"nope"}})
	if res.Err == nil || res.Err.Error() != "E_UNKNOWN_TARGET nope" || res.Executed {
		t.Fatalf("res = %+v", res)
	}
	if fs.Exists(vfs.StateFile) || fs.Exists("out/a.txt") {
		t.Error("workspace changed by a configuration error")
	}
}

func TestStateWrittenEvenWhenNothingRuns(t *testing.T) {
	fs := newFS()
	buildsys.Build(fs, buildsys.Options{})
	fs.Delete(vfs.StateFile)
	fs.Write(vfs.StateFile, "kiln-state 1\n")
	res := buildsys.Build(fs, buildsys.Options{})
	if res.Ran != 2 || !res.Executed {
		t.Fatalf("res = %+v", res)
	}
	if fs.Get(vfs.StateFile).Content() == "kiln-state 1\n" {
		t.Error("state not rewritten")
	}
}

func TestEventOrder(t *testing.T) {
	fs := newFS()
	res := buildsys.Build(fs, buildsys.Options{Workers: 2})
	if len(res.Events) != 2 {
		t.Fatalf("events = %+v", res.Events)
	}
	for i, ev := range res.Events {
		if ev.Kind != sched.KindRun || ev.Worker != i || ev.Serial != i || ev.Start != 0 || ev.End != 2 {
			t.Errorf("event %d = %+v", i, ev)
		}
	}
}

func TestFailureSelectsLowestSerial(t *testing.T) {
	fs := vfs.New()
	fs.Write("main.kiln", `
step {
    out "out/b.txt"
    in "src/b.txt"
    depfile "out/b.d"
    cmd preprocess()
}
step {
    out "out/a.txt"
    in "src/a.txt"
    depfile "out/a.d"
    cmd preprocess()
}
default ["out/a.txt", "out/b.txt"]
`)
	fs.Write("src/a.txt", "@need src/missing-a\n")
	fs.Write("src/b.txt", "@need src/missing-b\n")
	res := buildsys.Build(fs, buildsys.Options{Workers: 2})
	if res.Err == nil || res.Err.Error() != "E_NEED_MISSING src/missing-b needed by src/b.txt" {
		t.Fatalf("err = %v", res.Err)
	}
	for _, ev := range res.Events {
		if ev.Kind != sched.KindFail {
			t.Errorf("event %+v should be a fail", ev)
		}
	}
}
