package transfer

import "testing"

func TestBase64(t *testing.T) {
	cases := []struct{ in, want string }{
		{"AAECAw==", "\x00\x01\x02\x03"},
		{"TWFu", "Man"},
		{"TW\r\nFu", "Man"},
		{"TWE", "Ma"},
		{"TQ", "M"},
		{"TQ==", "M"},
		{"T", ""},
		{"TWFuT", "Man"},
		{"!!!", ""},
		{"", ""},
	}
	for _, c := range cases {
		if got := string(Base64([]byte(c.in))); got != c.want {
			t.Errorf("Base64(%q) = %q, want %q", c.in, got, c.want)
		}
		if got := string(Base64(c.in)); got != c.want {
			t.Errorf("Base64 string(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestQuotedPrintable(t *testing.T) {
	cases := []struct{ in, want string }{
		{"a=20b", "a b"},
		{"a=\nb", "ab"},
		{"a=3Db", "a=b"},
		{"a=Zb", "a=Zb"},
		{"a=3\n", "a=3\n"},
		{"abc=", "abc"},
		{"=0D=0A", "\r\n"},
		{"x  \ny", "x  \ny"},
		{"=3d=e9", "=\xe9"},
		{"==41", "=A"},
		{"a=4", "a=4"},
	}
	for _, c := range cases {
		if got := string(QuotedPrintable([]byte(c.in))); got != c.want {
			t.Errorf("QuotedPrintable(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestDecodeDispatch(t *testing.T) {
	body := []byte("a=41")
	for _, enc := range []string{"7bit", "8bit", "binary", "x-unknown", ""} {
		if got := string(Decode(body, enc)); got != "a=41" {
			t.Errorf("%q changed the body: %q", enc, got)
		}
	}
	if got := string(Decode(body, "quoted-printable")); got != "aA" {
		t.Errorf("qp = %q", got)
	}
	if got := string(Decode([]byte("TWFu"), "base64")); got != "Man" {
		t.Errorf("base64 = %q", got)
	}
}
