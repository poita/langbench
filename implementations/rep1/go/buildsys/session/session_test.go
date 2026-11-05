package session_test

import (
	"reflect"
	"testing"

	"buildsys/session"
	"buildsys/vfs"
)

func TestParse(t *testing.T) {
	script := `# comment
build
build @all out/a.txt -j 4

  build -j
build -j 3
create src/a.txt
line one
  indented  

# not a comment
---
edit main.kiln
---
delete src/a.txt
touch main.kiln
clean
`
	steps, err := session.Parse([]byte(script))
	if err != nil {
		t.Fatal(err)
	}
	want := []session.Step{
		{Kind: session.Build, Workers: 1},
		{Kind: session.Build, Targets: []string{"@all", "out/a.txt"}, Workers: 4},
		{Kind: session.Build, Targets: []string{"-j"}, Workers: 1},
		{Kind: session.Build, Workers: 3},
		{Kind: session.Create, Path: "src/a.txt", Content: []byte("line one\n  indented  \n\n# not a comment\n")},
		{Kind: session.Edit, Path: "main.kiln", Content: nil},
		{Kind: session.Delete, Path: "src/a.txt"},
		{Kind: session.Touch, Path: "main.kiln"},
		{Kind: session.Clean},
	}
	if !reflect.DeepEqual(steps, want) {
		t.Errorf("got  %+v\nwant %+v", steps, want)
	}
}

func TestParseErrors(t *testing.T) {
	for _, s := range []string{"frobnicate\n", "create a b\n---\n", "create a\nno terminator\n", "delete\n", "clean now\n"} {
		if _, err := session.Parse([]byte(s)); err == nil {
			t.Errorf("accepted %q", s)
		}
	}
}

func TestRunLog(t *testing.T) {
	fs := vfs.New()
	fs.Write("main.kiln", []byte("step {\n out \"out/hello.txt\"\n cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n"))
	steps, err := session.Parse([]byte("build\nbuild\ntouch main.kiln\nedit out/hello.txt\ntampered\n---\nbuild -j 2\nclean\nbuild nope\ncreate x.txt\n---\ndelete x.txt\n"))
	if err != nil {
		t.Fatal(err)
	}
	want := `step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
step 3: touch main.kiln
  ok
step 4: edit out/hello.txt
  ok size=9
step 5: build (default) -j 2
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 6: clean
  remove .kiln-state
  remove out/hello.txt
  ok removed=2
step 7: build nope -j 1
  error E_UNKNOWN_TARGET nope
step 8: create x.txt
  ok size=0
step 9: delete x.txt
  ok
`
	if got := string(session.Run(fs, steps)); got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}
