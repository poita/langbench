package plan

import (
	"testing"

	"buildsys/cmds"
)

func draft(name string, outs, ins []string) *Draft {
	return &Draft{Outs: outs, Ins: ins, Cmd: &cmds.Command{Spec: cmds.Lookup(name), Args: argsFor(name)}}
}

func argsFor(name string) []cmds.Arg {
	switch name {
	case "write":
		return []cmds.Arg{{Str: "x"}}
	}
	return nil
}

func errOf(d *Draft) string {
	_, err := d.Finish()
	if err == nil {
		return ""
	}
	return err.Error()
}

func TestFinishOrder(t *testing.T) {
	if got := errOf(&Draft{}); got != "E_STEP_FIELD missing cmd" {
		t.Error(got)
	}
	d := draft("write", nil, nil)
	if got := errOf(d); got != "E_STEP_FIELD missing out" {
		t.Error(got)
	}
	if got := errOf(draft("write", []string{"bad path"}, nil)); got != "E_BAD_PATH bad path" {
		t.Error(got)
	}
	if got := errOf(draft("write", []string{"src/a"}, nil)); got != "E_OUTPUT_PATH src/a" {
		t.Error(got)
	}
	if got := errOf(draft("write", []string{"out/a", "src/b", "x y"}, nil)); got != "E_OUTPUT_PATH src/b" {
		t.Error(got)
	}
	if got := errOf(draft("copy", []string{"out/a"}, []string{"@x y"})); got != "E_BAD_PATH @x y" {
		t.Error(got)
	}
	if got := errOf(draft("copy", []string{"out/a"}, []string{"@all"})); got != "E_CMD_SHAPE copy: expected inputs 1-1, got 0" {
		t.Error(got)
	}
}

func TestFinishFields(t *testing.T) {
	d := draft("concat", []string{"out/a"}, []string{"@all", "src/x", "src/x"})
	d.Afters = []string{"out/z"}
	s, err := d.Finish()
	if err != nil {
		t.Fatal(err)
	}
	if len(s.FileInputs) != 2 || s.Cost != 2 || s.CmdString != "concat()" || s.Primary() != "out/a" {
		t.Errorf("%+v", s)
	}
	d = draft("preprocess", []string{"out/a"}, []string{"src/x"})
	d.Depfile, d.HasDepfile, d.Cost, d.HasCost = "out/a.d", true, 0, true
	s, err = d.Finish()
	if err != nil {
		t.Fatal(err)
	}
	if s.Cost != 0 || len(s.FullOuts) != 2 || s.FullOuts[1] != "out/a.d" {
		t.Errorf("%+v", s)
	}
}

func TestPhonyAndBuild(t *testing.T) {
	b := NewBuild()
	if err := b.AddPhony("all", nil); err != nil {
		t.Fatal(err)
	}
	if err := b.AddPhony("all", nil); err == nil || err.Error() != "E_DUP_PHONY all" {
		t.Errorf("got %v", err)
	}
	if !b.HasPhony("all") || b.HasPhony("x") {
		t.Error("HasPhony")
	}
	s, _ := draft("write", []string{"out/a"}, nil).Finish()
	b.AddStep(s)
	s2, _ := draft("write", []string{"out/b"}, nil).Finish()
	b.AddStep(s2)
	if s2.Serial != 1 {
		t.Error("serial")
	}
}

func TestCheckRef(t *testing.T) {
	for _, ok := range []string{"@a", "@_a1", "src/a", "out/x"} {
		if CheckRef(ok) != nil {
			t.Errorf("%q rejected", ok)
		}
	}
	for _, bad := range []string{"@", "@1a", "@a-b", "@a/b", "a b", "", "/a"} {
		if CheckRef(bad) == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}
