package session_test

import (
	"strings"
	"testing"

	"buildsys/session"
	"buildsys/vfs"
)

type tc struct {
	name  string
	files map[string]string
	sess  string
	log   string
	// ws lists workspace files that must exist with exactly this content.
	ws map[string]string
	// absent lists paths that must not exist.
	absent []string
}

func lines(ss ...string) string { return strings.Join(ss, "\n") + "\n" }

const hello = "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n"

var cases = []tc{
	{
		name:  "one step",
		files: map[string]string{"main.kiln": hello},
		sess:  "build\n",
		log: lines(
			"step 1: build (default) -j 1",
			`  run 0 1 w0 out/hello.txt write("hello\n")`,
			"  ok ran=1 hit=0 time=1"),
		ws: map[string]string{
			"out/hello.txt": "hello\n",
			".kiln-state":   "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\nout out/hello.txt a9bc80cca21f28b3\nend\n",
		},
	},
	{
		name:  "hit and touch",
		files: map[string]string{"main.kiln": hello},
		sess:  "build\nbuild\ntouch main.kiln\nbuild\n",
		log: lines(
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
			"  ok ran=0 hit=1 time=0"),
	},
	{
		name: "parallel scheduling",
		files: map[string]string{"main.kiln": `
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
`},
		sess: "build -j 2\n",
		log: lines(
			"step 1: build (default) -j 2",
			`  run 0 3 w0 out/a.txt write("A\n")`,
			`  run 0 1 w1 out/b.txt write("B\n")`,
			`  run 1 5 w1 out/c.txt write("C\n")`,
			`  run 3 5 w0 out/d.txt write("D\n")`,
			"  run 5 7 w0 out/all.txt concat()",
			"  ok ran=5 hit=0 time=7"),
		ws: map[string]string{"out/all.txt": "A\nB\nC\nD\n"},
	},
	{
		name: "rules and a chain",
		files: map[string]string{
			"src/a.txt": "AAA\n", "src/b.txt": "BBB\n",
			"main.kiln": `
rule bundle(name, parts, weight = 2) {
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
`},
		sess: "build -j 2\n",
		log: lines(
			"step 1: build (default) -j 2",
			"  run 0 2 w0 out/one.txt concat()",
			"  run 2 7 w0 out/two.txt concat()",
			"  ok ran=2 hit=0 time=7"),
		ws: map[string]string{
			".kiln-state": lines("kiln-state 1",
				"step out/one.txt", "cmd concat()",
				"in src/a.txt 8943a78b9f342c58", "in src/b.txt c857dca71c36fafd",
				"out out/one.txt 5e52e06e8b405ae8", "end",
				"step out/two.txt", "cmd concat()",
				"in src/a.txt 8943a78b9f342c58", "in src/b.txt c857dca71c36fafd",
				"in out/one.txt 5e52e06e8b405ae8", "out out/two.txt f98ee131e7582add", "end"),
		},
	},
	{
		name: "preprocess and depfiles",
		files: map[string]string{
			"src/main.txt": "title\n@need src/part.txt\nend\n",
			"src/part.txt": "PART-A\n@need src/deep.txt\n",
			"src/deep.txt": "DEEP\n",
			"main.kiln": `
step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/main.txt"
    cmd preprocess()
}
default "out/doc.txt"
`},
		sess: "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild\n",
		log: lines(
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
			"  ok ran=1 hit=0 time=6"),
		ws: map[string]string{
			"out/doc.txt": "title\nPART-A\nDEEP2\nend\n",
			"out/doc.d":   "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n",
			".kiln-state": lines("kiln-state 1", "step out/doc.txt", "cmd preprocess()",
				"in src/main.txt 993a20756b253540",
				"dep src/deep.txt 06ae7bdd484568d7", "dep src/part.txt a8442a790131f243",
				"out out/doc.txt f755eb555e1be12f", "out out/doc.d ea603661a409bc02", "end"),
		},
	},
	{
		name: "early cutoff",
		files: map[string]string{"src/a.txt": "abc\n", "main.kiln": `
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
`},
		sess: "build\nedit src/a.txt\nABC\n---\nbuild\n",
		log: lines(
			"step 1: build (default) -j 1",
			"  run 0 2 w0 out/mid.txt upper()",
			"  run 2 4 w0 out/final.txt number()",
			"  ok ran=2 hit=0 time=4",
			"step 2: edit src/a.txt",
			"  ok size=4",
			"step 3: build (default) -j 1",
			"  run 0 2 w0 out/mid.txt upper()",
			"  hit 2 out/final.txt",
			"  ok ran=1 hit=1 time=2"),
		ws: map[string]string{"out/final.txt": "1: ABC\n"},
	},
	{
		name: "cycle is a configuration error",
		files: map[string]string{"main.kiln": `
step {
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
`},
		sess:   "build\n",
		log:    lines("step 1: build (default) -j 1", "  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt"),
		absent: []string{".kiln-state", "out/x.txt"},
	},
	{
		name:  "no build file",
		files: map[string]string{},
		sess:  "build -j 3\n",
		log:   lines("step 1: build (default) -j 3", "  error E_NO_BUILD_FILE main.kiln"),
	},
	{
		name: "execution error cancels work in flight",
		files: map[string]string{"src/main.txt": "@need src/gone.txt\n", "main.kiln": `
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
`},
		sess: "build -j 2\n",
		log: lines(
			"step 1: build (default) -j 2",
			"  fail 0 6 w0 out/doc.txt preprocess()",
			`  cancel 0 10 w1 out/slow.txt write("slow\n")`,
			"  error E_NEED_MISSING src/gone.txt needed by src/main.txt"),
		ws:     map[string]string{".kiln-state": "kiln-state 1\n"},
		absent: []string{"out/slow.txt", "out/doc.txt"},
	},
	{
		name: "after is order-only",
		files: map[string]string{"src/a.txt": "a\n", "main.kiln": `
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
phony all = ["out/rep.txt"]
default "@all"
`},
		sess: "build\nedit src/a.txt\nb\n---\nbuild\n",
		log: lines(
			"step 1: build (default) -j 1",
			"  run 0 1 w0 out/gen.txt copy()",
			`  run 1 2 w0 out/rep.txt write("report\n")`,
			"  ok ran=2 hit=0 time=2",
			"step 2: edit src/a.txt",
			"  ok size=2",
			"step 3: build (default) -j 1",
			"  run 0 1 w0 out/gen.txt copy()",
			"  hit 1 out/rep.txt",
			"  ok ran=1 hit=1 time=1"),
	},
	{
		name:  "tamper and delete outputs",
		files: map[string]string{"main.kiln": hello},
		sess:  "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild\n",
		log: lines(
			"step 1: build (default) -j 1",
			`  run 0 1 w0 out/hello.txt write("hello\n")`,
			"  ok ran=1 hit=0 time=1",
			"step 2: edit out/hello.txt",
			"  ok size=9",
			"step 3: build (default) -j 1",
			`  run 0 1 w0 out/hello.txt write("hello\n")`,
			"  ok ran=1 hit=0 time=1",
			"step 4: delete out/hello.txt",
			"  ok",
			"step 5: build (default) -j 1",
			`  run 0 1 w0 out/hello.txt write("hello\n")`,
			"  ok ran=1 hit=0 time=1"),
	},
	{
		name:  "clean",
		files: map[string]string{"main.kiln": hello},
		sess:  "build\nclean\nbuild\n",
		log: lines(
			"step 1: build (default) -j 1",
			`  run 0 1 w0 out/hello.txt write("hello\n")`,
			"  ok ran=1 hit=0 time=1",
			"step 2: clean",
			"  remove .kiln-state",
			"  remove out/hello.txt",
			"  ok removed=2",
			"step 3: build (default) -j 1",
			`  run 0 1 w0 out/hello.txt write("hello\n")`,
			"  ok ran=1 hit=0 time=1"),
	},
	{
		name: "corrupt state rebuilds everything; -j as a target",
		files: map[string]string{
			"main.kiln": hello, ".kiln-state": "kiln-state 1\ngarbage\n",
		},
		sess: "build -j\nbuild out/hello.txt -j 2\n",
		log: lines(
			"step 1: build -j -j 1",
			"  error E_UNKNOWN_TARGET -j",
			"step 2: build out/hello.txt -j 2",
			`  run 0 1 w0 out/hello.txt write("hello\n")`,
			"  ok ran=1 hit=0 time=1"),
	},
	{
		name:  "session comments, blank lines and verbatim content",
		files: map[string]string{},
		sess:  "# comment\n\n  \t\ncreate x.txt\n  indented \t\n\n# not a comment\n---\ndelete x.txt\n",
		log: lines(
			"step 1: create x.txt",
			"  ok size=30",
			"step 2: delete x.txt",
			"  ok"),
		absent: []string{"x.txt"},
	},
}

func TestSessions(t *testing.T) {
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fs := vfs.New()
			for p, content := range c.files {
				fs.Write(p, content)
			}
			log, err := session.RunScript(fs, c.sess)
			if err != nil {
				t.Fatal(err)
			}
			if log != c.log {
				t.Errorf("log mismatch\n got:\n%s\nwant:\n%s", log, c.log)
			}
			for p, want := range c.ws {
				if got, ok := fs.Read(p); !ok || got != want {
					t.Errorf("%s = %q (exists %v), want %q", p, got, ok, want)
				}
			}
			for _, p := range c.absent {
				if fs.Has(p) {
					t.Errorf("%s should not exist", p)
				}
			}
		})
	}
}

func TestParse(t *testing.T) {
	steps, err := session.Parse("build a b -j 4\nbuild\nclean\ntouch f\ncreate p\nx\n---\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(steps) != 5 {
		t.Fatalf("steps = %d", len(steps))
	}
	if b := steps[0]; b.Workers != 4 || len(b.Targets) != 2 {
		t.Errorf("build step = %+v", b)
	}
	if b := steps[1]; b.Workers != 1 || len(b.Targets) != 0 {
		t.Errorf("default build = %+v", b)
	}
	if steps[4].Content != "x\n" {
		t.Errorf("content = %q", steps[4].Content)
	}
	for _, bad := range []string{"frobnicate\n", "create p\nx\n", "build -j x\n", "touch\n"} {
		if _, err := session.Parse(bad); err == nil {
			t.Errorf("Parse(%q) succeeded", bad)
		}
	}
}
