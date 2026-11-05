package session

import (
	"reflect"
	"testing"

	"buildsys/vfs"
)

func run(t *testing.T, files map[string]string, script string) (string, *vfs.FS) {
	t.Helper()
	fs := vfs.New()
	for p, c := range files {
		fs.Write(p, []byte(c))
	}
	log, err := RunScript(fs, []byte(script))
	if err != nil {
		t.Fatal(err)
	}
	return string(log), fs
}

func content(fs *vfs.FS, p string) string {
	c, _ := fs.Read(p)
	return string(c)
}

func TestParseScript(t *testing.T) {
	script := "# comment\n\n  \t\nbuild @a  out/b -j 4\nbuild -j\nbuild -j 3 -j 2\nbuild\ncreate x.txt\n  keep  \n\n# not a comment\n---\ntouch x.txt\ndelete x.txt\nclean\n"
	steps, err := ParseScript([]byte(script))
	if err != nil {
		t.Fatal(err)
	}
	if len(steps) != 8 {
		t.Fatalf("%d steps: %+v", len(steps), steps)
	}
	if !reflect.DeepEqual(steps[0].Targets, []string{"@a", "out/b"}) || steps[0].Jobs != 4 {
		t.Errorf("step 0: %+v", steps[0])
	}
	if !reflect.DeepEqual(steps[1].Targets, []string{"-j"}) || steps[1].Jobs != 1 {
		t.Errorf("-j as a target: %+v", steps[1])
	}
	if !reflect.DeepEqual(steps[2].Targets, []string{"-j", "3"}) || steps[2].Jobs != 2 {
		t.Errorf("step 2: %+v", steps[2])
	}
	if steps[3].Jobs != 1 || len(steps[3].Targets) != 0 {
		t.Errorf("step 3: %+v", steps[3])
	}
	if steps[4].Kind != StepCreate || string(steps[4].Content) != "  keep  \n\n# not a comment\n" {
		t.Errorf("create: %q", steps[4].Content)
	}
	if steps[5].Kind != StepTouch || steps[6].Kind != StepDelete || steps[7].Kind != StepClean {
		t.Errorf("kinds: %+v", steps[5:])
	}
}

func TestParseScriptErrors(t *testing.T) {
	for _, s := range []string{"create x\nno end\n", "frobnicate\n", "touch\n", "build -j x\n"} {
		if _, err := ParseScript([]byte(s)); err == nil {
			t.Errorf("%q accepted", s)
		}
	}
	steps, err := ParseScript(nil)
	if err != nil || len(steps) != 0 {
		t.Error("empty script")
	}
}

const hello = "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n"

func TestExample1And2(t *testing.T) {
	log, fs := run(t, map[string]string{"main.kiln": hello}, "build\nbuild\ntouch main.kiln\nbuild\n")
	want := `step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
step 3: touch main.kiln
  ok
step 4: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
`
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if got := content(fs, ".kiln-state"); got != "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\nout out/hello.txt a9bc80cca21f28b3\nend\n" {
		t.Errorf("state:\n%s", got)
	}
}

func TestParallelTieBreak(t *testing.T) {
	main := `step {
    out "out/a.txt"
    cmd write("A\n")
    cost 3
}
step {
    out "out/b.txt"
    cmd write("B\n")
    cost 1
}
step {
    out "out/c.txt"
    cmd write("C\n")
    cost 4
}
step {
    out "out/d.txt"
    cmd write("D\n")
    cost 2
}
step {
    out "out/all.txt"
    in ["out/a.txt", "out/b.txt", "out/c.txt", "out/d.txt"]
    cmd concat()
    cost 2
}
default "out/all.txt"
`
	log, fs := run(t, map[string]string{"main.kiln": main}, "build -j 2\n")
	want := `step 1: build (default) -j 2
  run 0 3 w0 out/a.txt write("A\n")
  run 0 1 w1 out/b.txt write("B\n")
  run 1 5 w1 out/c.txt write("C\n")
  run 3 5 w0 out/d.txt write("D\n")
  run 5 7 w0 out/all.txt concat()
  ok ran=5 hit=0 time=7
`
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if content(fs, "out/all.txt") != "A\nB\nC\nD\n" {
		t.Error("all.txt")
	}
}

func TestEarlyCutoff(t *testing.T) {
	main := "step {\n out \"out/mid.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\nstep {\n out \"out/final.txt\"\n in \"out/mid.txt\"\n cmd number()\n}\ndefault \"out/final.txt\"\n"
	log, _ := run(t, map[string]string{"main.kiln": main, "src/a.txt": "abc\n"}, "build\nedit src/a.txt\nABC\n---\nbuild\n")
	want := `step 1: build (default) -j 1
  run 0 2 w0 out/mid.txt upper()
  run 2 4 w0 out/final.txt number()
  ok ran=2 hit=0 time=4
step 2: edit src/a.txt
  ok size=4
step 3: build (default) -j 1
  run 0 2 w0 out/mid.txt upper()
  hit 2 out/final.txt
  ok ran=1 hit=1 time=2
`
	if log != want {
		t.Errorf("log:\n%s", log)
	}
}

func TestFailureCancelsAndWritesEmptyState(t *testing.T) {
	main := `step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/main.txt"
    cmd preprocess()
}
step {
    out "out/slow.txt"
    cmd write("slow\n")
    cost 10
}
step {
    out "out/after.txt"
    in "out/doc.txt"
    cmd copy()
}
phony all = ["out/doc.txt", "out/slow.txt", "out/after.txt"]
default "@all"
`
	log, fs := run(t, map[string]string{"main.kiln": main, "src/main.txt": "@need src/gone.txt\n"}, "build -j 2\n")
	want := `step 1: build (default) -j 2
  fail 0 6 w0 out/doc.txt preprocess()
  cancel 0 10 w1 out/slow.txt write("slow\n")
  error E_NEED_MISSING src/gone.txt needed by src/main.txt
`
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if content(fs, ".kiln-state") != "kiln-state 1\n" || fs.Exists("out/slow.txt") {
		t.Error("state/outputs after failure")
	}
}

func TestConfigErrorLeavesWorkspaceUntouched(t *testing.T) {
	main := "step {\n out \"out/x.txt\"\n in \"out/y.txt\"\n cmd copy()\n}\nstep {\n out \"out/y.txt\"\n in \"out/x.txt\"\n cmd copy()\n}\ndefault \"out/x.txt\"\n"
	log, fs := run(t, map[string]string{"main.kiln": main}, "build\n")
	if log != "step 1: build (default) -j 1\n  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt\n" {
		t.Errorf("log:\n%s", log)
	}
	if fs.Len() != 1 {
		t.Errorf("workspace changed: %v", fs.Paths())
	}
	log, _ = run(t, nil, "build\n")
	if log != "step 1: build (default) -j 1\n  error E_NO_BUILD_FILE main.kiln\n" {
		t.Errorf("log:\n%s", log)
	}
}

func TestAfterIsOrderOnlyAndCostIsNotAChange(t *testing.T) {
	main := "step {\n out \"out/gen.txt\"\n in \"src/a.txt\"\n cmd copy()\n}\nstep {\n out \"out/rep.txt\"\n after \"out/gen.txt\"\n cmd write(\"report\\n\")\n}\nphony all = [\"out/rep.txt\"]\ndefault \"@all\"\n"
	log, _ := run(t, map[string]string{"main.kiln": main, "src/a.txt": "a\n"}, "build\nedit src/a.txt\nb\n---\nbuild\n")
	want := `step 1: build (default) -j 1
  run 0 1 w0 out/gen.txt copy()
  run 1 2 w0 out/rep.txt write("report\n")
  ok ran=2 hit=0 time=2
step 2: edit src/a.txt
  ok size=2
step 3: build (default) -j 1
  run 0 1 w0 out/gen.txt copy()
  hit 1 out/rep.txt
  ok ran=1 hit=1 time=1
`
	if log != want {
		t.Errorf("log:\n%s", log)
	}
}

func TestCleanAndTamper(t *testing.T) {
	log, fs := run(t, map[string]string{"main.kiln": hello}, "build\nedit out/hello.txt\ntampered\n---\nbuild\nclean\nbuild\n")
	want := `step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: edit out/hello.txt
  ok size=9
step 3: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 4: clean
  remove .kiln-state
  remove out/hello.txt
  ok removed=2
step 5: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
`
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if content(fs, "out/hello.txt") != "hello\n" {
		t.Error("final output")
	}
}
