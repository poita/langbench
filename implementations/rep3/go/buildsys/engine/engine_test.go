package engine

import (
	"testing"

	"buildsys/sched"
	"buildsys/vfs"
)

func ws(files map[string]string) *vfs.FS {
	fs := vfs.New()
	for p, c := range files {
		fs.Write(p, []byte(c))
	}
	return fs
}

const twoSteps = `step {
    out "out/a.txt"
    in "src/a.txt"
    cmd upper()
    cost 2
}
step {
    out "out/b.txt"
    in "out/a.txt"
    cmd copy()
    cost 3
}
step {
    out "out/c.txt"
    cmd write("c")
    cost 4
}
phony all = ["out/b.txt", "out/c.txt"]
default "@all"
`

func TestBuildAndRebuild(t *testing.T) {
	fs := ws(map[string]string{"main.kiln": twoSteps, "src/a.txt": "x\n"})
	r := Build(fs, nil, 2)
	if r.Err != nil || r.Ran != 3 || r.Hits != 0 || r.Time != 5 || !r.Executed {
		t.Fatalf("first build: %+v", r)
	}
	if c, _ := fs.Read("out/b.txt"); string(c) != "X\n" {
		t.Errorf("out/b.txt = %q", c)
	}
	r = Build(fs, nil, 2)
	if r.Err != nil || r.Ran != 0 || r.Hits != 3 || r.Time != 0 {
		t.Fatalf("second build: %+v", r)
	}
	for _, e := range r.Events {
		if e.Kind != sched.KindHit {
			t.Errorf("unexpected event %+v", e)
		}
	}
}

func TestRequestedTargetsLimitWork(t *testing.T) {
	fs := ws(map[string]string{"main.kiln": twoSteps, "src/a.txt": "x\n"})
	r := Build(fs, []string{"out/c.txt"}, 1)
	if r.Err != nil || r.Ran != 1 || fs.Exists("out/a.txt") {
		t.Fatalf("%+v", r)
	}
	// Build of an unreachable step does not touch its state entry.
	r = Build(fs, []string{"@all"}, 1)
	if r.Err != nil || r.Ran != 2 || r.Hits != 1 {
		t.Fatalf("%+v", r)
	}
}

func TestSourceAsTarget(t *testing.T) {
	fs := ws(map[string]string{"main.kiln": twoSteps, "src/a.txt": "x\n"})
	r := Build(fs, []string{"src/a.txt"}, 1)
	if r.Err != nil || r.Ran != 0 || r.Hits != 0 || !r.Executed {
		t.Fatalf("%+v", r)
	}
	if !fs.Exists(".kiln-state") {
		t.Error("state not written")
	}
}

func TestConfigurationErrorsDoNotWrite(t *testing.T) {
	fs := ws(map[string]string{"main.kiln": twoSteps})
	r := Build(fs, nil, 1)
	if r.Err == nil || r.Err.Error() != "E_MISSING_INPUT src/a.txt required by out/a.txt" || r.Executed {
		t.Fatalf("%+v", r)
	}
	if fs.Exists(".kiln-state") {
		t.Error("state written after configuration error")
	}
	r = Build(fs, []string{"nope"}, 1)
	if r.Err == nil {
		t.Error("expected error")
	}
}

func TestCorruptStateRebuildsEverything(t *testing.T) {
	fs := ws(map[string]string{"main.kiln": twoSteps, "src/a.txt": "x\n"})
	Build(fs, nil, 1)
	fs.Write(".kiln-state", []byte("garbage\n"))
	r := Build(fs, nil, 1)
	if r.Ran != 3 || r.Hits != 0 {
		t.Fatalf("%+v", r)
	}
}

func TestCostZeroAndHitCascade(t *testing.T) {
	main := "step {\n out \"out/a\"\n cmd write(\"a\")\n cost 0\n}\nstep {\n out \"out/b\"\n in \"out/a\"\n cmd copy()\n cost 0\n}\ndefault \"out/b\"\n"
	fs := ws(map[string]string{"main.kiln": main})
	r := Build(fs, nil, 1)
	if r.Ran != 2 || r.Time != 0 || len(r.Events) != 2 {
		t.Fatalf("%+v", r)
	}
	if r.Events[0].Start != 0 || r.Events[1].Start != 0 {
		t.Errorf("%+v", r.Events)
	}
}

func TestEventOrdering(t *testing.T) {
	fs := ws(map[string]string{"main.kiln": twoSteps, "src/a.txt": "x\n"})
	r := Build(fs, nil, 4)
	last := int64(-1)
	for _, e := range r.Events {
		if e.Start < last {
			t.Fatalf("events out of order: %+v", r.Events)
		}
		last = e.Start
	}
}
