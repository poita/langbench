package base64_test

import (
	stdb64 "encoding/base64" // oracle only
	"math/rand"
	"testing"

	"example.com/webhooks/base64"
)

func TestEncodeExamples(t *testing.T) {
	cases := []struct{ in, std, url string }{
		{"", "", ""},
		{"f", "Zg==", "Zg"},
		{"fo", "Zm8=", "Zm8"},
		{"foo", "Zm9v", "Zm9v"},
		{"\xfb\xff", "+/8=", "-_8"},
	}
	for _, c := range cases {
		if got := base64.EncodeStandard([]byte(c.in)); got != c.std {
			t.Errorf("EncodeStandard(%q) = %q, want %q", c.in, got, c.std)
		}
		if got := base64.EncodeURL([]byte(c.in)); got != c.url {
			t.Errorf("EncodeURL(%q) = %q, want %q", c.in, got, c.url)
		}
	}
}

func TestEncodeMatchesStdlib(t *testing.T) {
	rng := rand.New(rand.NewSource(4))
	for n := 0; n < 100; n++ {
		b := make([]byte, n)
		rng.Read(b)
		if got, want := base64.EncodeStandard(b), stdb64.StdEncoding.EncodeToString(b); got != want {
			t.Fatalf("std len %d: %q vs %q", n, got, want)
		}
		if got, want := base64.EncodeURL(b), stdb64.RawURLEncoding.EncodeToString(b); got != want {
			t.Fatalf("url len %d: %q vs %q", n, got, want)
		}
	}
}

func TestRoundTrip(t *testing.T) {
	rng := rand.New(rand.NewSource(5))
	for n := 0; n < 100; n++ {
		b := make([]byte, n)
		rng.Read(b)
		for _, enc := range []string{base64.EncodeStandard(b), base64.EncodeURL(b)} {
			got, err := base64.Decode([]byte(enc))
			if err != nil || string(got) != string(b) {
				t.Fatalf("len %d enc %q: got %x err %v", n, enc, got, err)
			}
		}
	}
}

func TestDecode(t *testing.T) {
	valid := map[string]string{
		"":         "",
		"Zg":       "f",
		"Zg==":     "f",
		"Zm8":      "fo",
		"Zm8=":     "fo",
		"QQ==":     "A",
		"QR==":     "A", // stray low bits are ignored
		"+/8=":     "\xfb\xff",
		"-_8":      "\xfb\xff",
		"AAAA":     "\x00\x00\x00",
		"Zm9vYmFy": "foobar",
	}
	for in, want := range valid {
		got, err := base64.Decode([]byte(in))
		if err != nil || string(got) != want {
			t.Errorf("Decode(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	invalid := []string{
		"A", "AAAAA", "Zg=", "Zm8==", "Zg===", "AAAA=", "AAAA==", "=", "==", "Zg=a", "Z=g=",
		"+-", "/_", "+/-", "Zm 9v", "Zm9v\n", "Zm9é", "Zm8=Zm8=",
	}
	for _, in := range invalid {
		if got, err := base64.Decode([]byte(in)); err == nil {
			t.Errorf("Decode(%q) = %q, want error", in, got)
		}
	}
}

func TestAppendDecodeLeavesDstOnError(t *testing.T) {
	dst := []byte("keep")
	got, err := base64.AppendDecode(dst, []byte("A"))
	if err == nil || string(got) != "keep" {
		t.Fatalf("got %q, %v", got, err)
	}
	got, err = base64.AppendDecode(dst, []byte("Zg=="))
	if err != nil || string(got) != "keepf" {
		t.Fatalf("got %q, %v", got, err)
	}
}
