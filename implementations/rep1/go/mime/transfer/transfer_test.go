package transfer

import "testing"

func TestQuotedPrintable(t *testing.T) {
	tests := []struct{ in, want string }{
		{"a=20b", "a b"},
		{"a=\nb", "ab"},
		{"a=3Db", "a=b"},
		{"a=3db", "a=b"},
		{"a=Zb", "a=Zb"},
		{"a=3\n", "a=3\n"},
		{"abc=", "abc"},
		{"=0D=0A", "\r\n"},
		{"x  \ny", "x  \ny"},
		{"=", ""},
		{"==41", "=A"},
	}
	for _, tc := range tests {
		if got := string(DecodeQuotedPrintable([]byte(tc.in))); got != tc.want {
			t.Errorf("QP(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestBase64(t *testing.T) {
	tests := []struct{ in, want string }{
		{"AAECAw==", "\x00\x01\x02\x03"},
		{"AAEC\nAw", "\x00\x01\x02\x03"},
		{"TWE=", "Ma"},
		{"TQ", "M"},
		{"TWFu", "Man"},
		{"T", ""},
		{"TW Fu!!\n", "Man"},
		{"", ""},
		{"TWFuT", "Man"},
	}
	for _, tc := range tests {
		if got := string(DecodeBase64([]byte(tc.in))); got != tc.want {
			t.Errorf("base64(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestDecodeDispatch(t *testing.T) {
	if got := string(Decode([]byte("a=20"), "7bit")); got != "a=20" {
		t.Errorf("7bit changed the body: %q", got)
	}
	if got := string(Decode([]byte("a=20"), "x-weird")); got != "a=20" {
		t.Errorf("unknown encoding changed the body: %q", got)
	}
	if got := string(Decode([]byte("a=20"), "quoted-printable")); got != "a " {
		t.Errorf("qp: %q", got)
	}
}
