package state

import (
	"strings"
	"testing"

	"buildsys/vfs"
)

const valid = "kiln-state 1\n" +
	"step out/a.txt\ncmd copy()\nin src/a.txt 0123456789abcdef\nout out/a.txt 0123456789abcdef\nend\n" +
	"step out/b.txt\ncmd write(\"x\")\nout out/b.txt 0000000000000001\nend\n"

func TestRoundTrip(t *testing.T) {
	s := Parse(valid)
	if s.Len() != 2 {
		t.Fatalf("parsed %d entries, want 2", s.Len())
	}
	if got := s.Serialize(); got != valid {
		t.Errorf("Serialize =\n%s\nwant\n%s", got, valid)
	}
}

func TestSerializeSorts(t *testing.T) {
	s := New()
	s.Put(&Entry{Step: "out/z", Cmd: "c()", Out: []PathHash{{"out/z", 1}}})
	s.Put(&Entry{Step: "out/a", Cmd: "c()", Out: []PathHash{{"out/a", 2}}})
	got := s.Serialize()
	if strings.Index(got, "out/a") > strings.Index(got, "out/z") {
		t.Errorf("entries not sorted:\n%s", got)
	}
	s.Remove("out/a")
	if s.Len() != 1 {
		t.Error("Remove failed")
	}
}

func TestCorruptStatesAreEmpty(t *testing.T) {
	entry := "step out/a\ncmd c()\nout out/a 0123456789abcdef\nend\n"
	bad := map[string]string{
		"empty":            "",
		"wrong header":     "kiln-state 2\n",
		"no final newline": "kiln-state 1\n" + strings.TrimSuffix(entry, "\n"),
		"unterminated":     "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789abcdef\n",
		"stray line":       "kiln-state 1\nfoo\n",
		"no cmd":           "kiln-state 1\nstep out/a\nout out/a 0123456789abcdef\nend\n",
		"two cmds":         "kiln-state 1\nstep out/a\ncmd c()\ncmd d()\nout out/a 0123456789abcdef\nend\n",
		"empty cmd":        "kiln-state 1\nstep out/a\ncmd \nout out/a 0123456789abcdef\nend\n",
		"no out":           "kiln-state 1\nstep out/a\ncmd c()\nend\n",
		"uppercase hash":   "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789ABCDEF\nend\n",
		"short hash":       "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123\nend\n",
		"bad path":         "kiln-state 1\nstep out/a\ncmd c()\nin a//b 0123456789abcdef\nout out/a 0123456789abcdef\nend\n",
		"misordered":       "kiln-state 1\nstep out/a\ncmd c()\nout out/a 0123456789abcdef\nin x 0123456789abcdef\nend\n",
		"key mismatch":     "kiln-state 1\nstep out/b\ncmd c()\nout out/a 0123456789abcdef\nend\n",
		"duplicate key":    "kiln-state 1\n" + entry + entry,
		"extra space":      "kiln-state 1\nstep out/a\ncmd c()\nout out/a  0123456789abcdef\nend\n",
	}
	for name, data := range bad {
		if got := Parse(data); got.Len() != 0 {
			t.Errorf("%s: accepted %d entries", name, got.Len())
		}
	}
	if Parse("kiln-state 1\n"+entry).Len() != 1 {
		t.Error("valid entry rejected")
	}
	// Unsorted dep lines and repeated paths are legal.
	ok := "kiln-state 1\nstep out/a\ncmd c()\ndep z 0123456789abcdef\ndep a 0123456789abcdef\ndep a 0123456789abcdef\nout out/a 0123456789abcdef\nend\n"
	if Parse(ok).Len() != 1 {
		t.Error("unsorted dep lines rejected")
	}
}

func TestFresh(t *testing.T) {
	fs := vfs.New()
	fs.Write("src/a", "A")
	fs.Write("out/a", "O")
	e := &Entry{Step: "out/a", Cmd: "copy()",
		In:  []PathHash{{"src/a", vfs.Hash("A")}},
		Out: []PathHash{{"out/a", vfs.Hash("O")}}}
	in, out := []string{"src/a"}, []string{"out/a"}
	if !Fresh(e, "copy()", in, out, fs) {
		t.Error("expected fresh")
	}
	if Fresh(nil, "copy()", in, out, fs) {
		t.Error("nil entry is stale")
	}
	if Fresh(e, "upper()", in, out, fs) {
		t.Error("command change must be stale")
	}
	if Fresh(e, "copy()", []string{"src/a", "src/a"}, out, fs) {
		t.Error("input list change must be stale")
	}
	if Fresh(e, "copy()", in, []string{"out/a", "out/b"}, fs) {
		t.Error("output list change must be stale")
	}
	fs.Write("out/a", "tampered")
	if Fresh(e, "copy()", in, out, fs) {
		t.Error("modified output must be stale")
	}
	fs.Write("out/a", "O")
	fs.Delete("src/a")
	if Fresh(e, "copy()", in, out, fs) {
		t.Error("missing input must be stale")
	}
}
