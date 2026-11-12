package header

import "testing"

func TestParseBlock(t *testing.T) {
	tests := []struct {
		name      string
		in        string
		wantNames []string
		wantBody  string
	}{
		{"simple", "A: 1\nB: 2\n\nbody", []string{"a", "b"}, "body"},
		{"folded", "Subject: a\n b\n\tc\n\nx", []string{"subject"}, "x"},
		{"no blank line", "A: 1", []string{"a"}, ""},
		{"space in name ends block", "A: 1\nSubject :x\nB: 2\n", []string{"a"}, "Subject :x\nB: 2\n"},
		{"no colon", "A: 1\nno colon here\n", []string{"a"}, "no colon here\n"},
		{"empty name", ": novalue\n", nil, ": novalue\n"},
		{"mbox from line", "From nobody Mon Sep  1 00:00:00 2025\nA: 1\n", nil, "From nobody Mon Sep  1 00:00:00 2025\nA: 1\n"},
		{"leading continuation", " A: 1\nB: 2\n", nil, " A: 1\nB: 2\n"},
		{"empty message", "", nil, ""},
		{"blank first line", "\nA: 1\n", nil, "A: 1\n"},
		{"repeated", "X: 1\nx: 2\n\n", []string{"x", "x"}, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fs, off := Parse([]byte(tc.in))
			if got := tc.in[off:]; got != tc.wantBody {
				t.Errorf("body = %q, want %q", got, tc.wantBody)
			}
			if len(fs) != len(tc.wantNames) {
				t.Fatalf("fields = %v, want names %v", fs, tc.wantNames)
			}
			for i, f := range fs {
				if f.Key() != tc.wantNames[i] {
					t.Errorf("field %d name %q, want %q", i, f.Key(), tc.wantNames[i])
				}
			}
		})
	}
}

func TestUnfold(t *testing.T) {
	fs, _ := Parse([]byte("Subject: a\n  b\n\tc\n\n"))
	if got, want := fs[0].Value, " a  b\tc"; got != want {
		t.Errorf("value = %q, want %q", got, want)
	}
}

func TestDisplay(t *testing.T) {
	fs, _ := Parse([]byte("Subject: =?utf-8?Q?Caf=C3=A9?=   report \nContent-Type:  text/plain;\n  charset=x \n\n"))
	if got := fs[0].Display(); got != "Café   report" {
		t.Errorf("subject display = %q", got)
	}
	if got := fs[1].Display(); got != "text/plain; charset=x" {
		t.Errorf("content-type display = %q", got)
	}
}

func TestGet(t *testing.T) {
	fs, _ := Parse([]byte("X: 1\nContent-Type : no\nContent-type: a\n\n"))
	f, ok := fs.Get("x")
	if !ok || f.Value != " 1" {
		t.Errorf("Get x = %v %v", f, ok)
	}
	if _, ok := fs.Get("content-type"); ok {
		// "Content-Type : no" is not a field line and ends the block.
		t.Errorf("content-type should not be found")
	}
}
