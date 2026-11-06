package build

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	"kiln/vfs"
)

func workspace(files ...string) *vfs.FS {
	fs := vfs.New()
	for i := 0; i+1 < len(files); i += 2 {
		fs.Write(files[i], []byte(files[i+1]))
	}
	return fs
}

// lines renders a build result like the log does, for easy comparison.
func lines(r *Result) []string {
	var out []string
	for _, e := range r.Events {
		if e.Kind == KindHit {
			out = append(out, fmt.Sprintf("hit %d %s", e.Start, e.Target))
		} else {
			out = append(out, fmt.Sprintf("%s %d %d w%d %s %s", e.Kind, e.Start, e.End, e.Worker, e.Target, e.Cmd))
		}
	}
	if r.Err != nil {
		out = append(out, "error "+r.Err.Error())
	} else {
		out = append(out, fmt.Sprintf("ok ran=%d hit=%d time=%d", r.Ran, r.Hits, r.Time))
	}
	return out
}

func check(t *testing.T, r *Result, want ...string) {
	t.Helper()
	if got := lines(r); !reflect.DeepEqual(got, want) {
		t.Errorf("got:\n  %s\nwant:\n  %s", strings.Join(got, "\n  "), strings.Join(want, "\n  "))
	}
}

const parallel = `
step {
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

func TestParallelSchedule(t *testing.T) {
	fs := workspace("main.kiln", parallel)
	r := Run(fs, Request{Workers: 2})
	check(t, r,
		`run 0 3 w0 out/a.txt write("A\n")`,
		`run 0 1 w1 out/b.txt write("B\n")`,
		`run 1 5 w1 out/c.txt write("C\n")`,
		`run 3 5 w0 out/d.txt write("D\n")`,
		`run 5 7 w0 out/all.txt concat()`,
		`ok ran=5 hit=0 time=7`)
	if d, _ := fs.Read("out/all.txt"); string(d) != "A\nB\nC\nD\n" {
		t.Errorf("all.txt = %q", d)
	}
	if !fs.Exists(".kiln-state") {
		t.Error("state file not written")
	}
	// Second build: everything is a hit at time 0.
	r = Run(fs, Request{Workers: 2})
	check(t, r, "hit 0 out/a.txt", "hit 0 out/b.txt", "hit 0 out/c.txt", "hit 0 out/d.txt",
		"hit 0 out/all.txt", "ok ran=0 hit=5 time=0")
}

func TestEarlyCutoffAndTamper(t *testing.T) {
	src := `
step {
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
	fs := workspace("main.kiln", src, "src/a.txt", "abc\n")
	Run(fs, Request{Workers: 1})
	fs.Write("src/a.txt", []byte("ABC\n"))
	check(t, Run(fs, Request{Workers: 1}),
		"run 0 2 w0 out/mid.txt upper()", "hit 2 out/final.txt", "ok ran=1 hit=1 time=2")
	fs.Write("out/final.txt", []byte("tampered"))
	check(t, Run(fs, Request{Workers: 1}),
		"hit 0 out/mid.txt", "run 0 2 w0 out/final.txt number()", "ok ran=1 hit=1 time=2")
	fs.Delete("out/mid.txt")
	check(t, Run(fs, Request{Workers: 1}),
		"run 0 2 w0 out/mid.txt upper()", "hit 2 out/final.txt", "ok ran=1 hit=1 time=2")
}

func TestStateFileContent(t *testing.T) {
	src := `
step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/main.txt"
    cmd preprocess()
}
default "out/doc.txt"
`
	fs := workspace("main.kiln", src, "src/main.txt", "title\n@need src/part.txt\n", "src/part.txt", "PART\n")
	check(t, Run(fs, Request{Workers: 1}), "run 0 6 w0 out/doc.txt preprocess()", "ok ran=1 hit=0 time=6")
	st, _ := fs.Read(".kiln-state")
	parsed := ParseState(st)
	e := parsed.Entries["out/doc.txt"]
	if e == nil || len(e.Deps) != 1 || e.Deps[0].Path != "src/part.txt" || len(e.Outs) != 2 {
		t.Fatalf("entry = %+v", e)
	}
	if string(parsed.Encode()) != string(st) {
		t.Error("state does not round-trip")
	}
	// Editing the discovered dependency forces a rebuild.
	fs.Write("src/part.txt", []byte("PART2\n"))
	check(t, Run(fs, Request{Workers: 1}), "run 0 6 w0 out/doc.txt preprocess()", "ok ran=1 hit=0 time=6")
	// Deleting the depfile does too.
	fs.Delete("out/doc.d")
	check(t, Run(fs, Request{Workers: 1}), "run 0 6 w0 out/doc.txt preprocess()", "ok ran=1 hit=0 time=6")
}

func TestFailureCancelsAndWritesState(t *testing.T) {
	src := `
step {
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
	fs := workspace("main.kiln", src, "src/main.txt", "@need src/gone.txt\n")
	r := Run(fs, Request{Workers: 2})
	check(t, r,
		`fail 0 6 w0 out/doc.txt preprocess()`,
		`cancel 0 10 w1 out/slow.txt write("slow\n")`,
		`error E_NEED_MISSING src/gone.txt needed by src/main.txt`)
	if d, _ := fs.Read(".kiln-state"); string(d) != "kiln-state 1\n" {
		t.Errorf("state = %q", d)
	}
	if fs.Exists("out/slow.txt") {
		t.Error("cancelled output was written")
	}
}

func TestConfigurationErrorsLeaveWorkspaceUntouched(t *testing.T) {
	cases := map[string]string{
		"step {\n out \"out/x\"\n in \"out/y\"\n cmd copy()\n}\nstep {\n out \"out/y\"\n in \"out/x\"\n cmd copy()\n}\ndefault \"out/x\"\n": "E_CYCLE out/x -> out/y -> out/x",
		"step {\n out \"out/x\"\n in \"out/x\"\n cmd copy()\n}\ndefault \"out/x\"\n":                                                        "E_CYCLE out/x -> out/x",
		"step {\n out \"out/z\"\n cmd write(\"1\")\n}\nstep {\n out \"out/z\"\n cmd write(\"2\")\n}\n":                                      "E_DUP_OUTPUT out/z",
		"step {\n out \"out/z\"\n in \"nope\"\n cmd copy()\n}\ndefault \"out/z\"\n":                                                         "E_MISSING_INPUT nope required by out/z",
		"step {\n out \"out/z\"\n cmd write(\"1\")\n}\n":                                                                                    "E_NO_DEFAULT",
		"default \"nope\"\n":   "E_UNKNOWN_TARGET nope",
		"phony p = [\"@q\"]\n": "E_MISSING_INPUT @q required by @p",
	}
	for src, want := range cases {
		fs := workspace("main.kiln", src)
		r := Run(fs, Request{Workers: 1})
		if r.Err == nil || r.Err.Error() != want {
			t.Errorf("%q: got %v, want %s", src, r.Err, want)
		}
		if fs.Len() != 1 {
			t.Errorf("%q: workspace changed: %v", src, fs.Paths())
		}
	}
	if r := Run(workspace(), Request{Workers: 1}); r.Err == nil || r.Err.Error() != "E_NO_BUILD_FILE main.kiln" {
		t.Errorf("no build file: %v", r.Err)
	}
	// An explicit unknown target is reported even though defaults exist.
	fs := workspace("main.kiln", "step {\n out \"out/z\"\n cmd write(\"1\")\n}\ndefault \"out/z\"\n")
	if r := Run(fs, Request{Targets: []string{"out/q"}, Workers: 1}); r.Err == nil || r.Err.Error() != "E_UNKNOWN_TARGET out/q" {
		t.Errorf("unknown target: %v", r.Err)
	}
}

func TestAfterIsOrderOnlyAndUnreachableNotRun(t *testing.T) {
	src := `
step {
    out "out/gen.txt"
    in "src/a.txt"
    cmd copy()
}
step {
    out "out/rep.txt"
    after "out/gen.txt"
    cmd write("report\n")
}
step {
    out "out/unused.txt"
    cmd write("u")
}
phony all = ["out/rep.txt"]
default "@all"
`
	fs := workspace("main.kiln", src, "src/a.txt", "a\n")
	check(t, Run(fs, Request{Workers: 1}), "run 0 1 w0 out/gen.txt copy()", "run 1 2 w0 out/rep.txt write(\"report\\n\")", "ok ran=2 hit=0 time=2")
	if fs.Exists("out/unused.txt") {
		t.Error("unreachable step ran")
	}
	fs.Write("src/a.txt", []byte("b\n"))
	check(t, Run(fs, Request{Workers: 1}), "run 0 1 w0 out/gen.txt copy()", "hit 1 out/rep.txt", "ok ran=1 hit=1 time=1")
}

func TestZeroCostAndHitCascade(t *testing.T) {
	src := `
step {
    out "out/z.txt"
    cmd write("z")
    cost 0
}
default "out/z.txt"
`
	fs := workspace("main.kiln", src)
	check(t, Run(fs, Request{Workers: 3}), `run 0 0 w0 out/z.txt write("z")`, "ok ran=1 hit=0 time=0")
}

func TestStateParsing(t *testing.T) {
	good := "kiln-state 1\nstep out/a\ncmd copy()\nin src/x 0000000000000001\ndep d 0000000000000002\nout out/a 00000000000000ff\nend\n"
	if n := len(ParseState([]byte(good)).Entries); n != 1 {
		t.Fatalf("good state parsed to %d entries", n)
	}
	bad := []string{
		"",
		"kiln-state 1",                        // unterminated last line
		"kiln-state 2\n",                      // wrong version
		strings.Replace(good, "end\n", "", 1), // unterminated entry
		strings.Replace(good, "cmd copy()\n", "", 1),
		strings.Replace(good, "00000000000000ff", "00000000000000FF", 1),
		strings.Replace(good, "step out/a", "step out/b", 1),
		strings.Replace(good, "in src/x", "in src/x extra", 1),
		strings.Replace(good, "cmd copy()\n", "cmd \n", 1),
		strings.Replace(good, "dep d 0000000000000002\n", "", 1) + good[len("kiln-state 1\n"):],     // duplicate key
		"kiln-state 1\nstep out/a\ncmd c\nout out/a 0000000000000001\nin x 0000000000000001\nend\n", // misordered
		"kiln-state 1\nstep out/a\ncmd c\nend\n",                                                    // no out
		"kiln-state 1\nstep ../a\ncmd c\nout ../a 0000000000000001\nend\n",                          // bad path
	}
	for _, b := range bad {
		if n := len(ParseState([]byte(b)).Entries); n != 0 {
			t.Errorf("corrupt state accepted: %q", b)
		}
	}
	// Unsorted entries are accepted on read, and written sorted.
	two := "kiln-state 1\nstep out/b\ncmd c\nout out/b 0000000000000001\nend\nstep out/a\ncmd c\nout out/a 0000000000000001\nend\n"
	st := ParseState([]byte(two))
	if len(st.Entries) != 2 || !strings.HasPrefix(string(st.Encode()), "kiln-state 1\nstep out/a\n") {
		t.Errorf("unsorted state handling wrong: %q", st.Encode())
	}
}

func TestHeap(t *testing.T) {
	var h minHeap
	for _, x := range []int{5, 3, 9, 1, 7, 3} {
		h.push(x)
	}
	var got []int
	for len(h) > 0 {
		got = append(got, h.pop())
	}
	if !reflect.DeepEqual(got, []int{1, 3, 3, 5, 7, 9}) {
		t.Errorf("heap order = %v", got)
	}
}
