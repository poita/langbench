package linediff

import "testing"

func TestApplyExample(t *testing.T) {
	a := lines("a\nb\nc\nd\ne\n")
	script, err := ParseScript(lines(" a\n-b\n+B\n c\n+c2\n-d\n e\n+f\n"))
	if err != nil {
		t.Fatal(err)
	}
	out, err := Apply(a, script)
	if err != nil {
		t.Fatal(err)
	}
	var got string
	for _, l := range out {
		got += string(l) + "\n"
	}
	if want := "a\nB\nc\nc2\ne\nf\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestApplyNonMinimalScript(t *testing.T) {
	a := lines("x\n")
	script, _ := ParseScript(lines("-x\n+x\n+y\n-\n"))
	// The script's '-' lines are "x" and "": it does not match a.
	if _, err := Apply(a, script); err != ErrMismatch {
		t.Fatalf("err = %v, want ErrMismatch", err)
	}
	script, _ = ParseScript(lines("+y\n-x\n+x\n"))
	out, err := Apply(a, script)
	if err != nil || len(out) != 2 || string(out[0]) != "y" || string(out[1]) != "x" {
		t.Fatalf("out=%q err=%v", out, err)
	}
}

func TestApplyMismatch(t *testing.T) {
	a := lines("a\nb\n")
	for _, s := range []string{" a\n", " a\n c\n", " a\n b\n c\n", "-b\n"} {
		script, _ := ParseScript(lines(s))
		if _, err := Apply(a, script); err != ErrMismatch {
			t.Errorf("script %q: err = %v", s, err)
		}
	}
}

func TestApplyEmpty(t *testing.T) {
	out, err := Apply(nil, nil)
	if err != nil || len(out) != 0 {
		t.Fatalf("%v %v", out, err)
	}
}
