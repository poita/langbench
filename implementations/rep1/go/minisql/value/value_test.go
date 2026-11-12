package value

import "testing"

func TestCompareOrder(t *testing.T) {
	ordered := []Value{
		Null(), Int(-5), RealHundredths(-150), Int(-1), Int(0), RealHundredths(50),
		Int(1), RealHundredths(150), Int(2), Int(100),
		Text(""), Text("0"), Text("B"), Text("a"), Text("ab"), Text("b"), Text("é"),
	}
	for i, a := range ordered {
		for j, b := range ordered {
			want := 0
			if i < j {
				want = -1
			} else if i > j {
				want = 1
			}
			if got := Compare(a, b); got != want {
				t.Errorf("Compare(%v, %v) = %d, want %d", a, b, got, want)
			}
		}
	}
}

func TestCompareIntReal(t *testing.T) {
	if Compare(Int(2), RealHundredths(200)) != 0 {
		t.Error("2 should equal 2.00")
	}
	if Compare(RealHundredths(-150), Int(-1)) >= 0 {
		t.Error("-1.50 should be below -1")
	}
	if Compare(Int(1<<62), RealHundredths(100)) <= 0 {
		t.Error("huge integer must not overflow")
	}
}

func TestString(t *testing.T) {
	tests := []struct {
		v    Value
		want string
	}{
		{Null(), "NULL"},
		{Int(0), "0"},
		{Int(-42), "-42"},
		{Text("hi"), "hi"},
		{RealHundredths(450), "4.50"},
		{RealHundredths(-113), "-1.13"},
		{RealHundredths(0), "0.00"},
		{RealHundredths(-5), "-0.05"},
	}
	for _, tc := range tests {
		if got := tc.v.String(); got != tc.want {
			t.Errorf("String() = %q, want %q", got, tc.want)
		}
	}
}

func TestAvg(t *testing.T) {
	tests := []struct {
		sum, count int64
		want       string
	}{
		{3, 2, "1.50"}, {4, 3, "1.33"}, {36, 8, "4.50"}, {-3, 2, "-1.50"},
		{9, 8, "1.13"}, {-9, 8, "-1.13"}, {-1, 201, "0.00"}, {80, 3, "26.67"},
	}
	for _, tc := range tests {
		if got := Avg(tc.sum, tc.count).String(); got != tc.want {
			t.Errorf("Avg(%d,%d) = %s, want %s", tc.sum, tc.count, got, tc.want)
		}
	}
}

func TestTruth(t *testing.T) {
	if tr, k := Null().Truth(); tr || k {
		t.Error("NULL is unknown")
	}
	if !Int(7).IsTrue() || Int(0).IsTrue() || RealHundredths(0).IsTrue() || !RealHundredths(1).IsTrue() {
		t.Error("numeric truth wrong")
	}
}

func TestLike(t *testing.T) {
	tests := []struct {
		s, p string
		want bool
	}{
		{"apple", "apple", true},
		{"APPLE", "apple", true},
		{"Ab_c", "ab%", true},
		{"abc", "a_c", true},
		{"ac", "a_c", false},
		{"abc", "%", true},
		{"", "%", true},
		{"", "_", false},
		{"", "", true},
		{"abc", "", false},
		{"abcabc", "%bc", true},
		{"abcabd", "%bc", false},
		{"aXbXc", "a%b%c", true},
		{"mississippi", "m%iss%ppi", true},
		{"mississippi", "m%iss%ppx", false},
		{"é", "É", false},
		{"é", "_", true},
		{"日本語", "日_語", true},
		{"日本語", "%語", true},
		{"abc", "ab", false},
		{"abc", "abcd", false},
		{"aaaaaaaaaaaaaaaaaaaab", "%a%a%a%a%a%c", false},
	}
	for _, tc := range tests {
		if got := Like(tc.s, tc.p); got != tc.want {
			t.Errorf("Like(%q, %q) = %v, want %v", tc.s, tc.p, got, tc.want)
		}
	}
}
