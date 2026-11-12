package session_test

import (
	"strings"
	"testing"

	"buildsys/session"
	"buildsys/vfs"
)

// runSession runs a script against a workspace given as path/content pairs and
// returns the log and the final file system.
func runSession(t *testing.T, script string, files ...string) (string, *vfs.FS) {
	t.Helper()
	fs := vfs.New()
	for i := 0; i+1 < len(files); i += 2 {
		fs.Write(files[i], files[i+1])
	}
	log, err := session.RunScript(fs, script)
	if err != nil {
		t.Fatal(err)
	}
	return log, fs
}

func lines(s ...string) string { return strings.Join(s, "\n") + "\n" }

const helloKiln = `step {
    out "out/hello.txt"
    cmd write("hello\n")
}
default "out/hello.txt"
`

func TestExample1OneStep(t *testing.T) {
	log, fs := runSession(t, "build\n", "main.kiln", helloKiln)
	want := lines(
		"step 1: build (default) -j 1",
		`  run 0 1 w0 out/hello.txt write("hello\n")`,
		"  ok ran=1 hit=0 time=1",
	)
	if log != want {
		t.Errorf("log:\n%s\nwant:\n%s", log, want)
	}
	if got := fs.Get("out/hello.txt").Content(); got != "hello\n" {
		t.Errorf("out/hello.txt = %q", got)
	}
	state := lines("kiln-state 1", "step out/hello.txt", `cmd write("hello\n")`, "out out/hello.txt a9bc80cca21f28b3", "end")
	if got := fs.Get(".kiln-state").Content(); got != state {
		t.Errorf("state:\n%s\nwant:\n%s", got, state)
	}
}

func TestExample2HitAndTouch(t *testing.T) {
	log, _ := runSession(t, "build\nbuild\ntouch main.kiln\nbuild\n", "main.kiln", helloKiln)
	want := lines(
		"step 1: build (default) -j 1",
		`  run 0 1 w0 out/hello.txt write("hello\n")`,
		"  ok ran=1 hit=0 time=1",
		"step 2: build (default) -j 1",
		"  hit 0 out/hello.txt",
		"  ok ran=0 hit=1 time=0",
		"step 3: touch main.kiln",
		"  ok",
		"step 4: build (default) -j 1",
		"  hit 0 out/hello.txt",
		"  ok ran=0 hit=1 time=0",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
}

func TestExample3ParallelTieBreak(t *testing.T) {
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
	log, fs := runSession(t, "build -j 2\n", "main.kiln", main)
	want := lines(
		"step 1: build (default) -j 2",
		`  run 0 3 w0 out/a.txt write("A\n")`,
		`  run 0 1 w1 out/b.txt write("B\n")`,
		`  run 1 5 w1 out/c.txt write("C\n")`,
		`  run 3 5 w0 out/d.txt write("D\n")`,
		"  run 5 7 w0 out/all.txt concat()",
		"  ok ran=5 hit=0 time=7",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if got := fs.Get("out/all.txt").Content(); got != "A\nB\nC\nD\n" {
		t.Errorf("all.txt = %q", got)
	}
}

func TestExample5RulesAndChain(t *testing.T) {
	main := `rule bundle(name, parts, weight = 2) {
    step {
        out "out/{name}.txt"
        in parts
        cmd concat()
        cost weight
    }
}

let base = ["src/a.txt", "src/b.txt"]
use bundle("one", base)
use bundle(name = "two", parts = base ++ ["out/one.txt"], weight = 5)
phony all = ["out/one.txt", "out/two.txt"]
default "@all"
`
	log, fs := runSession(t, "build -j 2\n", "main.kiln", main, "src/a.txt", "AAA\n", "src/b.txt", "BBB\n")
	want := lines(
		"step 1: build (default) -j 2",
		"  run 0 2 w0 out/one.txt concat()",
		"  run 2 7 w0 out/two.txt concat()",
		"  ok ran=2 hit=0 time=7",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	state := lines("kiln-state 1",
		"step out/one.txt", "cmd concat()",
		"in src/a.txt 8943a78b9f342c58", "in src/b.txt c857dca71c36fafd", "out out/one.txt 5e52e06e8b405ae8", "end",
		"step out/two.txt", "cmd concat()",
		"in src/a.txt 8943a78b9f342c58", "in src/b.txt c857dca71c36fafd", "in out/one.txt 5e52e06e8b405ae8",
		"out out/two.txt f98ee131e7582add", "end")
	if got := fs.Get(".kiln-state").Content(); got != state {
		t.Errorf("state:\n%s", got)
	}
}

func TestExample6GlobIncludeSet(t *testing.T) {
	main := `let mode = "fast"
let flags = []
include "tune.kiln"
when mode == "fast" {
    set flags = flags ++ ["F"]
} otherwise {
    set flags = flags ++ ["S"]
}
let srcs = glob("src/**/*.txt")
step {
    out "out/list.txt"
    in srcs
    cmd count_lines()
}
step {
    out "out/flags.txt"
    cmd write("{join(flags, ",")}\n")
}
default ["out/list.txt", "out/flags.txt"]
`
	log, fs := runSession(t, "build -j 2\n", "main.kiln", main, "tune.kiln", "set mode = \"slow\"\nlet extra = 1\n",
		"src/a.txt", "a1\n", "src/b.txt", "b1\n", "src/sub/c.txt", "c1\n", "src/notes.md", "note\n")
	want := lines(
		"step 1: build (default) -j 2",
		"  run 0 2 w0 out/list.txt count_lines()",
		`  run 0 1 w1 out/flags.txt write("S\n")`,
		"  ok ran=2 hit=0 time=2",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if got := fs.Get("out/list.txt").Content(); got != "1 src/a.txt\n1 src/b.txt\n1 src/sub/c.txt\n3 total\n" {
		t.Errorf("list.txt = %q", got)
	}
}

func TestExample7PreprocessDepfile(t *testing.T) {
	main := `step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/main.txt"
    cmd preprocess()
}
default "out/doc.txt"
`
	script := "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild\n"
	log, fs := runSession(t, script, "main.kiln", main,
		"src/main.txt", "title\n@need src/part.txt\nend\n",
		"src/part.txt", "PART-A\n@need src/deep.txt\n", "src/deep.txt", "DEEP\n")
	want := lines(
		"step 1: build (default) -j 1",
		"  run 0 6 w0 out/doc.txt preprocess()",
		"  ok ran=1 hit=0 time=6",
		"step 2: build (default) -j 1",
		"  hit 0 out/doc.txt",
		"  ok ran=0 hit=1 time=0",
		"step 3: edit src/deep.txt",
		"  ok size=6",
		"step 4: build (default) -j 1",
		"  run 0 6 w0 out/doc.txt preprocess()",
		"  ok ran=1 hit=0 time=6",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if got := fs.Get("out/doc.d").Content(); got != "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n" {
		t.Errorf("doc.d = %q", got)
	}
	state := lines("kiln-state 1", "step out/doc.txt", "cmd preprocess()", "in src/main.txt 993a20756b253540",
		"dep src/deep.txt 06ae7bdd484568d7", "dep src/part.txt a8442a790131f243",
		"out out/doc.txt f755eb555e1be12f", "out out/doc.d ea603661a409bc02", "end")
	if got := fs.Get(".kiln-state").Content(); got != state {
		t.Errorf("state:\n%s", got)
	}
}

func TestExample8EarlyCutoff(t *testing.T) {
	main := `step {
    out "out/mid.txt"
    in "src/a.txt"
    cmd upper()
}
step {
    out "out/final.txt"
    in "out/mid.txt"
    cmd number()
}
default "out/final.txt"
`
	log, _ := runSession(t, "build\nedit src/a.txt\nABC\n---\nbuild\n", "main.kiln", main, "src/a.txt", "abc\n")
	want := lines(
		"step 1: build (default) -j 1",
		"  run 0 2 w0 out/mid.txt upper()",
		"  run 2 4 w0 out/final.txt number()",
		"  ok ran=2 hit=0 time=4",
		"step 2: edit src/a.txt",
		"  ok size=4",
		"step 3: build (default) -j 1",
		"  run 0 2 w0 out/mid.txt upper()",
		"  hit 2 out/final.txt",
		"  ok ran=1 hit=1 time=2",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
}

func TestExample9CycleLeavesWorkspaceUntouched(t *testing.T) {
	main := `step {
    out "out/x.txt"
    in "out/y.txt"
    cmd copy()
}
step {
    out "out/y.txt"
    in "out/x.txt"
    cmd copy()
}
default "out/x.txt"
`
	log, fs := runSession(t, "build\n", "main.kiln", main)
	want := lines("step 1: build (default) -j 1", "  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt")
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if got := fs.Paths(); len(got) != 1 || got[0] != "main.kiln" {
		t.Errorf("workspace = %v", got)
	}
}

func TestExample10ConfigErrors(t *testing.T) {
	tests := []struct{ name, main, want string }{
		{"dup", "step {\n out \"out/z.txt\"\n cmd write(\"1\")\n}\nstep {\n out \"out/z.txt\"\n cmd write(\"2\")\n}\ndefault \"out/z.txt\"\n",
			"E_DUP_OUTPUT out/z.txt"},
		{"missing", "step {\n out \"out/z.txt\"\n in [\"src/a.txt\", \"src/missing.txt\"]\n cmd concat()\n}\ndefault \"out/z.txt\"\n",
			"E_MISSING_INPUT src/missing.txt required by out/z.txt"},
		{"var", "step {\n out \"out/z.txt\"\n cmd write(greeting)\n}\ndefault \"out/z.txt\"\n", "E_UNKNOWN_VAR greeting"},
		{"abort", "let n = 3\nwhen n > 2 {\n    abort \"n too large: {n}\"\n}\n", "E_ABORT n too large: 3"},
		{"nodefault", "step {\n out \"out/z.txt\"\n cmd write(\"ok\")\n}\n", "E_NO_DEFAULT"},
		{"nobuildfile", "", "E_NO_BUILD_FILE main.kiln"},
	}
	for _, tc := range tests {
		files := []string{"src/a.txt", "a\n"}
		if tc.main != "" {
			files = append(files, "main.kiln", tc.main)
		}
		log, fs := runSession(t, "build\n", files...)
		want := "step 1: build (default) -j 1\n  error " + tc.want + "\n"
		if log != want {
			t.Errorf("%s: log %q, want %q", tc.name, log, want)
		}
		if fs.Exists(".kiln-state") {
			t.Errorf("%s: configuration error wrote the state file", tc.name)
		}
	}
}

func TestExample11Clean(t *testing.T) {
	log, fs := runSession(t, "build\nclean\nbuild\n", "main.kiln", helloKiln, "keep.txt", "k")
	want := lines(
		"step 1: build (default) -j 1",
		`  run 0 1 w0 out/hello.txt write("hello\n")`,
		"  ok ran=1 hit=0 time=1",
		"step 2: clean",
		"  remove .kiln-state",
		"  remove out/hello.txt",
		"  ok removed=2",
		"step 3: build (default) -j 1",
		`  run 0 1 w0 out/hello.txt write("hello\n")`,
		"  ok ran=1 hit=0 time=1",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if !fs.Exists("keep.txt") {
		t.Error("clean removed an unrelated file")
	}
}

func TestExample12FailureCancelsWork(t *testing.T) {
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
	log, fs := runSession(t, "build -j 2\n", "main.kiln", main, "src/main.txt", "@need src/gone.txt\n")
	want := lines(
		"step 1: build (default) -j 2",
		"  fail 0 6 w0 out/doc.txt preprocess()",
		`  cancel 0 10 w1 out/slow.txt write("slow\n")`,
		"  error E_NEED_MISSING src/gone.txt needed by src/main.txt",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
	if got := fs.Get(".kiln-state").Content(); got != "kiln-state 1\n" {
		t.Errorf("state = %q", got)
	}
	if fs.Exists("out/slow.txt") {
		t.Error("cancelled step wrote its output")
	}
}

func TestExample13AfterIsOrderOnly(t *testing.T) {
	main := `step {
    out "out/gen.txt"
    in "src/a.txt"
    cmd copy()
}
step {
    out "out/rep.txt"
    after "out/gen.txt"
    cmd write("report\n")
}
phony all = ["out/rep.txt"]
default "@all"
`
	log, _ := runSession(t, "build\nedit src/a.txt\nb\n---\nbuild\n", "main.kiln", main, "src/a.txt", "a\n")
	want := lines(
		"step 1: build (default) -j 1",
		"  run 0 1 w0 out/gen.txt copy()",
		`  run 1 2 w0 out/rep.txt write("report\n")`,
		"  ok ran=2 hit=0 time=2",
		"step 2: edit src/a.txt",
		"  ok size=2",
		"step 3: build (default) -j 1",
		"  run 0 1 w0 out/gen.txt copy()",
		"  hit 1 out/rep.txt",
		"  ok ran=1 hit=1 time=1",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
}

func TestExample14CostAndDependencySet(t *testing.T) {
	v1 := "step {\n    out \"out/j.txt\"\n    in [\"src/a.txt\", \"src/b.txt\"]\n    cmd concat()\n}\ndefault \"out/j.txt\"\n"
	v2 := strings.Replace(v1, "    cmd concat()\n", "    cmd concat()\n    cost 5\n", 1)
	v3 := strings.Replace(v2, `["src/a.txt", "src/b.txt"]`, `["src/b.txt", "src/a.txt"]`, 1)
	script := "build\nedit main.kiln\n" + v2 + "---\nbuild\nedit main.kiln\n" + v3 + "---\nbuild\n"
	log, _ := runSession(t, script, "main.kiln", v1, "src/a.txt", "a\n", "src/b.txt", "a\n")
	want := lines(
		"step 1: build (default) -j 1",
		"  run 0 2 w0 out/j.txt concat()",
		"  ok ran=1 hit=0 time=2",
		"step 2: edit main.kiln",
		"  ok size=111",
		"step 3: build (default) -j 1",
		"  hit 0 out/j.txt",
		"  ok ran=0 hit=1 time=0",
		"step 4: edit main.kiln",
		"  ok size=111",
		"step 5: build (default) -j 1",
		"  run 0 5 w0 out/j.txt concat()",
		"  ok ran=1 hit=0 time=5",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
}

func TestExample15TamperedOutput(t *testing.T) {
	script := "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild\n"
	log, _ := runSession(t, script, "main.kiln", helloKiln)
	run := "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n"
	want := "step 1: build (default) -j 1\n" + run +
		"step 2: edit out/hello.txt\n  ok size=9\n" +
		"step 3: build (default) -j 1\n" + run +
		"step 4: delete out/hello.txt\n  ok\n" +
		"step 5: build (default) -j 1\n" + run
	if log != want {
		t.Errorf("log:\n%s", log)
	}
}

func TestParseScript(t *testing.T) {
	steps, err := session.Parse("# c\n\n  build a b  -j 4 \nbuild x -j\ncreate p\n  keep \n\n# not a comment\n---\nclean\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(steps) != 4 {
		t.Fatalf("got %d steps", len(steps))
	}
	if s := steps[0]; s.Workers != 4 || strings.Join(s.Targets, ",") != "a,b" {
		t.Errorf("step 0 = %+v", s)
	}
	if s := steps[1]; s.Workers != 1 || strings.Join(s.Targets, ",") != "x,-j" {
		t.Errorf("step 1 = %+v", s)
	}
	if s := steps[2]; s.Path != "p" || s.Content != "  keep \n\n# not a comment\n" {
		t.Errorf("step 2 = %+v", s)
	}
	for _, bad := range []string{"bogus\n", "create p\nx\n", "delete\n"} {
		if _, err := session.Parse(bad); err == nil {
			t.Errorf("Parse(%q) succeeded", bad)
		}
	}
}

func TestStateCorruptionAndRecovery(t *testing.T) {
	script := "build\nedit .kiln-state\ngarbage\n---\nbuild\n"
	log, _ := runSession(t, script, "main.kiln", helloKiln)
	if strings.Count(log, "  run 0 1 w0") != 2 {
		t.Errorf("corrupt state should force a rebuild:\n%s", log)
	}
}

func TestWorkerCountAndZeroCost(t *testing.T) {
	main := `step {
    out "out/z.txt"
    cmd write("z")
    cost 0
}
step {
    out "out/y.txt"
    in "out/z.txt"
    cmd copy()
}
default "out/y.txt"
`
	log, _ := runSession(t, "build -j 8\n", "main.kiln", main)
	want := lines(
		"step 1: build (default) -j 8",
		`  run 0 0 w0 out/z.txt write("z")`,
		"  run 0 1 w0 out/y.txt copy()",
		"  ok ran=2 hit=0 time=1",
	)
	if log != want {
		t.Errorf("log:\n%s", log)
	}
}
