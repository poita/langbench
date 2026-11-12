package diff_test

import (
	"fmt"
	"math/rand"
	"reflect"
	"strings"
	"testing"

	"example.com/diff"
)

func lines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, ",")
}

func TestDiffPaperExample(t *testing.T) {
	a, b := lines("a,b,c,a,b,b,a"), lines("c,b,a,b,a,c")
	s := diff.Diff(a, b)
	if s.Cost() != 5 {
		t.Fatalf("cost = %d, want 5:\n%s", s.Cost(), s)
	}
	got, err := diff.Apply(a, s)
	if err != nil || !reflect.DeepEqual(got, b) {
		t.Fatalf("Apply = %v, %v; want %v", got, err, b)
	}
}

func TestDiffIdenticalAndEmpty(t *testing.T) {
	if s := diff.Diff(nil, nil); len(s) != 0 {
		t.Fatalf("empty diff = %v", s)
	}
	a := lines("x,y,z")
	s := diff.Diff(a, a)
	if len(s) != 3 || s.Cost() != 0 {
		t.Fatalf("identical diff = %v", s)
	}
	if s := diff.Diff(nil, a); s.Cost() != 3 {
		t.Fatalf("cost = %d", s.Cost())
	}
	if s := diff.Diff(a, nil); s.Cost() != 3 {
		t.Fatalf("cost = %d", s.Cost())
	}
}

func TestWhitespaceSignificant(t *testing.T) {
	a := []string{"  indented", "trailing ", "trailing", " both ", "plain"}
	b := []string{"  indented", "trailing", "trailing ", " both", "plain", " "}
	s := diff.Diff(a, b)
	if s.Cost() != 5 {
		t.Fatalf("cost = %d, want 5:\n%s", s.Cost(), s)
	}
}

func TestApply(t *testing.T) {
	a := lines("a,b,c,d,e")
	s, err := diff.ParseScript([]string{" a", "-b", "+B", " c", "+c2", "-d", " e", "+f"})
	if err != nil {
		t.Fatal(err)
	}
	got, err := diff.Apply(a, s)
	if err != nil {
		t.Fatal(err)
	}
	if want := lines("a,B,c,c2,e,f"); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestApplyErrors(t *testing.T) {
	a := []string{"a", "b"}
	bad := []diff.Script{
		{{Op: diff.Keep, Line: "x"}, {Op: diff.Keep, Line: "b"}},
		{{Op: diff.Keep, Line: "a"}},
		{{Op: diff.Keep, Line: "a"}, {Op: diff.Keep, Line: "b"}, {Op: diff.Delete, Line: "c"}},
	}
	for i, s := range bad {
		if _, err := diff.Apply(a, s); err == nil {
			t.Errorf("case %d: expected error", i)
		}
	}
}

func TestParseScript(t *testing.T) {
	s, err := diff.ParseScript([]string{"+-x", "  ", "+", "-"})
	if err != nil {
		t.Fatal(err)
	}
	want := diff.Script{{diff.Insert, "-x"}, {diff.Keep, " "}, {diff.Insert, ""}, {diff.Delete, ""}}
	if !reflect.DeepEqual(s, want) {
		t.Fatalf("got %v", s)
	}
	if _, err := diff.ParseScript([]string{"?x"}); err == nil {
		t.Error("expected error for bad tag")
	}
	if _, err := diff.ParseScript([]string{""}); err == nil {
		t.Error("expected error for empty line")
	}
}

func TestRoundTripRandom(t *testing.T) {
	rng := rand.New(rand.NewSource(3))
	for iter := 0; iter < 500; iter++ {
		gen := func() []string {
			l := make([]string, rng.Intn(30))
			for i := range l {
				l[i] = fmt.Sprint(rng.Intn(5))
			}
			return l
		}
		a, b := gen(), gen()
		s := diff.Diff(a, b)
		got, err := diff.Apply(a, s)
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != len(b) || (len(b) > 0 && !reflect.DeepEqual(got, b)) {
			t.Fatalf("a=%v b=%v got=%v", a, b, got)
		}
	}
}

func ExampleDiff() {
	a := []string{"a", "b", "c"}
	b := []string{"a", "c", "d"}
	s := diff.Diff(a, b)
	fmt.Print(s)
	fmt.Println("cost:", s.Cost())
	// Output:
	//  a
	// -b
	//  c
	// +d
	// cost: 2
}

func ExampleApply() {
	a := []string{"one", "two"}
	script, _ := diff.ParseScript([]string{" one", "-two", "+2"})
	out, _ := diff.Apply(a, script)
	fmt.Println(out)
	// Output: [one 2]
}
