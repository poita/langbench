package session

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"kiln/vfs"
)

func TestParse(t *testing.T) {
	src := "# comment\n\n  \t\nbuild a -j x y\nbuild x y -j 4\nbuild -j 2\n  create  p/q.txt \n line  \n# kept\n\n---\nedit p/q.txt\n---\ndelete p/q.txt\ntouch main.kiln\nclean\n"
	sc, err := Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	want := []Step{
		{Op: OpBuild, Targets: []string{"a", "-j", "x", "y"}, Workers: 1},
		{Op: OpBuild, Targets: []string{"x", "y"}, Workers: 4},
		{Op: OpBuild, Workers: 2},
		{Op: OpCreate, Path: "p/q.txt", Content: []byte(" line  \n# kept\n\n")},
		{Op: OpEdit, Path: "p/q.txt"},
		{Op: OpDelete, Path: "p/q.txt"},
		{Op: OpTouch, Path: "main.kiln"},
		{Op: OpClean},
	}
	if !reflect.DeepEqual(sc.Steps, want) {
		t.Errorf("steps = %+v\nwant    %+v", sc.Steps, want)
	}
}

func TestParseErrors(t *testing.T) {
	for _, src := range []string{"frobnicate\n", "create a\nno terminator\n", "touch\n", "build -j 0\n"} {
		if _, err := Parse([]byte(src)); err == nil {
			t.Errorf("Parse(%q) succeeded", src)
		}
	}
}

func TestRunLog(t *testing.T) {
	fs := vfs.New()
	fs.Write("main.kiln", []byte("step {\n out \"out/hello.txt\"\n cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n"))
	sc, err := Parse([]byte("build\nbuild -j 3\ntouch main.kiln\nbuild bogus\nedit out/hello.txt\nx\n---\nbuild\ndelete main.kiln\nbuild\nclean\n"))
	if err != nil {
		t.Fatal(err)
	}
	want := `step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 3
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
step 3: touch main.kiln
  ok
step 4: build bogus -j 1
  error E_UNKNOWN_TARGET bogus
step 5: edit out/hello.txt
  ok size=2
step 6: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 7: delete main.kiln
  ok
step 8: build (default) -j 1
  error E_NO_BUILD_FILE main.kiln
step 9: clean
  remove .kiln-state
  remove out/hello.txt
  ok removed=2
`
	if got := sc.Run(fs); got != want {
		t.Errorf("log:\n%s\nwant:\n%s", got, want)
	}
	if fs.Len() != 0 {
		t.Errorf("workspace should be empty after clean, have %v", fs.Paths())
	}
}

func TestRunDir(t *testing.T) {
	in, out := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(in, "session.txt"), []byte("build\n"), 0o644)
	os.WriteFile(filepath.Join(in, "main.kiln"), []byte("step {\n out \"out/a\"\n cmd write(\"A\")\n}\ndefault \"out/a\"\n"), 0o644)
	if err := RunDir(in, out); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(out, "workspace/out/a")); string(b) != "A" {
		t.Errorf("out/a = %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(out, "log.txt")); string(b) != "step 1: build (default) -j 1\n  run 0 1 w0 out/a write(\"A\")\n  ok ran=1 hit=0 time=1\n" {
		t.Errorf("log = %q", b)
	}
	if _, err := os.Stat(filepath.Join(out, "workspace/session.txt")); err == nil {
		t.Error("session.txt must not be part of the workspace")
	}
}
