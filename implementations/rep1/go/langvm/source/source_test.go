package source

import "testing"

func TestSplit(t *testing.T) {
	cases := []struct {
		name, in string
		wantErr  string
		mods     int
	}{
		{"empty", "", "error: bad-module at 1:1", 0},
		{"no header", "fn main() {}\n", "error: bad-module at 1:1", 0},
		{"two modules", "@module a\nx\n@module b\n", "", 2},
		{"crlf", "@module a\r\nx\r\n", "", 1},
		{"trailing space", "@module a \n", "error: bad-module at 1:1", 0},
		{"bad later header", "@module a\n\n@modul b\n", "error: bad-module at 3:1", 0},
		{"keyword name", "@module a\n@module fn\n", "error: bad-module at 2:1", 0},
		{"dup", "@module a\n@module b\n@module a\n", "error: dup-module at 3:1", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			mods, err := Split(c.in)
			if c.wantErr != "" {
				if err == nil || err.Error() != c.wantErr {
					t.Fatalf("got %v, want %s", err, c.wantErr)
				}
				return
			}
			if err != nil || len(mods) != c.mods {
				t.Fatalf("got %d modules, err %v", len(mods), err)
			}
		})
	}
}

func TestBodyLines(t *testing.T) {
	mods, _ := Split("@module a\nline1\r\nline2\n@module b\n")
	if len(mods[0].Lines) != 2 || mods[0].Lines[0] != "line1" || len(mods[1].Lines) != 0 {
		t.Errorf("unexpected bodies: %#v %#v", mods[0], mods[1])
	}
}
