package lines

import "testing"

func TestNormalizeCRLF(t *testing.T) {
	cases := map[string]string{
		"a\r\nb\r\n": "a\nb\n",
		"a\rb":       "a\rb",
		"\r\r\n":     "\r\n",
		"":           "",
		"x\r":        "x\r",
	}
	for in, want := range cases {
		if got := string(NormalizeCRLF([]byte(in))); got != want {
			t.Errorf("NormalizeCRLF(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestNext(t *testing.T) {
	line, size, ok := Next([]byte("ab\r\ncd"))
	if string(line) != "ab" || size != 4 || !ok {
		t.Errorf("got %q %d %v", line, size, ok)
	}
	line, size, _ = Next([]byte("cd"))
	if string(line) != "cd" || size != 2 {
		t.Errorf("unterminated: %q %d", line, size)
	}
	if _, _, ok := Next(nil); ok {
		t.Error("empty input has no lines")
	}
}
