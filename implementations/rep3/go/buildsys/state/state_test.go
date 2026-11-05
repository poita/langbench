package state

import (
	"strings"
	"testing"

	"buildsys/vfs"
)

const example = `kiln-state 1
step out/one.txt
cmd concat()
in src/a.txt 8943a78b9f342c58
in src/b.txt c857dca71c36fafd
out out/one.txt 5e52e06e8b405ae8
end
step out/two.txt
cmd write("a b")
dep src/d.txt 0000000000000001
out out/two.txt f98ee131e7582add
out out/two.d f98ee131e7582add
end
`

func TestRoundTrip(t *testing.T) {
	st := Parse([]byte(example))
	if len(st) != 2 {
		t.Fatalf("parsed %d entries", len(st))
	}
	e := st["out/two.txt"]
	if e.Cmd != `write("a b")` || len(e.Deps) != 1 || len(e.Outs) != 2 || len(e.Ins) != 0 {
		t.Errorf("entry %+v", e)
	}
	if got := string(st.Encode()); got != example {
		t.Errorf("round trip:\n%s", got)
	}
}

func TestEncodeSortsEntries(t *testing.T) {
	st := State{
		"out/z": {Cmd: "c()", Outs: []PathHash{{"out/z", 1}}},
		"out/a": {Cmd: "c()", Outs: []PathHash{{"out/a", 2}}},
	}
	got := string(st.Encode())
	if strings.Index(got, "out/a") > strings.Index(got, "out/z") {
		t.Errorf("not sorted:\n%s", got)
	}
	if string(State{}.Encode()) != "kiln-state 1\n" {
		t.Error("empty state")
	}
}

func TestCorruptStatesAreEmpty(t *testing.T) {
	bad := map[string]string{
		"empty":            "",
		"bad header":       "kiln-state 2\n",
		"no final newline": "kiln-state 1",
		"unterminated":     "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0000000000000000\n",
		"stray line":       "kiln-state 1\nfoo\n",
		"no cmd":           "kiln-state 1\nstep out/a\nout out/a 0000000000000000\nend\n",
		"two cmds":         "kiln-state 1\nstep out/a\ncmd c()\ncmd c()\nout out/a 0000000000000000\nend\n",
		"no out":           "kiln-state 1\nstep out/a\ncmd c()\nend\n",
		"misordered":       "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0000000000000000\nin src/a 0000000000000000\nend\n",
		"dep before in":    "kiln-state 1\nstep out/a\ncmd c()\ndep src/a 0000000000000000\nin src/a 0000000000000000\nout out/a 0000000000000000\nend\n",
		"upper hash":       "kiln-state 1\nstep out/a\ncmd c()\nout out/a 000000000000000A\nend\n",
		"short hash":       "kiln-state 1\nstep out/a\ncmd c()\nout out/a 00\nend\n",
		"bad path":         "kiln-state 1\nstep out/a\ncmd c()\nout /out/a 0000000000000000\nend\n",
		"key mismatch":     "kiln-state 1\nstep out/a\ncmd c()\nout out/b 0000000000000000\nend\n",
		"duplicate keys":   "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0000000000000000\nend\nstep out/a\ncmd c()\nout out/a 0000000000000000\nend\n",
		"empty cmd":        "kiln-state 1\nstep out/a\ncmd \nout out/a 0000000000000000\nend\n",
		"extra space":      "kiln-state 1\nstep  out/a\ncmd c()\nout out/a 0000000000000000\nend\n",
		"end with space":   "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0000000000000000\nend \n",
		"extra field":      "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0000000000000000 x\nend\n",
		"step in entry":    "kiln-state 1\nstep out/a\nstep out/b\n",
	}
	for name, data := range bad {
		if st := Parse([]byte(data)); len(st) != 0 {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestLooseOrderingWithinSections(t *testing.T) {
	data := "kiln-state 1\nstep out/b\ncmd c()\ndep src/z 0000000000000001\ndep src/a 0000000000000002\ndep src/a 0000000000000002\nout out/b 0000000000000003\nend\n" +
		"step out/a\ncmd c()\nout out/a 0000000000000003\nend\n"
	st := Parse([]byte(data))
	if len(st) != 2 || len(st["out/b"].Deps) != 3 {
		t.Errorf("%+v", st)
	}
}

type hashes map[string]uint64

func (h hashes) Hash(p string) (uint64, bool) { v, ok := h[p]; return v, ok }

func TestFresh(t *testing.T) {
	h := vfs.Hash64([]byte("x"))
	e := &Entry{
		Cmd:  "concat()",
		Ins:  []PathHash{{"src/a", h}, {"src/b", h}},
		Deps: []PathHash{{"src/d", h}},
		Outs: []PathHash{{"out/o", h}},
	}
	files := hashes{"src/a": h, "src/b": h, "src/d": h, "out/o": h}
	ins, outs := []string{"src/a", "src/b"}, []string{"out/o"}
	if !e.Fresh("concat()", ins, outs, files) {
		t.Error("should be fresh")
	}
	var nilEntry *Entry
	stale := map[string]bool{
		"nil entry":   nilEntry.Fresh("concat()", ins, outs, files),
		"cmd":         e.Fresh("copy()", ins, outs, files),
		"out list":    e.Fresh("concat()", ins, []string{"out/o", "out/d"}, files),
		"in order":    e.Fresh("concat()", []string{"src/b", "src/a"}, outs, files),
		"in count":    e.Fresh("concat()", ins[:1], outs, files),
		"in changed":  e.Fresh("concat()", ins, outs, hashes{"src/a": 1, "src/b": h, "src/d": h, "out/o": h}),
		"dep missing": e.Fresh("concat()", ins, outs, hashes{"src/a": h, "src/b": h, "out/o": h}),
		"out changed": e.Fresh("concat()", ins, outs, hashes{"src/a": h, "src/b": h, "src/d": h, "out/o": 7}),
		"out missing": e.Fresh("concat()", ins, outs, hashes{"src/a": h, "src/b": h, "src/d": h}),
	}
	for name, fresh := range stale {
		if fresh {
			t.Errorf("%s: reported fresh", name)
		}
	}
}
