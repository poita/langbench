package spreadsheet_test

import (
	"fmt"
	"strings"
	"testing"

	"example.com/spreadsheet"
)

// build applies "CELL content" assignments.
func build(t *testing.T, sets ...string) *spreadsheet.Sheet {
	t.Helper()
	s := spreadsheet.New()
	for _, a := range sets {
		name, content, _ := strings.Cut(a, " ")
		if err := s.Set(name, content); err != nil {
			t.Fatalf("Set(%q): %v", a, err)
		}
	}
	return s
}

func show(t *testing.T, s *spreadsheet.Sheet, name string) string {
	t.Helper()
	v, err := s.Get(name)
	if err != nil {
		t.Fatal(err)
	}
	return v.String()
}

func TestFormulas(t *testing.T) {
	tests := []struct {
		name    string
		sets    []string // applied before the formula under test
		formula string
		want    string
	}{
		{"precedence", nil, "=1+2*3", "7"},
		{"parens", nil, "=(1+2)*3", "9"},
		{"unary", nil, "=-2*3-4", "-10"},
		{"mul unary", nil, "=2*-3", "-6"},
		{"double neg", nil, "=--5", "5"},
		{"cmp lowest", nil, "=1<2+3", "1"},
		{"concat below add", nil, "=1+2&3", "33"},
		{"left assoc sub", nil, "=10-3-2", "5"},
		{"left assoc div", nil, "=100/10/5", "2"},
		{"div zero", nil, "=1/0", "#DIV/0!"},
		{"div negative zero", nil, "=1/(0*-1)", "#DIV/0!"},
		{"overflow", nil, "=1" + strings.Repeat("0", 200) + "*1" + strings.Repeat("0", 200), "#VALUE!"},
		{"string arithmetic", nil, `="5"+1`, "#VALUE!"},
		{"string negate", nil, `=-"a"`, "#VALUE!"},
		{"empty ref arithmetic", nil, "=Z1+1", "1"},
		{"empty unary then concat", nil, `=-Z1&"x"`, "0x"},
		{"empty concat", nil, `=Z1&"x"`, "x"},
		{"whole result empty", nil, "=Z1", "0"},
		{"paren passes empty", nil, `=(Z1)=""`, "1"},
		{"if passes empty", nil, `=IF(1,Z1,7)&"x"`, "x"},
		{"count paren empty", nil, "=COUNT((Z1))", "0"},
		{"concat number", nil, `="n="&0.5&"/"&1/3`, "n=0.5/0.3333333333"},
		{"cmp number string eq", nil, `=1="1"`, "0"},
		{"cmp number string ne", nil, `=1<>"1"`, "1"},
		{"cmp number string lt", nil, `=1<"1"`, "#VALUE!"},
		{"cmp empty empty", nil, "=Z1=Z2", "1"},
		{"cmp empty string", nil, `=Z1=""`, "1"},
		{"cmp empty number", nil, "=Z1<1", "1"},
		{"cmp strings case", nil, `="a"<"B"`, "0"},
		{"cmp prefix", nil, `="ab">"a"`, "1"},
		{"cmp code point order", nil, "=\"\U0001F600\">\"ｚ\"", "1"},
		{"cmp ops", nil, "=(2>=2)+(2<=1)+(3<>3)+(3=3)", "2"},
		{"if lazy", []string{"B1 =1/0"}, "=IF(1,5,B1)", "5"},
		{"if error branch", []string{"B1 =1/0"}, "=IF(0,5,B1)", "#DIV/0!"},
		{"if string cond", nil, `=IF("a",1,2)`, "#VALUE!"},
		{"if empty cond", nil, "=IF(Z1,1,2)", "2"},
		{"sum range", []string{"B1 3", "B2 4.5", `B3 "x"`}, "=SUM(B1:B3)", "7.5"},
		{"sum reversed range", []string{"B1 3", "C2 4"}, "=SUM(C2:B1)", "7"},
		{"avg", []string{"B1 3", "B2 4.5", `B3 "x"`}, "=AVG(B1:B3)", "3.75"},
		{"avg none", nil, "=AVG(B1:B3)", "#DIV/0!"},
		{"min max none", nil, "=MIN(B1:B3)+MAX(B1:B3)", "0"},
		{"min", []string{"B1 3", "B2 -4"}, "=MIN(B1:B2, 10)", "-4"},
		{"max", []string{"B1 3", "B2 -4"}, "=MAX(B1:B2, 10)", "10"},
		{"count", []string{"B1 3", "B2 4.5", `B3 "x"`}, "=COUNT(B1:B3, 1, Z9)", "3"},
		{"sum expr string", nil, `=SUM(1,"a")`, "#VALUE!"},
		{"sum range error", []string{"B1 =1/0", "B2 5"}, "=SUM(B1:B2)", "#DIV/0!"},
		{"sum overflow", nil, "=SUM(1" + strings.Repeat("0", 300) + "*100000000,1" + strings.Repeat("0", 300) + "*100000000)", "#VALUE!"},
		{"invalid ref", nil, "=AAA1+1", "#REF!"},
		{"invalid row zero", nil, "=A0", "#REF!"},
		{"invalid row big", nil, "=A10000", "#REF!"},
		{"invalid leading zero", nil, "=A01", "#REF!"},
		{"invalid in unselected if", nil, "=IF(1,2,A0)", "#REF!"},
		{"invalid range corner", nil, "=SUM(A1:A0)", "#REF!"},
		{"spaces", nil, `= 1 +  2 * ( 3 ) & "x y"`, "7x y"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := spreadsheet.New()
			for _, a := range tc.sets {
				name, content, _ := strings.Cut(a, " ")
				if err := s.Set(name, content); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.Set("Y1", tc.formula); err != nil {
				t.Fatal(err)
			}
			if got := show(t, s, "Y1"); got != tc.want {
				t.Errorf("%s = %q, want %q", tc.formula, got, tc.want)
			}
		})
	}
}

func TestExample1Cycles(t *testing.T) {
	s := build(t, "A1 10", "A2 32", "A3 =A1+A2")
	if got := show(t, s, "A3"); got != "42" {
		t.Fatalf("A3 = %s", got)
	}
	s.Set("A1", "=A3")
	for _, n := range []string{"A1", "A3"} {
		if got := show(t, s, n); got != "#CYCLE!" {
			t.Errorf("%s = %s, want #CYCLE!", n, got)
		}
	}
	s.Set("A1", "5")
	if got := show(t, s, "A3"); got != "37" {
		t.Errorf("A3 = %s after breaking cycle, want 37", got)
	}
}

func TestCycleShapes(t *testing.T) {
	s := build(t, "A1 =A1+1")
	if got := show(t, s, "A1"); got != "#CYCLE!" {
		t.Errorf("self reference: %s", got)
	}
	s = build(t, "A1 =SUM(A1:A3)")
	if got := show(t, s, "A1"); got != "#CYCLE!" {
		t.Errorf("range containing itself: %s", got)
	}
	// B reads a cycle but is not on it; IF can mask the error.
	s = build(t, "A1 =A2", "A2 =A1", "B1 =A1+1", "B2 =IF(1,5,A1)")
	if got := show(t, s, "B1"); got != "#CYCLE!" {
		t.Errorf("B1 = %s", got)
	}
	// The IF branch is still a dependency, so B2 is only masked, not cyclic.
	if got := show(t, s, "B2"); got != "5" {
		t.Errorf("B2 = %s", got)
	}
	// Clearing one member breaks the cycle and downstream cells recover.
	s.Clear("A2")
	if got := show(t, s, "B1"); got != "1" {
		t.Errorf("B1 after clear = %s", got)
	}
	// A cycle whose cells are shadowed by a cyclic formula that would
	// otherwise compute a value.
	s = build(t, "A1 =IF(1,1,A2)", "A2 =A1")
	if got := show(t, s, "A1"); got != "#CYCLE!" {
		t.Errorf("static dependencies: A1 = %s", got)
	}
}

func TestEditsRecalculate(t *testing.T) {
	s := build(t, "A1 1", "B1 =A1+1", "C1 =B1*2", "D1 =SUM(A1:C1)")
	if got := show(t, s, "D1"); got != "7" {
		t.Fatalf("D1 = %s", got)
	}
	s.Set("A1", "10")
	if got := show(t, s, "D1"); got != "43" {
		t.Errorf("D1 = %s, want 43", got)
	}
	s.Set("B1", `"text"`)
	if got := show(t, s, "C1"); got != "#VALUE!" {
		t.Errorf("C1 = %s, want #VALUE!", got)
	}
	s.Clear("B1")
	if got := show(t, s, "C1"); got != "0" {
		t.Errorf("C1 = %s, want 0", got)
	}
	// Formulas that reference a cell filled in later.
	s = build(t, "A1 =B1&\"!\"")
	s.Set("B1", `"hi"`)
	if got := show(t, s, "A1"); got != "hi!" {
		t.Errorf("A1 = %s", got)
	}
}

func TestLiterals(t *testing.T) {
	s := build(t, "A1 007", "A2 -0", "A3 4.50", `A4 ""`, `A5 "a b"`, "A6 -3")
	want := map[string]string{"A1": "7", "A2": "0", "A3": "4.5", "A4": "", "A5": "a b", "A6": "-3"}
	for n, w := range want {
		if got := show(t, s, n); got != w {
			t.Errorf("%s = %q, want %q", n, got, w)
		}
	}
	if err := spreadsheet.New().Set("A1", "abc"); err == nil {
		t.Error("expected error for invalid content")
	}
	if err := spreadsheet.New().Set("A1", "=1+"); err == nil {
		t.Error("expected error for syntax error")
	}
	if err := spreadsheet.New().Set("a1", "1"); err == nil {
		t.Error("expected error for invalid cell name")
	}
}

func TestSyntaxErrorLeavesSheetUnchanged(t *testing.T) {
	s := build(t, "A1 5")
	if err := s.Set("A1", "=(1"); err == nil {
		t.Fatal("expected error")
	}
	if got := show(t, s, "A1"); got != "5" {
		t.Errorf("A1 = %s", got)
	}
}

func TestDumpOrder(t *testing.T) {
	s := build(t, "B2 1", "A2 2", "AA1 3", "Z1 4", "A1 5", `C3 ""`)
	s.Set("A2", "7")
	s.Clear("B2")
	var got []string
	for _, e := range s.Dump() {
		got = append(got, e.Name+"="+e.Value.String())
	}
	want := "A1=5 Z1=4 AA1=3 A2=7 C3="
	if strings.Join(got, " ") != want {
		t.Errorf("Dump = %v, want %s", got, want)
	}
	if len(spreadsheet.New().Dump()) != 0 {
		t.Error("empty sheet should dump nothing")
	}
}

func TestGetEmptyAndInvalid(t *testing.T) {
	s := spreadsheet.New()
	v, err := s.Get("Q7")
	if err != nil || !v.IsEmpty() || v.String() != "" {
		t.Errorf("Get(Q7) = %v, %v", v, err)
	}
	if _, err := s.Get("AAA1"); err == nil {
		t.Error("expected error for invalid name")
	}
}

func TestValueAccessors(t *testing.T) {
	s := build(t, "A1 2.5", `A2 "s"`, "A3 =1/0")
	a1, _ := s.Get("A1")
	a2, _ := s.Get("A2")
	a3, _ := s.Get("A3")
	if a1.Kind() != spreadsheet.KindNumber || a1.Num() != 2.5 {
		t.Error("A1")
	}
	if a2.Kind() != spreadsheet.KindString || a2.Text() != "s" {
		t.Error("A2")
	}
	if a3.Kind() != spreadsheet.KindError || a3.Err() != spreadsheet.ErrDiv0 {
		t.Error("A3")
	}
}

func TestDeepChain(t *testing.T) {
	const n = 9999
	s := spreadsheet.New()
	s.Set("A1", "1")
	for i := 2; i <= n; i++ {
		s.Set(fmt.Sprintf("A%d", i), fmt.Sprintf("=A%d+1", i-1))
	}
	if got := show(t, s, "A9999"); got != "9999" {
		t.Fatalf("A9999 = %s", got)
	}
	s.Set("A1", "5")
	if got := show(t, s, "A9999"); got != "10003" {
		t.Errorf("A9999 = %s", got)
	}
	// Close the chain into one big cycle, then break it again.
	s.Set("A1", "=A9999")
	if got := show(t, s, "A5000"); got != "#CYCLE!" {
		t.Errorf("A5000 = %s", got)
	}
	s.Set("A1", "1")
	if got := show(t, s, "A5000"); got != "5000" {
		t.Errorf("A5000 = %s", got)
	}
}

func TestRangeEdits(t *testing.T) {
	s := spreadsheet.New()
	s.Set("B1", "=SUM(A1:A100)")
	for i := 1; i <= 100; i++ {
		s.Set(fmt.Sprintf("A%d", i), fmt.Sprint(i))
	}
	if got := show(t, s, "B1"); got != "5050" {
		t.Errorf("B1 = %s", got)
	}
	s.Clear("A100")
	if got := show(t, s, "B1"); got != "4950" {
		t.Errorf("B1 = %s", got)
	}
}

// ExampleSheet shows basic use of the library.
func ExampleSheet() {
	s := spreadsheet.New()
	s.Set("A1", "10")
	s.Set("A2", "32")
	s.Set("A3", "=A1+A2")
	v, _ := s.Get("A3")
	fmt.Println(v)

	s.Set("A1", "=A3") // creates a cycle
	v, _ = s.Get("A3")
	fmt.Println(v)
	// Output:
	// 42
	// #CYCLE!
}
