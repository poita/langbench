package prog

import (
	"strings"
	"testing"

	"regex/syntax"
)

func compile(t *testing.T, pat string) *Program {
	t.Helper()
	tree, err := syntax.Parse(pat)
	if err != nil {
		t.Fatal(err)
	}
	p, err := Compile(tree)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func count(p *Program, op Op) int {
	n := 0
	for _, in := range p.Insts {
		if in.Op == op {
			n++
		}
	}
	return n
}

func TestSingleCharLoopIsOneInstruction(t *testing.T) {
	p := compile(t, `\w{2,5}`)
	if len(p.Insts) != 2 || p.Insts[0].Op != OpCharLoop || p.Insts[0].B != 2 || p.Insts[0].C != 5 {
		t.Errorf("unexpected program:\n%s", p)
	}
	if p := compile(t, `.*`); p.Insts[0].A != -1 {
		t.Errorf(".* should use the any loop:\n%s", p)
	}
}

func TestMarkCheckOnlyWhenBodyCanBeEmpty(t *testing.T) {
	if p := compile(t, `(ab)*`); count(p, OpMark) != 0 || count(p, OpCheck) != 0 {
		t.Errorf("non-nullable body got mark/check:\n%s", p)
	}
	p := compile(t, `(a*)*`)
	if count(p, OpMark) != 1 || count(p, OpCheck) != 1 {
		t.Errorf("nullable body lacks mark/check:\n%s", p)
	}
}

func TestCounted(t *testing.T) {
	if p := compile(t, `(ab){0}`); len(p.Insts) != 1 {
		t.Errorf("x{0} should emit only match:\n%s", p)
	}
	// min copies inline plus max-min optional copies, each with a split.
	p := compile(t, `(ab){2,4}`)
	if count(p, OpSplit) != 2 || count(p, OpSave) != 8 {
		t.Errorf("unexpected expansion:\n%s", p)
	}
}

func TestStartFilters(t *testing.T) {
	if p := compile(t, `^a`); !p.Anchored {
		t.Error("^a should be anchored")
	}
	p := compile(t, `ab|cd`)
	if p.First == nil || !p.First['a'] || !p.First['c'] || p.First['b'] {
		t.Error("bad first set for ab|cd")
	}
	if compile(t, `a*`).First != nil || compile(t, `.b`).First != nil {
		t.Error("nullable or full first set should disable the filter")
	}
}

func TestTooLarge(t *testing.T) {
	tree, _ := syntax.Parse(`((((a|b){100}){100}){100}){100}`)
	if _, err := Compile(tree); err != ErrTooLarge {
		t.Errorf("err = %v, want ErrTooLarge", err)
	}
}

func TestDisassembly(t *testing.T) {
	s := compile(t, `(a|b)*c`).String()
	for _, want := range []string{"split", "save 0", "jmp", "match"} {
		if !strings.Contains(s, want) {
			t.Errorf("disassembly lacks %q:\n%s", want, s)
		}
	}
}
