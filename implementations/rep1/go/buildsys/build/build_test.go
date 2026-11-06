package build_test

import (
	"strings"
	"testing"

	"buildsys/build"
	"buildsys/vfs"
)

func workspace(files ...string) *vfs.FS {
	fs := vfs.New()
	for i := 0; i+1 < len(files); i += 2 {
		fs.Write(files[i], []byte(files[i+1]))
	}
	return fs
}

// render prints a result the way the session log does.
func render(r *build.Result) string {
	var sb strings.Builder
	for _, e := range r.Events {
		switch e.Kind {
		case build.KindHit:
			sb.WriteString("hit " + itoa(e.Start) + " " + e.Target + "\n")
		default:
			word := map[build.EventKind]string{build.KindRun: "run", build.KindFail: "fail", build.KindCancel: "cancel"}[e.Kind]
			sb.WriteString(word + " " + itoa(e.Start) + " " + itoa(e.End) + " w" + itoa(int64(e.Worker)) + " " + e.Target + " " + e.Command + "\n")
		}
	}
	if r.Err != nil {
		sb.WriteString("error " + r.Err.Error() + "\n")
	} else {
		sb.WriteString("ok ran=" + itoa(int64(r.Ran)) + " hit=" + itoa(int64(r.Hits)) + " time=" + itoa(r.Time) + "\n")
	}
	return sb.String()
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}

const parallel = `
step { out "out/a.txt"
 cmd write("A\n")
 cost 3 }
step { out "out/b.txt"
 cmd write("B\n")
 cost 1 }
step { out "out/c.txt"
 cmd write("C\n")
 cost 4 }
step { out "out/d.txt"
 cmd write("D\n")
 cost 2 }
step {
 out "out/all.txt"
 in ["out/a.txt", "out/b.txt", "out/c.txt", "out/d.txt"]
 cmd concat()
 cost 2
}
default "out/all.txt"
`

func TestSchedulerTieBreaking(t *testing.T) {
	// "step { out ..." on one line is not valid KBL; expand into blocks.
	src := strings.NewReplacer("step { out", "step {\n out", " cost 3 }", " cost 3\n}", " cost 1 }", " cost 1\n}", " cost 4 }", " cost 4\n}", " cost 2 }", " cost 2\n}").Replace(parallel)
	fs := workspace("main.kiln", src)
	got := render(build.Run(fs, nil, 2))
	want := `run 0 3 w0 out/a.txt write("A\n")
run 0 1 w1 out/b.txt write("B\n")
run 1 5 w1 out/c.txt write("C\n")
run 3 5 w0 out/d.txt write("D\n")
run 5 7 w0 out/all.txt concat()
ok ran=5 hit=0 time=7
`
	if got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
	c, _ := fs.Read("out/all.txt")
	if string(c) != "A\nB\nC\nD\n" {
		t.Errorf("all.txt = %q", c)
	}
}

const chain = `step {
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

func TestEarlyCutoffAndHits(t *testing.T) {
	fs := workspace("main.kiln", chain, "src/a.txt", "abc\n")
	if got := render(build.Run(fs, nil, 1)); !strings.HasSuffix(got, "ok ran=2 hit=0 time=4\n") {
		t.Fatalf("first build: %s", got)
	}
	if got := render(build.Run(fs, nil, 1)); got != "hit 0 out/mid.txt\nhit 0 out/final.txt\nok ran=0 hit=2 time=0\n" {
		t.Fatalf("second build: %s", got)
	}
	fs.Write("src/a.txt", []byte("ABC\n"))
	want := "run 0 2 w0 out/mid.txt upper()\nhit 2 out/final.txt\nok ran=1 hit=1 time=2\n"
	if got := render(build.Run(fs, nil, 1)); got != want {
		t.Fatalf("early cutoff: %s", got)
	}
	// Touching does not rebuild; tampering with an output does.
	fs.Touch("src/a.txt")
	if got := render(build.Run(fs, nil, 1)); !strings.Contains(got, "ran=0 hit=2") {
		t.Fatalf("touch: %s", got)
	}
	fs.Write("out/mid.txt", []byte("junk"))
	if got := render(build.Run(fs, nil, 1)); !strings.HasPrefix(got, "run 0 2 w0 out/mid.txt upper()") {
		t.Fatalf("tamper: %s", got)
	}
}

func TestStateFileWritten(t *testing.T) {
	fs := workspace("main.kiln", "step {\n out \"out/hello.txt\"\n cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n")
	build.Run(fs, nil, 1)
	st, _ := fs.Read(".kiln-state")
	want := "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\nout out/hello.txt a9bc80cca21f28b3\nend\n"
	if string(st) != want {
		t.Errorf("state = %q", st)
	}
}

func TestConfigurationErrorsLeaveWorkspaceUntouched(t *testing.T) {
	fs := workspace("main.kiln", "step {\n out \"out/x\"\n in \"out/y\"\n cmd copy()\n}\nstep {\n out \"out/y\"\n in \"out/x\"\n cmd copy()\n}\ndefault \"out/x\"\n")
	got := render(build.Run(fs, nil, 1))
	if got != "error E_CYCLE out/x -> out/y -> out/x\n" {
		t.Errorf("got %s", got)
	}
	if fs.Exists(".kiln-state") || fs.Len() != 1 {
		t.Error("workspace modified")
	}
}

func TestGraphErrors(t *testing.T) {
	step := func(out, in string) string {
		s := "step {\n out \"" + out + "\"\n cmd write(\"x\")\n"
		if in != "" {
			s = "step {\n out \"" + out + "\"\n in " + in + "\n cmd copy()\n"
		}
		return s + "}\n"
	}
	cases := []struct {
		name, src string
		targets   []string
		want      string
	}{
		{"dup output", step("out/z", "") + step("out/z", ""), nil, "error E_DUP_OUTPUT out/z\n"},
		{"dup depfile", step("out/z", "") + "step {\n out \"out/q\"\n depfile \"out/z\"\n in \"main.kiln\"\n cmd preprocess()\n}\n", nil, "error E_DUP_OUTPUT out/z\n"},
		{"missing input", step("out/z", `"nope"`), nil, "error E_MISSING_INPUT nope required by out/z\n"},
		{"missing phony", "phony p = [\"@q\"]\n", nil, "error E_MISSING_INPUT @q required by @p\n"},
		{"unknown default", "default \"nope\"\n", []string{"out/z"}, "error E_UNKNOWN_TARGET nope\n"},
		{"unknown target", step("out/z", ""), []string{"out/y"}, "error E_UNKNOWN_TARGET out/y\n"},
		{"no default", step("out/z", ""), nil, "error E_NO_DEFAULT\n"},
		{"self cycle", step("out/z", `"out/z"`), []string{"out/z"}, "error E_CYCLE out/z -> out/z\n"},
		{"phony cycle", "step {\n out \"out/z\"\n in \"@p\"\n cmd write(\"x\")\n}\n" + "phony p = [\"out/z\"]\n", []string{"out/z"}, "error E_CYCLE out/z -> @p -> out/z\n"},
		{"unreachable cycle ignored", step("out/z", "") + step("out/a", `"out/b"`) + step("out/b", `"out/a"`), []string{"out/z"}, "run 0 1 w0 out/z write(\"x\")\nok ran=1 hit=0 time=1\n"},
		{"source target", step("out/z", ""), []string{"main.kiln"}, "ok ran=0 hit=0 time=0\n"},
	}
	for _, tc := range cases {
		fs := workspace("main.kiln", tc.src)
		if got := render(build.Run(fs, tc.targets, 1)); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestFailureCancelsAndRemovesState(t *testing.T) {
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
	fs := workspace("main.kiln", main, "src/main.txt", "@need src/gone.txt\n")
	want := `fail 0 6 w0 out/doc.txt preprocess()
cancel 0 10 w1 out/slow.txt write("slow\n")
error E_NEED_MISSING src/gone.txt needed by src/main.txt
`
	if got := render(build.Run(fs, nil, 2)); got != want {
		t.Errorf("got:\n%s", got)
	}
	st, _ := fs.Read(".kiln-state")
	if string(st) != "kiln-state 1\n" {
		t.Errorf("state = %q", st)
	}
	if fs.Exists("out/slow.txt") {
		t.Error("cancelled output written")
	}
}

func TestCorruptStateRebuildsEverything(t *testing.T) {
	fs := workspace("main.kiln", chain, "src/a.txt", "abc\n")
	build.Run(fs, nil, 1)
	st, _ := fs.Read(".kiln-state")
	fs.Write(".kiln-state", st[:len(st)-1]) // drop final newline
	if got := render(build.Run(fs, nil, 1)); !strings.Contains(got, "ran=2 hit=0") {
		t.Errorf("got %s", got)
	}
}

func TestCostZeroAndHitCascade(t *testing.T) {
	src := "step {\n out \"out/a\"\n cmd write(\"a\")\n cost 0\n}\nstep {\n out \"out/b\"\n in \"out/a\"\n cmd copy()\n}\ndefault \"out/b\"\n"
	fs := workspace("main.kiln", src)
	want := "run 0 0 w0 out/a write(\"a\")\nrun 0 1 w0 out/b copy()\nok ran=2 hit=0 time=1\n"
	if got := render(build.Run(fs, nil, 1)); got != want {
		t.Errorf("got %s", got)
	}
}
