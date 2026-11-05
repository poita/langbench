package state_test

import (
	"strings"
	"testing"

	"buildsys/state"
)

const good = `kiln-state 1
step out/a.txt
cmd concat()
in src/a.txt 8943a78b9f342c58
dep src/z.txt 0000000000000001
out out/a.txt 5e52e06e8b405ae8
out out/a.d 5e52e06e8b405ae9
end
step out/b.txt
cmd write("x y")
out out/b.txt 5e52e06e8b405ae8
end
`

func TestParseAndMarshalRoundTrip(t *testing.T) {
	st, ok := state.Parse([]byte(good))
	if !ok || len(st) != 2 {
		t.Fatalf("parse failed: %v %v", ok, st)
	}
	e := st["out/a.txt"]
	if e.Cmd != "concat()" || len(e.In) != 1 || len(e.Dep) != 1 || len(e.Out) != 2 {
		t.Fatalf("entry = %+v", e)
	}
	if st["out/b.txt"].Cmd != `write("x y")` {
		t.Error("cmd verbatim")
	}
	if got := string(st.Marshal()); got != good {
		t.Errorf("marshal differs:\n%s", got)
	}
}

func TestMarshalSortsEntries(t *testing.T) {
	st := state.State{
		"out/z": {Cmd: "c()", Out: []state.PathHash{{Path: "out/z", Hash: 1}}},
		"out/a": {Cmd: "c()", Out: []state.PathHash{{Path: "out/a", Hash: 2}}},
	}
	want := "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0000000000000002\nend\n" +
		"step out/z\ncmd c()\nout out/z 0000000000000001\nend\n"
	if got := string(st.Marshal()); got != want {
		t.Errorf("got %q", got)
	}
	if got := string(state.State{}.Marshal()); got != "kiln-state 1\n" {
		t.Errorf("empty = %q", got)
	}
}

func TestUnsortedLinesAreAccepted(t *testing.T) {
	in := "kiln-state 1\nstep out/b\ncmd c()\nin b 0000000000000001\nin a 0000000000000001\n" +
		"dep z 0000000000000001\ndep a 0000000000000001\ndep a 0000000000000001\nout out/b 0000000000000001\nend\n" +
		"step out/a\ncmd c()\nout out/a 0000000000000001\nend\n"
	if st, ok := state.Parse([]byte(in)); !ok || len(st) != 2 {
		t.Fatal("rejected valid unsorted state")
	}
}

func TestRejects(t *testing.T) {
	h := "0000000000000001"
	bad := map[string]string{
		"empty":            "",
		"bad header":       "kiln-state 2\n",
		"no final newline": "kiln-state 1",
		"unterminated":     "kiln-state 1\nstep out/a\ncmd c()\nout out/a " + h + "\n",
		"no out":           "kiln-state 1\nstep out/a\ncmd c()\nend\n",
		"no cmd":           "kiln-state 1\nstep out/a\nout out/a " + h + "\nend\n",
		"two cmds":         "kiln-state 1\nstep out/a\ncmd c()\ncmd d()\nout out/a " + h + "\nend\n",
		"empty cmd":        "kiln-state 1\nstep out/a\ncmd \nout out/a " + h + "\nend\n",
		"key mismatch":     "kiln-state 1\nstep out/a\ncmd c()\nout out/b " + h + "\nend\n",
		"dup entry":        "kiln-state 1\nstep out/a\ncmd c()\nout out/a " + h + "\nend\nstep out/a\ncmd c()\nout out/a " + h + "\nend\n",
		"stray line":       "kiln-state 1\nfoo\n",
		"uppercase hash":   "kiln-state 1\nstep out/a\ncmd c()\nout out/a 000000000000000A\nend\n",
		"short hash":       "kiln-state 1\nstep out/a\ncmd c()\nout out/a 1\nend\n",
		"bad path":         "kiln-state 1\nstep out/a\ncmd c()\nin ../x " + h + "\nout out/a " + h + "\nend\n",
		"misordered":       "kiln-state 1\nstep out/a\ncmd c()\nout out/a " + h + "\nin x " + h + "\nend\n",
		"dep before in":    "kiln-state 1\nstep out/a\ncmd c()\ndep x " + h + "\nin x " + h + "\nout out/a " + h + "\nend\n",
		"extra space":      "kiln-state 1\nstep out/a\ncmd c()\nin x  " + h + "\nout out/a " + h + "\nend\n",
		"end with text":    "kiln-state 1\nstep out/a\ncmd c()\nout out/a " + h + "\nend \n",
		"step bad path":    "kiln-state 1\nstep /out/a\ncmd c()\nout out/a " + h + "\nend\n",
	}
	for name, in := range bad {
		st, ok := state.Parse([]byte(in))
		if ok || len(st) != 0 {
			t.Errorf("%s: accepted", name)
		}
	}
	if !strings.HasPrefix(good, state.Header) {
		t.Error("header const")
	}
}
