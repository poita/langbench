package spreadsheet

import (
	"fmt"
	"strings"
	"testing"
)

// run applies "set"/"clear" lines and returns the displayed value of every
// "get" line, joined with '|'.
func run(t *testing.T, script string) string {
	t.Helper()
	s := New()
	var out []string
	for _, line := range strings.Split(strings.TrimSpace(script), "\n") {
		f := strings.SplitN(strings.TrimSpace(line), " ", 3)
		var err error
		switch f[0] {
		case "set":
			err = s.Set(f[1], f[2])
		case "clear":
			err = s.Clear(f[1])
		case "get":
			var v Value
			v, err = s.Get(f[1])
			out = append(out, v.String())
		}
		if err != nil {
			t.Fatalf("%q: %v", line, err)
		}
	}
	return strings.Join(out, "|")
}

func TestEvaluation(t *testing.T) {
	tests := []struct{ name, formula, want string }{
		{"precedence", "=1+2*3", "7"},
		{"unary", "=-2*3-4", "-10"},
		{"double neg", "=--5", "5"},
		{"cmp lowest", "=1<2+3", "1"},
		{"cat below add", "=1+2&3", "33"},
		{"div zero", "=1/0", "#DIV/0!"},
		{"div neg zero", "=1/-0", "#DIV/0!"},
		{"overflow", "=1" + strings.Repeat("0", 300) + "*1" + strings.Repeat("0", 300), "#VALUE!"},
		{"string arithmetic", `="5"+1`, "#VALUE!"},
		{"empty arithmetic", "=Z1+1", "1"},
		{"empty unary cat", `=-Z1&"x"`, "0x"},
		{"paren empty cat", `=(Z1)&"x"`, "x"},
		{"if empty passes", `=IF(1,Z1,7)&"x"`, "x"},
		{"empty eq empty string", `=(Z1)=""`, "1"},
		{"count paren", "=COUNT((Z1))", "0"},
		{"num vs str eq", `=1="1"`, "0"},
		{"num vs str ne", `=1<>"1"`, "1"},
		{"num vs str lt", `=1<"1"`, "#VALUE!"},
		{"str order", `="a"<"b"`, "1"},
		{"str case", `="B"<"a"`, "1"},
		{"str prefix", `="ab">"a"`, "1"},
		{"code point order", `="😀">"ｚ"`, "1"},
		{"if lazy", "=IF(1,5,1/0)", "5"},
		{"if else", "=IF(0,5,6)", "6"},
		{"if string cond", `=IF("a",1,2)`, "#VALUE!"},
		{"sum none", "=SUM(Z1:Z3)", "0"},
		{"avg none", "=AVG(Z1:Z3)", "#DIV/0!"},
		{"min none", "=MIN(Z1:Z3)", "0"},
		{"max neg", "=MAX(-3,-5)", "-3"},
		{"sum expr string", `=SUM(1,"a")`, "#VALUE!"},
		{"invalid ref", "=AAA1+1", "#REF!"},
		{"invalid ref in dead branch", "=IF(1,2,A0)", "#REF!"},
		{"third", "=1/3", "0.3333333333"},
		{"big", "=100000000000000000000", "1e+20"},
		{"first error wins", "=1/0+AAA1", "#REF!"}, // #REF! covers the whole formula
		{"string a before b", `="x"+(1/0)`, "#VALUE!"},
		{"div0 first", `=(1/0)+"x"`, "#DIV/0!"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := run(t, "set A1 "+tt.formula+"\nget A1"); got != tt.want {
				t.Errorf("%s = %q, want %q", tt.formula, got, tt.want)
			}
		})
	}
}

func TestRangeAggregates(t *testing.T) {
	script := `
set B1 3
set B2 4.5
set B3 "x"
set C1 =SUM(B1:B3)
set C2 =AVG(B3:B1)
set C3 =COUNT(B1:B4)
set C4 =MIN(B1:B3, 1)
set C5 =MAX(B1:B3, 10)
get C1
get C2
get C3
get C4
get C5`
	if got, want := run(t, script), "7.5|3.75|2|1|10"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestRangeErrorPropagates(t *testing.T) {
	got := run(t, "set A1 =1/0\nset B1 =SUM(A1:A2)\nget B1\nset A1 5\nget B1")
	if got != "#DIV/0!|5" {
		t.Errorf("got %q", got)
	}
}

func TestIncrementalUpdateAndClear(t *testing.T) {
	got := run(t, `
set A1 10
set A2 =A1*2
set A3 =A2+A1
get A3
set A1 1
get A3
clear A1
get A3
get A1
set A1 "s"
get A2`)
	if got != "30|3|0||#VALUE!" {
		t.Errorf("got %q", got)
	}
}

func TestCycles(t *testing.T) {
	got := run(t, `
set A1 10
set A2 =A1+1
set A3 =A2+1
get A3
set A1 =A3
get A1
get A2
get A3
set A4 =A3+1
get A4
set A5 =IF(1,7,A3)
get A5
set A1 5
get A2
get A3
get A4`)
	if got != "12|#CYCLE!|#CYCLE!|#CYCLE!|#CYCLE!|7|6|7|8" {
		t.Errorf("got %q", got)
	}
}

func TestSelfAndRangeSelfCycle(t *testing.T) {
	got := run(t, "set A1 =A1+1\nget A1\nset B2 =SUM(A1:C3)\nget B2\nset A1 1\nget B2")
	if got != "#CYCLE!|#CYCLE!|#CYCLE!" {
		t.Errorf("got %q", got)
	}
	// Note: B2 stays cyclic because its own range covers it.
}

func TestIfMasksCycleError(t *testing.T) {
	got := run(t, "set A1 =A1\nset B1 =IF(1,5,A1)\nget B1\nset C1 =IF(0,5,A1)\nget C1")
	if got != "5|#CYCLE!" {
		t.Errorf("got %q", got)
	}
}

func TestForwardReferenceToUnsetCell(t *testing.T) {
	got := run(t, "set A1 =B1+1\nget A1\nset B1 41\nget A1\nclear B1\nget A1")
	if got != "1|42|1" {
		t.Errorf("got %q", got)
	}
}

func TestReplaceFormulaDropsOldDependencies(t *testing.T) {
	s := New()
	s.Set("A1", "1")
	s.Set("B1", "=A1")
	s.Set("B1", "7")
	s.Set("A1", "=B1") // would be a cycle if B1 still read A1
	if v, _ := s.Get("A1"); v.String() != "7" {
		t.Errorf("A1 = %v", v)
	}
}

func TestDumpOrderAndEmpty(t *testing.T) {
	s := New()
	if len(s.Dump()) != 0 || len(s.AppendDump(nil)) != 0 {
		t.Error("empty sheet should dump nothing")
	}
	s.Set("B2", "1")
	s.Set("A2", `""`)
	s.Set("AA1", "2")
	s.Set("Z1", "3")
	s.Set("A3", "=A9")
	s.Set("C9", "5")
	s.Clear("C9")
	var names []string
	for _, e := range s.Dump() {
		names = append(names, e.Name)
	}
	if got := strings.Join(names, ","); got != "Z1,AA1,A2,B2,A3" {
		t.Errorf("order = %s", got)
	}
	want := "Z1 3\nAA1 2\nA2 \nB2 1\nA3 0\n"
	if got := string(s.AppendDump(nil)); got != want {
		t.Errorf("AppendDump = %q, want %q", got, want)
	}
}

func TestSetErrors(t *testing.T) {
	s := New()
	if err := s.Set("a1", "1"); err == nil {
		t.Error("bad name accepted")
	}
	for _, c := range []string{"", "abc", "1.", ".5", "1e5", `"open`, `"a"b"`, "=1+"} {
		if err := s.Set("A1", c); err == nil {
			t.Errorf("content %q accepted", c)
		}
	}
	if v, _ := s.Get("A1"); v.Kind() != Empty {
		t.Error("failed Set modified the sheet")
	}
}

func TestNegativeZeroDisplay(t *testing.T) {
	if got := run(t, "set A1 -0\nset A2 =-A1\nget A1\nget A2"); got != "0|0" {
		t.Errorf("got %q", got)
	}
}

func TestLongChainDoesNotRecurse(t *testing.T) {
	s := New()
	s.Set("A1", "1")
	const n = 9000
	for i := 2; i <= n; i++ {
		s.Set(fmt.Sprintf("A%d", i), fmt.Sprintf("=A%d+1", i-1))
	}
	if v, _ := s.Get(fmt.Sprintf("A%d", n)); v.String() != fmt.Sprint(n) {
		t.Errorf("tail = %v", v)
	}
	s.Set("A1", "5")
	if v, _ := s.Get(fmt.Sprintf("A%d", n)); v.String() != fmt.Sprint(n+4) {
		t.Errorf("tail after edit = %v", v)
	}
	s.Set("A1", fmt.Sprintf("=A%d", n))
	if v, _ := s.Get(fmt.Sprintf("A%d", n/2)); v.String() != "#CYCLE!" {
		t.Errorf("middle = %v", v)
	}
}

func TestValueAccessors(t *testing.T) {
	if v := NumberValue(2.5); v.Kind() != Number || v.Number() != 2.5 {
		t.Error("number")
	}
	if v := StringValue("hi"); v.Kind() != String || v.Str() != "hi" {
		t.Error("string")
	}
	if v := ErrorValue(ErrRef); v.Kind() != Error || v.Err() != ErrRef || v.String() != "#REF!" {
		t.Error("error")
	}
	var z Value
	if z.Kind() != Empty || z.String() != "" {
		t.Error("zero value")
	}
}
