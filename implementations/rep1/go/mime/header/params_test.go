package header

import "testing"

func TestStructuredValue(t *testing.T) {
	s := ParseStructured(` Text/HTML ; charset="UTF-8"; boundary=simple boundary`)
	if s.Token() != "text/html" {
		t.Errorf("token = %q", s.Token())
	}
	if v, _ := s.Param("boundary"); v != "simple boundary" {
		t.Errorf("boundary = %q", v)
	}
	if v, _ := s.Param("charset"); v != "UTF-8" {
		t.Errorf("charset = %q", v)
	}
}

func TestParameters(t *testing.T) {
	tests := []struct {
		name, in, want string
	}{
		{"quoted", `a; filename="report.pdf"`, "report.pdf"},
		{"extended", `a; filename*=utf-8''a%C3%A9.txt`, "aé.txt"},
		{"segments", `a; filename*0="long"; filename*1="name.txt"`, "longname.txt"},
		{"mixed segments", `a; filename*0*=utf-8''a%C3%A9; filename*1=".txt"`, "aé.txt"},
		{"encoded word", `a; filename="=?utf-8?Q?a=C3=A9.txt?="`, "aé.txt"},
		{"unquoted blanks", `a; filename=two words.bin`, "two words.bin"},
		{"empty charset is ascii", `a; filename*=''caf%E9.txt`, "caf�.txt"},
		{"numeric order", `a; filename*0=a; filename*2=c; filename*10=j`, "acj"},
		{"escaped backslash", `a; filename="a\\"; x=1`, `a\`},
		{"semicolon in quotes", `a; filename="a;b"; x=1`, "a;b"},
		{"first wins", `a; filename=one; filename=two`, "one"},
		{"duplicate segment", `a; filename*0=a; filename*00=b; filename*1=c`, "ac"},
		{"segments beat extended", `a; filename*=utf-8''x; filename*0=y`, "y"},
		{"extended beats plain", `a; filename=x; filename*=utf-8''y`, "y"},
		{"bad percent", `a; filename*=utf-8''100%25%zz`, "100%%zz"},
		{"no apostrophes", `a; filename*=a%20b`, "a b"},
		{"latin1 charset", `a; filename*=iso-8859-1'en'caf%E9`, "café"},
		{"unterminated quote", `a; filename="abc; x=1`, "abc; x=1"},
		{"name case", `a; FileName=x`, "x"},
		{"segment padding", `a; filename*07=b; filename*0=a`, "ab"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := ParseStructured(tc.in).Param("filename")
			if !ok || got != tc.want {
				t.Errorf("filename = %q (%v), want %q", got, ok, tc.want)
			}
		})
	}
}

func TestStarNamesArePlain(t *testing.T) {
	s := ParseStructured(`a; *0=x; =y; noequals`)
	if v, ok := s.Param("*0"); !ok || v != "x" {
		t.Errorf("*0 = %q %v", v, ok)
	}
	if _, ok := s.Param("noequals"); ok {
		t.Error("segment without = must be ignored")
	}
}
