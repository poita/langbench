package engine_test

import (
	"strings"
	"testing"

	"buildsys/engine"
	"buildsys/vfs"
)

func TestConfigurationErrorLeavesWorkspaceUntouched(t *testing.T) {
	fs := vfs.New()
	fs.Write("main.kiln", "let = 1\n")
	res := engine.Build(fs, nil, 1)
	if res.Err == nil || res.Err.Error() != "E_PARSE main.kiln:1" {
		t.Fatalf("err = %v", res.Err)
	}
	if fs.Has(vfs.StateFile) {
		t.Error("state file written after configuration error")
	}
}

func TestStateAlwaysWritten(t *testing.T) {
	fs := vfs.New()
	fs.Write("main.kiln", "step {\n out \"out/a\"\n cmd write(\"x\")\n}\ndefault \"out/a\"\n")
	engine.Build(fs, nil, 1)
	before, _ := fs.Read(vfs.StateFile)
	res := engine.Build(fs, nil, 4)
	if res.Err != nil || res.Hits != 1 || res.Ran != 0 || res.Time != 0 {
		t.Fatalf("result = %+v", res)
	}
	if after, _ := fs.Read(vfs.StateFile); after != before {
		t.Errorf("state changed on a pure hit:\n%s\n%s", before, after)
	}
}

func TestStaleEntriesOfUnreachableStepsKept(t *testing.T) {
	fs := vfs.New()
	fs.Write("main.kiln", "step {\n out \"out/a\"\n cmd write(\"a\")\n}\nstep {\n out \"out/b\"\n cmd write(\"b\")\n}\n")
	engine.Build(fs, []string{"out/a", "out/b"}, 2)
	res := engine.Build(fs, []string{"out/a"}, 1)
	if res.Hits != 1 {
		t.Fatalf("result = %+v", res)
	}
	st, _ := fs.Read(vfs.StateFile)
	if want := "step out/b\n"; !strings.Contains(st, want) {
		t.Errorf("entry for unreachable step dropped:\n%s", st)
	}
}
