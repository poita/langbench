package base64

import (
	"bytes"
	"testing"
)

func TestEncode(t *testing.T) {
	cases := []struct{ in, std, url string }{
		{"", "", ""},
		{"f", "Zg==", "Zg"},
		{"fo", "Zm8=", "Zm8"},
		{"foo", "Zm9v", "Zm9v"},
		{"foobar", "Zm9vYmFy", "Zm9vYmFy"},
		{"\xfb\xff", "+/8=", "-_8"},
	}
	for _, c := range cases {
		if got := EncodeStd([]byte(c.in)); string(got) != c.std {
			t.Errorf("EncodeStd(%q) = %q, want %q", c.in, got, c.std)
		}
		if got := EncodeURL([]byte(c.in)); string(got) != c.url {
			t.Errorf("EncodeURL(%q) = %q, want %q", c.in, got, c.url)
		}
	}
}

func TestDecodeValid(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", ""},
		{"Zg==", "f"}, {"Zg", "f"}, {"Zm8=", "fo"}, {"Zm8", "fo"}, {"Zm9v", "foo"},
		{"+/8=", "\xfb\xff"}, {"-_8", "\xfb\xff"}, {"-_8=", "\xfb\xff"},
		{"QQ==", "A"}, {"QR==", "A"}, // unused low bits are ignored
	}
	for _, c := range cases {
		got, err := Decode(nil, []byte(c.in))
		if err != nil || string(got) != c.want {
			t.Errorf("Decode(%q) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}
}

func TestDecodeInvalid(t *testing.T) {
	for _, in := range []string{
		"A", "AAAAA", "Zg=", "Zg===", "Zm8==", "Zm9v=", "====", "=Zg", "Z=g=",
		"Zm 9v", "Zm9v\n", "+-", "_/", "ab+c-d", "é", "Zg==Zg==",
	} {
		if got, err := Decode(nil, []byte(in)); err == nil {
			t.Errorf("Decode(%q) = %q, want error", in, got)
		}
	}
}

func TestDecodeAppendsAndKeepsPrefixOnError(t *testing.T) {
	dst := []byte("x")
	got, err := Decode(dst, []byte("Zg"))
	if err != nil || string(got) != "xf" {
		t.Fatalf("got %q, %v", got, err)
	}
	got, err = Decode(dst, []byte("!"))
	if err == nil || string(got) != "x" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestRoundTrip(t *testing.T) {
	var data []byte
	for i := 0; i < 300; i++ {
		data = append(data, byte(i*7))
		for _, enc := range [][]byte{EncodeStd(data), EncodeURL(data)} {
			got, err := Decode(nil, enc)
			if err != nil || !bytes.Equal(got, data) {
				t.Fatalf("round trip failed at %d", i)
			}
		}
	}
}
