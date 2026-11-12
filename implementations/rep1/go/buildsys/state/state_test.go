package state

import (
	"strings"
	"testing"

	"buildsys/cmds"
	"buildsys/plan"
	"buildsys/vfs"
)

const h1 = "0123456789abcdef"

func sample() string {
	return "kiln-state 1\n" +
		"step out/a\ncmd copy()\nin src/a " + h1 + "\ndep src/d " + h1 + "\nout out/a " + h1 + "\nend\n" +
		"step out/b\ncmd write(\"x y\")\nout out/b " + h1 + "\nend\n"
}

func TestRoundTrip(t *testing.T) {
	s := Parse(sample())
	if s.Len() != 2 {
		t.Fatalf("entries = %d", s.Len())
	}
	if got := s.Format(); got != sample() {
		t.Errorf("round trip:\n%s", got)
	}
	if e := s.Get("out/b"); e == nil || e.Cmd != `write("x y")` {
		t.Errorf("entry = %+v", e)
	}
}

func TestFormatSortsEntries(t *testing.T) {
	s := New()
	s.Put(&Entry{Key: "out/z", Cmd: "c()", Out: []PathHash{{"out/z", h1}}})
	s.Put(&Entry{Key: "out/a", Cmd: "c()", Out: []PathHash{{"out/a", h1}}})
	if !strings.HasPrefix(s.Format(), "kiln-state 1\nstep out/a\n") {
		t.Errorf("unsorted:\n%s", s.Format())
	}
	if New().Format() != "kiln-state 1\n" {
		t.Error("empty state")
	}
}

func TestParseRejects(t *testing.T) {
	good := sample()
	bad := map[string]string{
		"empty":            "",
		"no trailing nl":   strings.TrimSuffix(good, "\n"),
		"bad header":       strings.Replace(good, "kiln-state 1", "kiln-state 2", 1),
		"stray line":       good + "junk\n",
		"unterminated":     "kiln-state 1\nstep out/a\ncmd c()\nout out/a " + h1 + "\n",
		"no out":           "kiln-state 1\nstep out/a\ncmd c()\nend\n",
		"key mismatch":     "kiln-state 1\nstep out/a\ncmd c()\nout out/b " + h1 + "\nend\n",
		"upper hash":       strings.Replace(good, h1, "0123456789ABCDEF", 1),
		"short hash":       strings.Replace(good, h1, "0123", 1),
		"bad path":         strings.Replace(good, "src/a ", "src//a ", 1),
		"empty cmd":        "kiln-state 1\nstep out/a\ncmd \nout out/a " + h1 + "\nend\n",
		"two cmds":         "kiln-state 1\nstep out/a\ncmd c()\ncmd d()\nout out/a " + h1 + "\nend\n",
		"misordered":       "kiln-state 1\nstep out/a\ncmd c()\nout out/a " + h1 + "\nin x " + h1 + "\nend\n",
		"duplicate key":    "kiln-state 1\n" + strings.Repeat("step out/a\ncmd c()\nout out/a "+h1+"\nend\n", 2),
		"double space":     "kiln-state 1\nstep out/a\ncmd c()\nout  out/a " + h1 + "\nend\n",
		"extra field":      "kiln-state 1\nstep out/a\ncmd c()\nout out/a " + h1 + " x\nend\n",
		"end with payload": "kiln-state 1\nstep out/a\ncmd c()\nout out/a " + h1 + "\nend x\n",
	}
	for name, content := range bad {
		if s := Parse(content); s.Len() != 0 {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestFresh(t *testing.T) {
	copySpec, _ := cmds.Lookup("copy")
	step := &plan.Step{Outputs: []string{"out/a"}, FileInputs: []string{"src/a"}, Spec: copySpec, Command: "copy()"}
	fs := vfs.New()
	fs.Write("src/a", "x")
	fs.Write("out/a", "x")
	if Fresh(nil, step, fs) {
		t.Error("fresh without entry")
	}
	e := Capture(step, nil, fs)
	if !Fresh(e, step, fs) {
		t.Error("captured entry not fresh")
	}
	fs.Write("out/a", "tampered")
	if Fresh(e, step, fs) {
		t.Error("tampered output still fresh")
	}
	fs.Write("out/a", "x")
	fs.Write("src/a", "y")
	if Fresh(e, step, fs) {
		t.Error("changed input still fresh")
	}
	fs.Write("src/a", "x")
	other := *step
	other.Command = "copy( )"
	if Fresh(e, &other, fs) {
		t.Error("changed command still fresh")
	}
	other = *step
	other.FileInputs = []string{"src/a", "src/a"}
	if Fresh(e, &other, fs) {
		t.Error("changed input list still fresh")
	}
	fs.Delete("out/a")
	if Fresh(e, step, fs) {
		t.Error("missing output still fresh")
	}
}
